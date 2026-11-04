#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed extending O_DIRECT write leaves nothing past EOF to expose
#
# An O_DIRECT write past i_size allocated its blocks as WRITTEN data, on
# the grounds that i_size moves only once the write completes. A write
# that fails does not move it -- and the block stayed in the tree as
# data, holding whatever the previous owner left there. A truncate-up,
# or a later write further out, then served those bytes as the file's.
# The buffered path zeroes such blocks; the direct one did not.
#
# Now a direct write allocates preallocated past i_size too, and its
# completion converts only what landed.
#
# Staged: every free block is filled with a marker (a file written to
# ENOSPC, then deleted); an O_DIRECT write at the end of a one-block
# file fails right after allocating (dio_fail_after_alloc_once); the
# file is truncated up over the block and read, then again after a
# remount.
#
# DISCRIMINATION: with past-EOF blocks allocated written again
# (dio_prealloc limited to i_size), the read returns the marker.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dio_fail_after_alloc_once ] || { skip "dio_fail_after_alloc_once is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 dioextfail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dioextfail)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Every free block holds the marker.
python3 - "$MNT/filler" <<'PY'
import os, sys
blk = b"STALE-OWNER-DATA" * 256
f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
buf = blk * 256
try:
    while True:
        os.write(f, buf)
except OSError:
    pass
os.fsync(f); os.close(f)
PY
rm -f "$MNT/filler"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"

# A one-block file, then a direct write of one block at its end that
# fails after allocating.
python3 - "$MNT/victim" <<'PY'
import os, sys, mmap
p = sys.argv[1]
f = os.open(p, os.O_WRONLY | os.O_CREAT, 0o644)
os.write(f, b"v" * 4096); os.fsync(f); os.close(f)
PY
INO="$(stat -c %i "$MNT/victim")"
ct_param_set dio_fail_after_alloc_once 1
RES="$(python3 - "$MNT/victim" <<'PY'
import os, sys, mmap
f = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(b"D" * 4096)
try:
    n = os.pwrite(f, buf, 4096)
    print("wrote %d" % n)
except OSError as e:
    print("errno %d" % e.errno)
os.close(f)
PY
)"
ARMED="$(cat /sys/module/cetrafs/parameters/dio_fail_after_alloc_once)"
ct_param_set dio_fail_after_alloc_once 0
log "the extending direct write: $RES; size now $(stat -c %s "$MNT/victim")"
[ "$ARMED" = N ] && [ "$RES" != "wrote 4096" ] ||
    { fail "setup: the direct write did not fail after allocating ($RES, knob $ARMED)"; ct_exit; }
sync

# Setup: the write did allocate block 1, and the device holds the marker there.
PHYS="$("$IPOKE" "$IMG" extents "$INO" | sed -n 's/^ext [0-9]* logical=1 phys=\([0-9]*\) .*/\1/p')"
[ -n "$PHYS" ] || PHYS="$("$IPOKE" "$IMG" extents "$INO" | awk '/^ext / {split($3,l,"="); split($4,p,"="); split($5,n,"="); if (l[2] <= 1 && l[2] + n[2] > 1) print p[2] + 1 - l[2]}')"
if [ -n "$PHYS" ] && dd if="$IMG" bs=4096 skip="$PHYS" count=1 status=none | grep -q STALE-OWNER-DATA; then
    pass "setup: the failed write left block 1 allocated at $PHYS, over the previous owner's bytes"
else
    fail "setup: no allocated block 1 holding the marker ($("$IPOKE" "$IMG" extents "$INO" | tr '\n' ' ')) -- the check below proves nothing"
fi

check() {
    python3 - "$MNT/victim" <<'PY'
import os, sys
os.truncate(sys.argv[1], 8 * 4096)
d = open(sys.argv[1], "rb").read()
print("STALE" if b"STALE-OWNER-DATA" in d else "clean")
PY
}
OUT="$(check)"
[ "$OUT" = clean ] && pass "a truncate-up over the failed write reads zeros" ||
    fail "a truncate-up over the failed write serves the previous owner's bytes"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
OUT="$(check)"
[ "$OUT" = clean ] && pass "and after a remount" || fail "after a remount the previous owner's bytes are the file's"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
