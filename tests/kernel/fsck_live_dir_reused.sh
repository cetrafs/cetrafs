#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck --live judges where a '.' stands only while the block is still the directory's
#
# fsck reports a '.' or '..' outside the slot a directory keeps it in, and
# a name held twice (N-49). Under --live a directory can be deleted while
# the walk holds its map, and its block reused as another directory's
# first block: the walk then reads a '.' and a '..' at the old
# directory's logical block 1, and names held twice -- a false ERR on a
# healthy volume (audit 2026-11-22 N-280). Those verdicts now count only
# while the directory is still the record the walk judged and its tree
# still maps the block there.
#
# A directory X of two blocks and a directory Y, mounted; one --live walk
# (CETRAFS_TEST_LIVE_PASSES=1, so nothing is filtered by repetition) held
# at X's map (CETRAFS_FSCK_TEST_LIVE_DIR_STALL); meanwhile X is removed
# and its second block made a copy of Y's first, as a reuse leaves it:
#   1. the walk reports no misplaced '.' or '..' and no name held twice;
#   2. the same walk over the volume left alone still sees a '.' that X
#      itself holds out of place (planted, unmounted): the check runs.
#
# DISCRIMINATION: CETRAFS_FSCK_TEST_LIVE_DIR_UNCHECKED=1 (as before): the
# reused block reads as X's misplaced '.' and '..'.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
FPOKE="$(ct_helper dirent_field_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
MNT="$(ct_mnt fldr)"
ct_track mnt "$MNT"
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
# phys of logical block <n> of inode <ino> in <img>
blk_of() {
    "$IPOKE" "$1" extents "$2" | awk -v n="$3" '
        /^ext / { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  if (n >= v["logical"] && n < v["logical"] + v["len"]) { print v["phys"] + n - v["logical"]; exit } }'
}

# <tag> <unchecked 0|1> -> RES "dot= dotdot= dup="
round() {
    local img dev x y bx1 by0 flag out pid
    img="$(ct_image 560 "fldr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/x" "$MNT/y"
    for i in $(seq -w 1 20); do : >"$MNT/x/f$i"; done
    : >"$MNT/y/a"
    x="$(stat -c %i "$MNT/x")"
    y="$(stat -c %i "$MNT/y")"
    sync
    bx1="$(blk_of "$img" "$x" 1)"
    by0="$(blk_of "$img" "$y" 0)"
    [ -n "$bx1" ] && [ -n "$by0" ] || { fail "setup: x has no second block or y no first ($bx1 / $by0)"; ct_exit; }
    flag="$(ct_tmp fldr-flag)"
    rm -f "$flag"
    out="$(ct_tmp fldr-out)"
    # set at all is on (cetrafs_test_env()): only in the control
    if [ "$2" = 1 ]; then
        CETRAFS_TEST_LIVE_PASSES=1 CETRAFS_FSCK_TEST_LIVE_DIR_STALL="$x:$flag" \
            CETRAFS_FSCK_TEST_LIVE_DIR_UNCHECKED=1 "$FSCK" --live "$dev" >"$out" 2>&1 &
    else
        CETRAFS_TEST_LIVE_PASSES=1 CETRAFS_FSCK_TEST_LIVE_DIR_STALL="$x:$flag" "$FSCK" --live "$dev" >"$out" 2>&1 &
    fi
    pid=$!
    for _ in $(seq 1 300); do [ -e "$flag" ] && break; sleep 0.1; done
    [ -e "$flag" ] || { kill "$pid" 2>/dev/null; fail "setup: the walk never reached x ($(tail -2 "$out"))"; ct_exit; }
    rm -rf "$MNT/x"
    sync
    dd if="$img" of="$img" bs=4096 skip="$by0" seek="$bx1" count=1 conv=notrunc,fsync status=none
    rm -f "$flag"
    wait "$pid" || true
    RES="dot=$(grep -c "^ERR: directory inode $x has a '.' entry" "$out" || true)"
    RES="$RES dotdot=$(grep -c "^ERR: directory inode $x has a '..' entry" "$out" || true)"
    RES="$RES dup=$(grep -c "^ERR: directory inode $x holds the name" "$out" || true)"
    ct_umount "$MNT"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (unchecked): $C"
[ "$(get dot "$R")" = 0 ] && [ "$(get dotdot "$R")" = 0 ] && [ "$(get dup "$R")" = 0 ] &&
    pass "1: the reused block was not taken for the deleted directory's own" || fail "1: $R"
[ "$(get dot "$C")" -ge 1 ] && [ "$(get dotdot "$C")" -ge 1 ] &&
    pass "control: unchecked, the reused block read as x's misplaced '.' and '..' ($C)" ||
    fail "control: $C -- the walk did not read the reused block as x's"

# 2: a '.' x really holds out of place is still reported under --live
img="$(ct_image 560 fldrp)"
dev="$(ct_loop "$img")"
ct_mkfs_small "$dev" >/dev/null
ct_mount "$dev" "$MNT"
mkdir "$MNT/x"
for i in $(seq -w 1 20); do : >"$MNT/x/f$i"; done
rm "$MNT/x/f20" # a free slot in the second block
x="$(stat -c %i "$MNT/x")"
ct_umount "$MNT"
bx1="$(blk_of "$img" "$x" 1)"
slot="$(python3 -I -c '
import sys, struct
f = open(sys.argv[1], "rb"); f.seek(int(sys.argv[2]) * 4096); blk = f.read(4096)
print(next(k for k in range(4096 // 266) if struct.unpack_from("<Q", blk, k * 266)[0] == 0))' "$img" "$bx1")"
"$FPOKE" "$img" "$bx1" "$slot" inode "$x" >/dev/null
"$FPOKE" "$img" "$bx1" "$slot" file_type 2 >/dev/null
"$FPOKE" "$img" "$bx1" "$slot" name_len 1 >/dev/null
"$FPOKE" "$img" "$bx1" "$slot" name_byte_0 0x2e >/dev/null
"$IPOKE" "$img" setsize "$x" $((21 * 266)) >/dev/null # '.', '..', 19 names and this one
blockdev --flushbufs "$dev"
ct_mount "$dev" "$MNT"
out="$(CETRAFS_TEST_LIVE_PASSES=1 "$FSCK" --live "$dev" 2>&1 || true)"
ct_umount "$MNT"
grep -q "^ERR: directory inode $x has a '.' entry at logical block 1 slot $slot" <<<"$out" &&
    pass "2: a '.' the directory itself holds out of place is still reported under --live" ||
    fail "2: not reported: $(grep -E '^ERR' <<<"$out" | head -3 | tr '\n' '|')"
ct_exit
