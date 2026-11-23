#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck reports a directory's duplicate and impossible names
#
# fsck's namespace walk counted references and nothing else: two entries
# in one directory with one name (a lookup finds one; an unlink through
# it leaves the other naming a file whose count went down), a name no
# create can make (empty, '/' or NUL inside it), and '.' or '..' where
# no directory keeps them all left a clean report (audit 2026-11-22
# N-49). Each is now an ERR.
#
# A directory of 24 entries (two blocks) made the normal way, then one
# entry at a time changed on the unmounted image (checksum restamped,
# references and sizes left right, so nothing else in fsck objects):
#   D. 'ab' cut to 'a': the name 'a' twice;
#   E. 'xy' given length 0;
#   S. 'xy' made 'x/';
#   Z. 'xy' made 'x\0';
#   P. a second '.' (naming the directory) in a free slot of block 0;
#   Q. a '..' (naming its parent) in a free slot of block 1;
# each: fsck exits nonzero and names that fault. The unpoked directory
# is clean first, and is again after each case is put back.
#
# DISCRIMINATION: CETRAFS_FSCK_TEST_NAMES_UNCHECKED=1 (the walk as
# before): every case is a clean report.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
FPOKE="$(ct_helper dirent_field_poke)"
MNT="$(ct_mnt fdn)"
ct_track mnt "$MNT"
FSCK="$ROOT/userspace/fsck.cetra"

IMG="$(ct_image 560 fdn)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
mkdir "$MNT/d"
: >"$MNT/d/a"
: >"$MNT/d/ab"
: >"$MNT/d/xy"
for i in $(seq -w 1 20); do : >"$MNT/d/f$i"; done
rm "$MNT/d/f05" # a free slot in the first block
D="$(stat -c %i "$MNT/d")"
AB="$(stat -c %i "$MNT/d/ab")"
XY="$(stat -c %i "$MNT/d/xy")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"

# phys of logical block <n> of the directory
blk_of() {
    "$IPOKE" "$IMG" extents "$D" | awk -v n="$1" '
        /^ext / { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  if (n >= v["logical"] && n < v["logical"] + v["len"]) { print v["phys"] + n - v["logical"]; exit } }'
}
# slot of inode <ino> in block <phys>, or of the first free slot with ino 0
slot_of() {
    python3 -I -c '
import sys, struct
f = open(sys.argv[1], "rb"); f.seek(int(sys.argv[2]) * 4096); blk = f.read(4096)
for k in range(4096 // 266):
    if struct.unpack_from("<Q", blk, k * 266)[0] == int(sys.argv[3]):
        print(k); break' "$IMG" "$1" "$2"
}
B0="$(blk_of 0)"
B1="$(blk_of 1)"
[ -n "$B0" ] && [ -n "$B1" ] || { fail "setup: the directory has no two blocks ($B0 / $B1)"; ct_exit; }
SAB="$(slot_of "$B0" "$AB")"
SXY="$(slot_of "$B0" "$XY")"
F0="$(slot_of "$B0" 0)"
F1="$(slot_of "$B1" 0)"
[ -n "$SAB" ] && [ -n "$SXY" ] && [ -n "$F0" ] && [ -n "$F1" ] ||
    { fail "setup: ab=$SAB xy=$SXY free0=$F0 free1=$F1 -- the entries are not in the first block"; ct_exit; }
DSIZE=$((24 * 266)) # a directory's size is its occupied slots: '.', '..' and 22 names
# (a wrong count here fails the clean fsck below: it checks the size)

fsck_out() { "$FSCK" "$DEV" 2>&1 && echo "EXIT=0" || echo "EXIT=$?"; }
OUT="$(fsck_out)"
grep -q '^EXIT=0' <<<"$OUT" || { fail "setup: fsck is not clean before any poke: $(grep -m2 ERR <<<"$OUT")"; ct_exit; }

SAVE0="$(ct_tmp fdn-b0)"
SAVE1="$(ct_tmp fdn-b1)"
dd if="$IMG" of="$SAVE0" bs=4096 skip="$B0" count=1 status=none
dd if="$IMG" of="$SAVE1" bs=4096 skip="$B1" count=1 status=none
restore() {
    dd if="$SAVE0" of="$IMG" bs=4096 seek="$B0" count=1 conv=notrunc,fsync status=none
    dd if="$SAVE1" of="$IMG" bs=4096 seek="$B1" count=1 conv=notrunc,fsync status=none
    "$IPOKE" "$IMG" setsize "$D" "$DSIZE" >/dev/null
    blockdev --flushbufs "$DEV"
}
# an entry fabricated in a free slot: <block> <slot> <ino> <name bytes...>
fabricate() {
    local b="$1" s="$2" ino="$3" i=0 x
    shift 3
    "$FPOKE" "$IMG" "$b" "$s" inode "$ino" >/dev/null
    "$FPOKE" "$IMG" "$b" "$s" file_type 2 >/dev/null
    "$FPOKE" "$IMG" "$b" "$s" name_len $# >/dev/null
    for x in "$@"; do "$FPOKE" "$IMG" "$b" "$s" "name_byte_$i" "$x" >/dev/null; i=$((i + 1)); done
    "$IPOKE" "$IMG" setsize "$D" $((DSIZE + 266)) >/dev/null # the entry is in the size
}

poke() {
    case "$1" in
    D) "$FPOKE" "$IMG" "$B0" "$SAB" name_len 1 >/dev/null ;;
    E) "$FPOKE" "$IMG" "$B0" "$SXY" name_len 0 >/dev/null ;;
    S) "$FPOKE" "$IMG" "$B0" "$SXY" name_byte_1 0x2f >/dev/null ;;
    Z) "$FPOKE" "$IMG" "$B0" "$SXY" name_byte_1 0 >/dev/null ;;
    P) fabricate "$B0" "$F0" "$D" 0x2e ;;
    Q) fabricate "$B1" "$F1" 1 0x2e 0x2e ;;
    esac
    blockdev --flushbufs "$DEV"
}
declare -A WANT=(
    [D]="holds the name 'a' 2 times"
    [E]="with an empty name"
    [S]="with a name containing '/'"
    [Z]="with a name containing a NUL byte"
    [P]="has a '.' entry at logical block 0 slot $F0"
    [Q]="has a '..' entry at logical block 1 slot $F1"
)
for c in D E S Z P Q; do
    poke "$c"
    OUT="$(fsck_out)"
    COUT="$(CETRAFS_FSCK_TEST_NAMES_UNCHECKED=1 fsck_out)"
    restore
    grep -qF "${WANT[$c]}" <<<"$OUT" && ! grep -q '^EXIT=0' <<<"$OUT" &&
        pass "$c: fsck fails and says: ${WANT[$c]}" ||
        fail "$c: no '${WANT[$c]}': $(grep -E '^(ERR|EXIT)' <<<"$OUT" | head -3 | tr '\n' '|')"
    grep -q '^EXIT=0' <<<"$COUT" && pass "$c control: the walk as before reports nothing" ||
        fail "$c control: the old walk saw it anyway: $(grep -E '^(ERR|EXIT)' <<<"$COUT" | head -3 | tr '\n' '|')"
    OUT="$(fsck_out)"
    grep -q '^EXIT=0' <<<"$OUT" || { fail "setup: case $c was not put back: $(grep -m2 ERR <<<"$OUT")"; ct_exit; }
done
ct_exit
