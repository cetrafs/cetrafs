#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# punch and truncate on a file with more than 65535 extents keep every extent
#
# A depth-2 extent tree holds far more than 65535 extents (kmod.h's
# cetrafs_inode_extents.entries is u32 for exactly that reason), but the
# two array editors the punch and the truncate run over the flattened map
# -- cetrafs_leaf_array_punch() and cetrafs_leaf_array_trim() -- took the
# entry count as u16. The callers passed the u32 count straight in, so
# for a file with 65536 + k extents the editors saw k entries, and the
# tree rebuilt from their output kept only those: every other extent
# vanished from the map (its data reading back as a hole) and its blocks
# leaked. Any user with a writable file reaches it; a VM guest issuing
# discard (PUNCH_HOLE) on a fragmented image is enough.
#
# N is chosen so that N mod 65536 = 64: under the bug the punch and the
# truncate each rebuild the file from ~64 entries, which is unmistakable.
#
# The file is built one isolated block every other block, with the
# run-aware allocator off, so every written block is its own extent by
# construction -- two logically non-adjacent blocks cannot share one.
# That is asserted (block count, depth 2) rather than assumed.
#
# Every verification follows a REMOUNT: the punch only drops page cache
# over the hole, so a read straight after it would be served from cache
# for every block the broken tree no longer maps, and pass.
#
# DISCRIMINATION (measured against the u16 code): the mid-file punch
# readback fails (the hole still holds data), the truncate readback fails
# (65526 of 65590 blocks gone, 65 blocks left), and fsck reports the
# stranded blocks as leaked.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

ct_param_set alloc_run_blocks 0
IPOKE="$(ct_helper inode_block_poke)"

DEV="$(ct_dev 2048 u16ext)"
IMG="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt u16ext)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

N=65600 # 65536 + 64

build() {
    python3 - "$1" "$N" <<'PY'
import os, sys
p, n = sys.argv[1], int(sys.argv[2])
fd = os.open(p, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
for i in range(n):
    os.pwrite(fd, i.to_bytes(8, 'little') * 512, i * 2 * 4096)
os.fsync(fd)
os.close(fd)
PY
}

# verify <file> <n_data_blocks_expected_in_file> <punched_index or -1>
verify() {
    python3 - "$1" "$2" "$3" <<'PY'
import os, sys
p, n, punched = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fd = os.open(p, os.O_RDONLY)
bad = []
for i in range(n):
    got = os.pread(fd, 4096, i * 2 * 4096)
    want = b'\0' * 4096 if i == punched else i.to_bytes(8, 'little') * 512
    if got != want:
        bad.append(i)
os.close(fd)
if bad:
    print(f"{len(bad)} of {n} block(s) wrong; first: {bad[:8]}")
    sys.stdout.flush()
    sys.exit(1)
PY
}

log "building two files of $N single-block extents each"
t0=$SECONDS
build "$MNT/punch"
build "$MNT/trunc"
sync
log "built in $((SECONDS - t0))s"

# Setup proof: every written block allocated (and nothing in the gaps),
# and the tree really is depth 2.
for f in punch trunc; do
    blocks=$(($(stat -c %b "$MNT/$f") / 8))
    if [ "$blocks" -ge "$N" ] && [ "$blocks" -lt $((N + 1024)) ]; then
        pass "$f: $blocks blocks allocated for $N isolated data blocks (>= $N extents)"
    else
        fail "$f: $blocks blocks allocated, expected $N + metadata -- the setup did not build $N extents"
    fi
done
INO_P="$(stat -c %i "$MNT/punch")"
INO_T="$(stat -c %i "$MNT/trunc")"
ct_umount "$MNT"
for ino in "$INO_P" "$INO_T"; do
    SHAPE="$("$IPOKE" "$IMG" extents "$ino" 2>/dev/null | head -1)"
    case "$SHAPE" in
    depth=2*) pass "ino $ino is a depth-2 tree ($SHAPE)" ;;
    *) fail "ino $ino: expected depth 2, got: $SHAPE -- the setup is not what this suite measures" ;;
    esac
done
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# --- punch: one whole extent, twice ---
# Two positions, because the bug had two faces. A punch past the first
# (N mod 65536) entries was a silent NO-OP -- the truncated array never
# reached the hole, the no-op check saw an unchanged map and published
# nothing, and the "hole" kept serving its old data. A punch inside them
# rebuilt the whole file from those few entries.
for MID in $((N / 2)) 10; do
    log "punching data block $MID of $N"
    if fallocate -p -o $((MID * 2 * 4096)) -l 4096 "$MNT/punch"; then
        pass "punch of block $MID in a $N-extent file returned success"
    else
        fail "punch of block $MID in a $N-extent file failed"
    fi
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    if out="$(verify "$MNT/punch" "$N" "$MID" 2>&1)"; then
        pass "after punching block $MID it reads as a hole and every other block keeps its data"
    else
        fail "after punching block $MID: $out"
    fi
    # The next round expects block $MID to read as data again: rewrite it.
    python3 -c "import os,sys; fd=os.open(sys.argv[1], os.O_WRONLY); os.pwrite(fd, int(sys.argv[2]).to_bytes(8,'little')*512, int(sys.argv[2])*2*4096); os.fsync(fd)" "$MNT/punch" "$MID"
done

# --- truncate: drop only the last 10 data blocks ---
KEEP=$((N - 10))
NEWSIZE=$(((KEEP - 1) * 2 * 4096 + 4096))
log "truncating to keep $KEEP of $N data blocks"
truncate -s "$NEWSIZE" "$MNT/trunc"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
if out="$(verify "$MNT/trunc" "$KEEP" -1 2>&1)"; then
    pass "after the truncate all $KEEP kept blocks read back their own data"
else
    fail "after the truncate: $out"
fi
blocks=$(($(stat -c %b "$MNT/trunc") / 8))
if [ "$blocks" -ge "$KEEP" ]; then
    pass "truncated file still has $blocks blocks allocated (>= $KEEP)"
else
    fail "truncated file has only $blocks blocks allocated, $KEEP data blocks should remain"
fi

ct_umount "$MNT"
# fsck reports a leak as a WARN and still exits 0, so the exit status
# alone cannot see the blocks a truncated map strands: match the count.
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'leaked' <<<"$out"; then
    pass "fsck clean, nothing leaked, after the punches and the truncate"
else
    fail "fsck after the punches and the truncate (rc=$rc): $(grep -E 'ERR|WARN' <<<"$out" | head -5)"
fi

ct_exit
