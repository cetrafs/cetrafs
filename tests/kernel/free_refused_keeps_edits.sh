#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free refused as damage drops no held-back tree edit
#
# A free drops the held-back tree edits of the blocks it frees (their
# tree no longer names them). It did so first, before it looked at the
# extent at all -- so a corrupt extent whose free is then REFUSED (out of
# its Block Group, in an unowned one) still dropped the edits of every
# held-back block in its range, another file's live leaf included: that
# file's next boundary wrote its old map, and the blocks its edit had
# converted read as zeros (audit 2026-11-15 BL-13). The drop now follows
# the validation.
#
# Staged on one node: file A, preallocated, with O_DIRECT writes spaced
# so its map spills into a leaf, fsynced; then one more write at block
# 900 with no fsync -- its leaf edit held back. File B, one block, gets
# an inline extent poked to start at A's leaf block and run past its
# Block Group's end; B is removed, and its free is refused.
#   setup: the free was refused as crossing out of the Block Group;
#   1. A's fsync after it keeps the conversion: block 900 reads back on
#      a fresh mount.
#
# DISCRIMINATION: free_forget_first=1 drops before validating; block 900
# must then read zeros.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/free_forget_first ] || { skip "free_forget_first is missing"; ct_exit; }
LP="$(ct_helper leaf_poke)"
PPOKE="$(ct_helper extent_phys_poke)"
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt frke)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set free_forget_first 0

dio_write() { # <path> <block> <tag> [fsync]
    python3 -I - "$@" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(sys.argv[3].encode() * (4096 // len(sys.argv[3])))
os.pwritev(fd, [buf], int(sys.argv[2]) * 4096)
if len(sys.argv) > 4:
    os.fsync(fd)
os.close(fd)
PY
}

# <forget_first 0|1> -> "refused= reads="
round() {
    local img dev a b ia ib leaf mark refused=0 reads=0
    img="$(ct_image 560 "frke$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    a="$MNT/a"
    b="$MNT/b"
    fallocate -l $((4 << 20)) "$a"
    for i in $(seq 0 6); do dio_write "$a" $((i * 64)) "$(printf 'A%07d' $((i * 64)))"; done
    dio_write "$a" 448 A0000448 fsync
    echo x >"$b"
    sync
    ia="$(stat -c %i "$a")"
    ib="$(stat -c %i "$b")"
    ct_umount "$MNT"
    leaf="$("$LP" "$img" leaf "$ia" 2>/dev/null || true)"
    [ -n "$leaf" ] || { echo "refused=0 reads=0 noleaf=1"; return; }
    # B's one extent: at A's leaf, running past the Block Group's end.
    "$PPOKE" "$img" "$ib" "$leaf" >/dev/null 2>&1
    "$IPOKE" "$img" extset "$ib" 0 len 400000 >/dev/null 2>&1
    ct_mount "$dev" "$MNT"
    echo "$1" >/sys/module/cetrafs/parameters/free_forget_first
    mark="$(dmesg_mark)"
    # A stays open: its close would write the held-back edit first.
    python3 -I - "$a" "$b" "$MNT" <<'PY'
import mmap, os, subprocess, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(b"LATE0900" * 512)
os.pwritev(fd, [buf], 900 * 4096)        # held back: no fsync yet
os.unlink(sys.argv[2])                   # B's free, refused
subprocess.run(["sync", "-f", sys.argv[3]], check=False)
os.fsync(fd)                             # A's boundary, after the free
os.close(fd)
PY
    echo 0 >/sys/module/cetrafs/parameters/free_forget_first
    dmesg_since "$mark" | grep -q "crosses out of BG .* -- refusing" && refused=1
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    [ "$(dd if="$a" bs=4096 skip=900 count=1 status=none | head -c 8)" = LATE0900 ] && reads=1
    ct_umount "$MNT"
    echo "refused=$refused reads=$reads"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "validated first: $R"
C="$(round 1)"
log "control (dropped first): $C"
for v in "$R" "$C"; do
    [ "$(get refused "$v")" = 1 ] || { fail "setup: B's free was not refused as crossing its Block Group ($v)"; ct_exit; }
done
pass "setup: B's corrupt extent named A's held-back leaf, and its free was refused"
[ "$(get reads "$R")" = 1 ] && pass "1: A kept its held-back conversion: block 900 reads back" ||
    fail "1: A's block 900 does not read back ($R)"
[ "$(get reads "$C")" = 0 ] && pass "control: dropped before validating, A's conversion was lost (block 900 reads zeros)" ||
    fail "control: A's conversion survived anyway -- the suite does not reach the window ($C)"
ct_exit
