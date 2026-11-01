#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed allocation-bitmap flush must stop the publish of the extents it covers
#
# The allocator sets data-bitmap bits with sync=false; every durability
# boundary calls cetrafs_alloc_flush_bitmaps() BEFORE the write that
# publishes extents naming those blocks (CLAUDE.md rule 8). That flush
# could fail and nobody would know:
#
#   - it consumed the BG's "bitmap dirty" flag before syncing, so a
#     failed sync was never retried by the next boundary;
#   - the record publishers (cetrafs_write_raw_inode_fd(), the sync
#     cetrafs_write_raw_inode()) and the close path ignored its result.
#
# fsync even saw the -EIO -- and then published anyway, because the
# record write it goes on to do calls the flush again, finds the flag
# already consumed, gets 0 and CASes the extent onto the device. A node
# dying there leaves blocks referenced by an inode and reading FREE to
# every node, allocator included.
#
# The crash is simulated by copying the backing file while the volume
# is still mounted: that is exactly what the device holds at that
# instant, dirty buffers excluded. alloc_flush_fail makes the bitmap
# sync fail as a device write error would, leaving the block dirty.
#
# Three outcomes are told apart: the baseline snapshot (no fault) must
# have no referenced-but-FREE block -- otherwise the method is noisy and
# the fault snapshot proves nothing -- the fault snapshot must have none
# either, and the injected fault must actually have fired (fsync -EIO).
#
# DISCRIMINATION (measured on the unfixed code): the fault snapshot's
# fsck reports the written blocks as referenced but FREE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 bmflush)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt bmflush)"
SNAP_BASE="$(ct_image 1 snapbase)"
SNAP_FAULT="$(ct_image 1 snapfault)"
SNAP_AFTER="$(ct_image 1 snapafter)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_flush_fail 0
# The speculative run reserves (and so sets) bits ahead of the write that
# uses them; the first fsync would make them durable and the second
# write would dirty no bit at all. One block per allocation instead.
ct_param_set alloc_run_blocks 0

PARAM=/sys/module/cetrafs/parameters/alloc_flush_fail

# One process holds the file open across every step: closing it is a
# durability boundary of its own and would publish behind our back.
out="$(python3 - "$MNT/f" "$BACK" "$SNAP_BASE" "$SNAP_FAULT" "$SNAP_AFTER" "$PARAM" <<'PY'
import errno, os, subprocess, sys
path, back, snap_base, snap_fault, snap_after, param = sys.argv[1:]

def snap(dst):
    subprocess.run(["cp", "--sparse=always", back, dst], check=True)

def setp(v):
    with open(param, "w") as f:
        f.write(v)

fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
os.write(fd, b"A" * 65536)
os.fsync(fd)                          # baseline: no fault, everything durable
snap(snap_base)

setp("1")
os.pwrite(fd, b"B" * 65536, 1 << 20)  # fresh blocks, bits dirty in cache only
try:
    os.fsync(fd)
    print("fsync=0")
except OSError as e:
    print("fsync=" + errno.errorcode.get(e.errno, str(e.errno)))
snap(snap_fault)                      # the crash, taken before anything else can flush

setp("0")
try:
    os.fsync(fd)
    print("refsync=0")
except OSError as e:
    print("refsync=" + errno.errorcode.get(e.errno, str(e.errno)))
snap(snap_after)                      # a crash right after the recovered fsync
os.close(fd)
sys.stdout.flush()
PY
)"
log "$(tr '\n' ' ' <<<"$out")"

if grep -qx 'fsync=EIO' <<<"$out"; then
    pass "fsync reported the injected bitmap write failure (-EIO)"
else
    fail "fsync did not report the injected failure ($(grep '^fsync=' <<<"$out")) -- the fault never fired"
fi
if grep -qx 'refsync=0' <<<"$out"; then
    pass "once the device recovers, the next fsync succeeds"
else
    fail "the fsync after recovery failed ($(grep '^refsync=' <<<"$out")) -- the failed flush was not retryable"
fi

fsck_clean() { # <device> <what>
    local rc=0 o
    o="$(ct_fsck "$1" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -qE '^ERR' <<<"$o"; then
        pass "$2: fsck clean"
    else
        fail "$2: fsck rc=$rc: $(grep -E '^ERR' <<<"$o" | head -3)"
    fi
}

# A crash snapshot of a LIVE volume is not fsck-clean and is not meant to
# be: free counts accrue in memory and are reconciled when ownership
# moves, so a count that disagrees with its bitmap is the designed state.
# What a crash must never leave is a block an inode references while its
# bit reads FREE -- that is the one class asserted on here. The content
# pass must have actually run for its silence to mean anything.
snap_no_ref_free() { # <image> <what>
    local rc=0 o
    o="$(ct_fsck "$(ct_loop "$1")" 2>&1)" || rc=$?
    if ! grep -q '^  content: ' <<<"$o"; then
        fail "$2: fsck never reached its content pass (rc=$rc): $(grep -E '^ERR' <<<"$o" | head -2)"
    elif grep -q 'referenced by an inode but marked FREE' <<<"$o"; then
        fail "$2: $(grep -c 'referenced by an inode but marked FREE' <<<"$o") block(s) referenced but FREE, e.g. $(grep -m1 'marked FREE' <<<"$o")"
    else
        pass "$2: no block is referenced while its bit reads FREE"
    fi
}
snap_no_ref_free "$SNAP_BASE" "baseline crash snapshot (no fault)"
snap_no_ref_free "$SNAP_FAULT" "crash snapshot after a failed bitmap flush"
# A successful fsync must have made the bits the failed one owed durable:
# the old code had consumed their dirty flag, so this one synced nothing.
snap_no_ref_free "$SNAP_AFTER" "crash snapshot after the recovered fsync"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
if python3 - "$MNT/f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
ok = os.pread(fd, 65536, 0) == b"A" * 65536 and os.pread(fd, 65536, 1 << 20) == b"B" * 65536
sys.exit(0 if ok else 1)
PY
then
    pass "after remount both writes read back"
else
    fail "after remount the file content is wrong"
fi
ct_umount "$MNT"
fsck_clean "$DEV" "final volume"

ct_exit
