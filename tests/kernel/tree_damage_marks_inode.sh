#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tree or dirent block that fails its checksum marks ITS file damaged
#
# Damaged metadata refuses every write to the inode it belongs to
# (cetrafs_write_gate(), EUCLEAN). A tail-checksum failure on an extent
# leaf, interior index, xattr or dirent block was recorded against inode
# 0 instead: counted, logged, and no file's writes refused, so writes
# went on through a tree that had just failed (audit 2026-11-15 M-13).
#
#   L. a file's extent leaf corrupted: after the failed read, the file
#      is marked damaged; a write to it and a setxattr on it, which
#      never reads the tree, are refused EUCLEAN;
#   D. a directory's dirent block corrupted (dir.c's own reader, rule
#      12): after the failed listing, the directory is marked damaged.
#
# DISCRIMINATION: tree_damage_ino0=1 (as before): neither is marked, and
# the setxattr on L goes through.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper blk_tail_poke)"
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt tdmi)"
ct_track mnt "$MNT"
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <knob 0|1> -> RES
round() {
    local img dev fi di db mark out wr xw lmark dmark
    img="$(ct_image 560 "tdmi$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_param_set tree_damage_ino0 "$2"
    ct_mount "$dev" "$MNT"
    python3 - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(30):
    os.pwrite(fd, b'f' * 4096, i * 2 * 4096)   # strided: one extent each
os.fsync(fd); os.close(fd)
PY
    mkdir "$MNT/d"
    for i in 1 2 3; do touch "$MNT/d/e$i"; done
    sync
    fi="$(stat -c %i "$MNT/frag")"
    di="$(stat -c %i "$MNT/d")"
    [ "$("$IPOKE" "$img" extents "$fi" | grep -o 'depth=[01]')" = "depth=1" ] ||
        { fail "setup: frag did not spill into a leaf"; ct_exit; }
    db="$("$IPOKE" "$img" extents "$di" | sed -n 's/^ext 0 logical=0 phys=\([0-9]*\) .*/\1/p')"
    [ -n "$db" ] || { fail "setup: no dirent block for d"; ct_exit; }

    mark="$(dmesg_mark)"
    "$POKE" "$img" leaf "$fi" corrupt >/dev/null
    md5sum <"$MNT/frag" >/dev/null 2>&1 && { fail "setup: the corrupt leaf read back"; ct_exit; }
    wr="$(python3 -c 'import os,sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY)
    os.pwrite(fd, b"w", 0); os.close(fd); print("written")
except OSError as e:
    print(e.errno)' "$MNT/frag")"
    # A write that never reads the tree: refused only by the mark.
    xw="$(python3 -c 'import os,sys
try:
    os.setxattr(sys.argv[1], "user.k", b"v"); print("set")
except OSError as e:
    print(e.errno)' "$MNT/frag")"
    # The dirent block's tail: its last 8 bytes, flipped.
    printf '\xff\xff\xff\xff' | dd of="$img" bs=1 seek=$((db * 4096 + 4092)) conv=notrunc status=none
    "$IPOKE" "$img" bumpseq "$di" 2>/dev/null
    ls "$MNT/d" >/dev/null 2>&1 && { fail "setup: the corrupt dirent block listed"; ct_exit; }
    out="$(dmesg_since "$mark")"
    lmark=$(grep -c "ino=$fi is damaged" <<<"$out" || true)
    dmark=$(grep -c "ino=$di is damaged" <<<"$out" || true)
    RES="leaftail=$(grep -c 'extent leaf block .* failed its tail checksum' <<<"$out" || true)"
    RES="$RES direnttail=$(grep -c 'dirent block .* failed its tail checksum' <<<"$out" || true)"
    RES="$RES lmark=$lmark dmark=$dmark write=$wr xattr=$xw"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    ct_param_set tree_damage_ino0 0
}

round c 1
C="$RES"
log "control (inode 0): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get leaftail "$R")" -ge 1 ] && [ "$(get direnttail "$R")" -ge 1 ] &&
    [ "$(get leaftail "$C")" -ge 1 ] && [ "$(get direnttail "$C")" -ge 1 ] ||
    { fail "setup: a checksum failure was not reached ($R / $C)"; ct_exit; }
[ "$(get lmark "$R")" -ge 1 ] && pass "L1: the file whose leaf failed is marked damaged" || fail "L1: $R"
[ "$(get write "$R")" = 117 ] && [ "$(get xattr "$R")" = 117 ] &&
    pass "L2: a write and a setxattr on it are refused EUCLEAN" || fail "L2: $R"
[ "$(get dmark "$R")" -ge 1 ] && pass "D: the directory whose dirent block failed is marked damaged" || fail "D: $R"
[ "$(get lmark "$C")" = 0 ] && [ "$(get dmark "$C")" = 0 ] && [ "$(get xattr "$C")" = set ] &&
    pass "control: marked against inode 0, nothing was refused" ||
    fail "control: a mark landed without the change -- the suite does not reach it: $C"
ct_exit
