#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rebuilt extent leaf never repeats an earlier leaf's bytes, so a dead node's redo cannot mistake it for its own "before" image
#
# Journal redo applies a dead node's entry when the target's CRC equals
# the entry's prev_checksum: "the write never landed". An extent leaf's
# bytes are only its entries and a tail, and a tree rebuild that comes
# out with the same entries writes the same bytes into whatever block it
# was given: a leaf rebuilt into a block a dead node's entry names reads
# as that entry's before-image, the owner and allocation checks pass
# (the file does reference it, it is allocated), and the redo puts the
# dead node's leaf over the live one -- extents over blocks the live
# node freed. nofilelock, the dead node's journal replayed by a
# survivor's sweep (audit 2026-11-11 J1). Every leaf/index write now
# draws a fresh eh_generation.
#
# Played on one node: a file with an external leaf; a cycle (punch the
# tail, write into it, punch it again) rebuilds the leaf into a new block
# with the same entries each time. Cycle 1 leaves it at P1 (bytes A),
# cycle 2 at P2. A dead peer's entry against P2 is planted with A as its
# guard -- the image a rebuild repeats -- and a payload B (A with block
# 0's extent moved). The survivor's replay then judges P2.
#
#  1. the stamp on: P2's bytes are not A's; the entry is refused and P2
#     is untouched.
#  2. CONTROL, ext_gen_stamp_off: P2's bytes ARE A's, and the redo puts B
#     over the live leaf -- the corruption 1 prevents.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in ext_gen_stamp_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 jaba)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jaba)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0

mnt_nfl() { mount -t cetrafs -o nofilelock "$DEV" "$MNT" && ct_track mnt "$MNT"; }
leaf() { "$IPOKE" "$IMG" leaf "$INO" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p'; }
blk() { dd if="$IMG" bs=4096 skip="$1" count=1 status=none | sha256sum | cut -d' ' -f1; }
cyc() {
    fallocate -p -o $((150 * 4096)) -l $((20 * 4096)) "$MNT/v"
    dd if=/dev/urandom of="$MNT/v" bs=4096 seek=150 count=10 conv=notrunc,fsync status=none
    fallocate -p -o $((150 * 4096)) -l $((10 * 4096)) "$MNT/v"
    sync
}

# play: stage, plant, replay. Sets SAME (P2 held A's bytes), KEPT (P2
# untouched by the replay), APPLIED (P2 now holds B).
play() {
    local a b r ent p1 p2 mark
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mnt_nfl
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/v" bs=4096 count=160 conv=fsync status=none
    for i in $(seq 1 2 159); do fallocate -p -o $((i * 4096)) -l 4096 "$MNT/v"; done
    sync
    INO="$(stat -c %i "$MNT/v")"
    cyc
    ct_umount "$MNT"
    p1="$(leaf)"
    a="$(ct_tmp jaba-a)"; dd if="$IMG" of="$a" bs=4096 skip="$p1" count=1 status=none
    mnt_nfl
    cyc
    ct_umount "$MNT"
    p2="$(leaf)"
    [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ] ||
        { fail "setup: the cycle did not rebuild the leaf into a new block ($p1 -> $p2)"; ct_exit; }
    r="$(ct_tmp jaba-r)"; dd if="$IMG" of="$r" bs=4096 skip="$p2" count=1 status=none
    cmp -s "$a" "$r" && SAME=1 || SAME=0
    # B: A with block 0's extent pointing one block on -- a valid leaf
    # for this file that the device does not hold, as a dead node's
    # entry would carry.
    ent="$("$LPOKE" "$IMG" show "$INO" | awk '$3 == "block=0" && !done { print $2; done = 1 }')"
    [ -n "$ent" ] || { fail "setup: no leaf entry maps block 0"; ct_exit; }
    "$LPOKE" "$IMG" setphys "$INO" "$ent" "$(("$("$LPOKE" "$IMG" show "$INO" | awk '$3 == "block=0" { sub("phys=", "", $4); print $4; exit }')" + 1))" >/dev/null
    b="$(ct_tmp jaba-b)"; dd if="$IMG" of="$b" bs=4096 skip="$p2" count=1 status=none
    # Plant against P2 with A as its guard, then give P2 its real bytes.
    dd if="$a" of="$IMG" bs=4096 seek="$p2" count=1 conv=notrunc status=none
    compress_timing
    poke_dead_peer "$DEV" 1 aa
    "$JPOKE" "$DEV" 1 0 "$p2" "$b" --guard-current >/dev/null
    dd if="$r" of="$IMG" bs=4096 seek="$p2" count=1 conv=notrunc status=none
    blockdev --flushbufs "$DEV"
    mark="$(dmesg_mark)"
    mnt_nfl
    wait_for 60 "dmesg_since '$mark' | grep -q 'journal replay: node 1'" ||
        { fail "setup: the dead node's journal was never replayed: $(dmesg_since "$mark" | grep -i journal | tail -2)"; ct_exit; }
    sleep 2
    ct_umount "$MNT"
    reset_stale_window
    [ "$(blk "$p2")" = "$(sha256sum <"$r" | cut -d' ' -f1)" ] && KEPT=1 || KEPT=0
    [ "$(blk "$p2")" = "$(sha256sum <"$b" | cut -d' ' -f1)" ] && APPLIED=1 || APPLIED=0
    LOG="$(dmesg_since "$mark" | grep 'journal replay' | tail -3)"
}

# ------------------------------------------------------------------- 1
log "1: every leaf write draws a fresh eh_generation"
play
[ "$SAME" = 0 ] && pass "1: the rebuilt leaf's bytes differ from the earlier leaf's, entries the same" ||
    fail "1: two rebuilds wrote byte-identical leaves"
[ "$KEPT" = 1 ] && pass "1: the dead node's entry was refused; the live leaf is untouched" ||
    { [ "$APPLIED" = 1 ] && fail "1: the redo put the dead node's leaf over the live one: $LOG" ||
        fail "1: the live leaf changed to something else: $LOG"; }

# ------------------------------------------------------------------- 2
log "2: CONTROL -- leaves written without the stamp"
ct_param_set ext_gen_stamp_off 1
play
ct_param_set ext_gen_stamp_off 0
[ "$SAME" = 1 ] && [ "$APPLIED" = 1 ] &&
    pass "2: unstamped, the rebuild repeated A's bytes and the redo put B over the live leaf -- what 1 prevents" ||
    fail "2: the control did not reproduce the redo (same $SAME, applied $APPLIED): $LOG -- 1 proves nothing"
ct_exit
