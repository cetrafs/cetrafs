#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock: replay keeps an entry whose file a live node has open
#
# Under nofilelock no lock stops a live node that has the file open from
# writing the block a dead node's entry targets. Between replay's last
# read of the block and the redo landing, that live write could land
# first and be buried under the dead node's older image -- valid, CRC-
# correct, wrong (audit 2026-11-15 M-20). Such an entry is now kept, the
# area left dirty, until the opener closes; when the only opener is the
# replaying node itself, the redo runs under that file's invalidate_lock.
#
# Node 1 is dead with one entry for file v's extent leaf (guarded
# against the leaf as it is, so a redo would apply). The heartbeat's
# sweep replays it:
#   L. node 2, live, has v open for write: kept -- the leaf untouched, counted;
#   R. node 2's presence cleared: applied;
#   O. only this node has v open (an fd held across the sweep): applied.
#
# DISCRIMINATION: journal_live_opener_off=1 (as before): L is applied.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LFPOKE="$(ct_helper leaf_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt jrlo)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set journal_live_opener_off 0
ct_param_set hb_replay_sweep_off 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }
sha() { dd if="$1" bs=4096 skip="$2" count=1 status=none | sha256sum | cut -d' ' -f1; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <tag> <L|R|O> <off 0|1> -> RES
round() {
    local img dir ino p a b ent ph mark k0 o0 now
    img="$(ct_image 560 "jrlo$1")"
    DEV="$(ct_loop "$img")"
    dir="$(ct_tmp "jrlo-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    nfmount "$DEV" "$MNT"
    dd if=/dev/urandom of="$MNT/v" bs=4096 count=60 conv=fsync status=none
    for i in $(seq 1 2 59); do fallocate -p -o $((i * 4096)) -l 4096 "$MNT/v"; done
    sync
    ino="$(stat -c %i "$MNT/v")"
    umount "$MNT"
    p="$("$IPOKE" "$img" leaf "$ino" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
    [ -n "$p" ] || { fail "setup: v has no external leaf"; ct_exit; }
    a="$dir/a" b="$dir/b"
    dd if="$img" of="$a" bs=4096 skip="$p" count=1 status=none
    ent="$("$LFPOKE" "$img" show "$ino" | awk '$3 == "block=0" { print $2; exit }')"
    ph="$("$LFPOKE" "$img" show "$ino" | awk '$3 == "block=0" { sub("phys=", "", $4); print $4; exit }')"
    "$LFPOKE" "$img" setphys "$ino" "$ent" $((ph + 1)) >/dev/null
    dd if="$img" of="$b" bs=4096 skip="$p" count=1 status=none
    dd if="$a" of="$img" bs=4096 seek="$p" count=1 conv=notrunc status=none
    cmp -s "$a" "$b" && { fail "setup: the dead node's image is the leaf as it is"; ct_exit; }
    compress_timing
    poke_dead_peer "$DEV" 1 aa
    "$(ct_helper node_poke)" "$DEV" 1 --mode 2 >/dev/null
    "$JPOKE" "$DEV" 1 0 "$p" "$b" --guard-current >/dev/null
    if [ "$2" != O ]; then
        poke_dead_peer "$DEV" 2 bb
        "$(ct_helper node_poke)" "$DEV" 2 --mode 2 >/dev/null
        # Open for WRITE: only a writer keeps an entry back
        # (journal_replay_writers_only.sh covers the reader).
        "$LPOKE" "$DEV" "$ino" --writer 2 >/dev/null
        [ "$2" = R ] && "$LPOKE" "$DEV" "$ino" --unreader 2 >/dev/null
    fi
    blockdev --flushbufs "$DEV"
    echo "$3" >$P/journal_live_opener_off
    echo 1 >$P/hb_replay_sweep_off # held off until the round is set up
    mark="$(dmesg_mark)"
    nfmount "$DEV" "$MNT"
    [ "$2" != O ] && ct_beat_row "$DEV" 2
    k0="$(info journal_replay_live_kept)" o0="$(info journal_replay_own_opener)"
    [ "$2" = O ] && exec 7<"$MNT/v"
    echo 0 >$P/hb_replay_sweep_off
    wait_for 60 "dmesg_since '$mark' | grep -q 'journal replay: node 1\|is open on a live node'" ||
        { fail "setup: the sweep never reached node 1's journal"; ct_exit; }
    sleep 2
    RES="kept=$(($(info journal_replay_live_kept) - k0)) own=$(($(info journal_replay_own_opener) - o0))"
    [ "$2" = O ] && exec 7<&-
    ct_unbeat
    echo 0 >$P/journal_live_opener_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    reset_stale_window
    now="$(sha "$img" "$p")"
    if [ "$now" = "$(sha256sum <"$b" | cut -d' ' -f1)" ]; then now=applied
    elif [ "$now" = "$(sha256sum <"$a" | cut -d' ' -f1)" ]; then now=untouched
    else now=other; fi
    RES="$RES leaf=$now"
}

round l L 0
L="$RES"
log "L (node 2 live with v open): $L"
round r R 0
R="$RES"
log "R (no other opener): $R"
round o O 0
O="$RES"
log "O (only this node has v open): $O"
round c L 1
C="$RES"
log "control (live opener ignored): $C"
[ "$(get leaf "$L")" = untouched ] && [ "$(get kept "$L")" -ge 1 ] &&
    pass "L: a live node had the file open -- the entry kept, the leaf untouched" || fail "L: $L"
[ "$(get leaf "$R")" = applied ] && pass "R: with no other opener the entry was redone" || fail "R: $R"
[ "$(get leaf "$O")" = applied ] && [ "$(get kept "$O")" = 0 ] && [ "$(get own "$O")" -ge 1 ] &&
    pass "O: this node's own opener -- redone under its invalidate_lock" || fail "O: $O"
[ "$(get leaf "$C")" = applied ] &&
    pass "control: as before, the redo ran under the live opener" ||
    fail "control: not applied without the change -- the suite does not reach it: $C"
ct_exit
