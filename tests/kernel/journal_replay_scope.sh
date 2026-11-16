#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock: a dead node's entry kept for a live opener blocks only its file
#
# Replay keeps an entry whose file a live node has open (audit 2026-11-15
# M-20, journal_replay_live_opener.sh), and a kept entry leaves the area
# dirty. Every replay caller treated that as "replay failed", so one VM
# image held open on a live node refused the open of EVERY other file the
# dead node had open -- HA could restart none of its VMs -- and every Zone
# Group claim and namespace reclaim waiting on that node (F-37). Now such
# a replay succeeds for every caller except the one that needs THAT file.
#
# The area stays dirty, and a kept entry's payload can name blocks no
# tree references yet: the scrub must not judge them leaked while it is.
#
# Node 1 is dead with one entry for file v's extent leaf; node 2, live,
# has v open, so the entry is kept. Its image points v's first extent at
# a block the dead node "allocated" (bit set) and nothing else references.
#   S. an open of w (node 1 had it open) succeeds; an open of v is refused;
#   G. the scrub skips while node 1's journal is dirty; once node 2 closes
#      v and the entry is redone, the block it names is still in use.
#
# DISCRIMINATION: journal_scope_off=1: S refuses the open of w.
# scrub_ignores_dead_journal=1: the scrub frees the block and the redo
# publishes an extent over a FREE block (fsck: "marked FREE").
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LFPOKE="$(ct_helper leaf_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
LEAK="$(ct_helper data_leak_poke)"
BGMAP="$(ct_helper bg_map)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt jrsc)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set journal_live_opener_off 0
ct_param_set journal_scope_off 0
ct_param_set scrub_ignores_dead_journal 0
ct_param_set hb_replay_sweep_off 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <tag> <S|G> -> IMG DEV INO; node 1 dead with an entry for v's leaf
# pointing extent 0 at a block nothing references; node 2 has v open.
setup() {
    local dir p a b ent ph tgt bg base w out
    IMG="$(ct_image 560 "jrsc$1")"
    DEV="$(ct_loop "$IMG")"
    dir="$(ct_tmp "jrsc-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    nfmount "$DEV" "$MNT"
    dd if=/dev/urandom of="$MNT/v" bs=4096 count=60 conv=fsync status=none
    for i in $(seq 1 2 59); do fallocate -p -o $((i * 4096)) -l 4096 "$MNT/v"; done
    echo w >"$MNT/w"
    sync
    INO="$(stat -c %i "$MNT/v")"
    w="$(stat -c %i "$MNT/w")"
    umount "$MNT"
    p="$("$IPOKE" "$IMG" leaf "$INO" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
    [ -n "$p" ] || { fail "setup: v has no external leaf"; ct_exit; }
    a="$dir/a" b="$dir/b"
    dd if="$IMG" of="$a" bs=4096 skip="$p" count=1 status=none
    ent="$("$LFPOKE" "$IMG" show "$INO" | awk '$3 == "block=0" { print $2; exit }')"
    ph="$("$LFPOKE" "$IMG" show "$INO" | awk '$3 == "block=0" { sub("phys=", "", $4); print $4; exit }')"
    tgt=$((ph + 1))
    "$LFPOKE" "$IMG" setphys "$INO" "$ent" "$tgt" >/dev/null
    dd if="$IMG" of="$b" bs=4096 skip="$p" count=1 status=none
    dd if="$a" of="$IMG" bs=4096 seek="$p" count=1 conv=notrunc status=none
    cmp -s "$a" "$b" && { fail "setup: the dead node's image is the leaf as it is"; ct_exit; }
    if [ "$2" = G ]; then
        # The block the dead node's image names: allocated, referenced by
        # nothing on the device -- what its last tree write leaves.
        bg="$("$BGMAP" "$IMG" | awk -v t="$tgt" '$1 == "bg" { sub("start=", "", $4); if ($4 + 0 <= t) id = $2 } END { print id }')"
        base="$("$LEAK" "$IMG" "$bg" 0 0 | sed -n 's/.* lba \([0-9]*\)$/\1/p')"
        [ -n "$base" ] && [ "$tgt" -ge "$base" ] || { fail "setup: no data offset for lba $tgt"; ct_exit; }
        "$LEAK" "$IMG" "$bg" $((tgt - base)) 1 >/dev/null
        blockdev --flushbufs "$DEV"
        out="$(ct_fsck "$DEV" 2>&1 || true)"
        echo "$out" | grep -q " 1 leaked" ||
            { fail "setup: lba $tgt does not read as the one leaked block: $(echo "$out" | grep -E 'leaked|^(ERR|WARN)' | head -3)"; ct_exit; }
    fi
    compress_timing
    poke_dead_peer "$DEV" 1 aa
    "$(ct_helper node_poke)" "$DEV" 1 --mode 2 >/dev/null
    "$JPOKE" "$DEV" 1 0 "$p" "$b" --guard-current >/dev/null
    poke_dead_peer "$DEV" 2 bb
    "$(ct_helper node_poke)" "$DEV" 2 --mode 2 >/dev/null
    "$LPOKE" "$DEV" "$INO" --reader 2 >/dev/null
    if [ "$2" = S ]; then
        "$LPOKE" "$DEV" "$INO" --reader 1 >/dev/null
        "$LPOKE" "$DEV" "$w" --reader 1 >/dev/null
    fi
    blockdev --flushbufs "$DEV"
}

# <tag> <scope_off> -> RES
round_s() {
    local w0 v0
    setup "$1" S
    echo "$2" >$P/journal_scope_off
    echo 1 >$P/hb_replay_sweep_off # only the opens replay
    nfmount "$DEV" "$MNT"
    ct_beat_row "$DEV" 2
    wait_out_stale_window
    w0=fail v0=fail
    cat "$MNT/w" >/dev/null 2>&1 && w0=ok
    cat "$MNT/v" >/dev/null 2>&1 && v0=ok
    RES="w=$w0 v=$v0 scoped=$(info journal_replay_scoped_ok)"
    ct_unbeat
    echo 0 >$P/journal_scope_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/hb_replay_sweep_off
    reset_stale_window
}

# <tag> <ignore 0|1> -> RES
round_g() {
    local r0 s0 mark out
    setup "$1" G
    echo "$2" >$P/scrub_ignores_dead_journal
    echo 1 >$P/hb_replay_sweep_off # the kept entry stays kept: node 2 has v open
    nfmount "$DEV" "$MNT"
    ct_beat_row "$DEV" 2
    wait_out_stale_window
    r0="$(info scrub_reclaimed)" s0="$(info scrub_dead_journal_skips)"
    ct_param_set scrub 1
    wait_for 30 "[ \$((\$(info scrub_reclaimed) - $r0)) -gt 0 ] || [ \$((\$(info scrub_dead_journal_skips) - $s0)) -gt 2 ]" || true
    ct_param_set scrub 0
    RES="reclaimed=$(($(info scrub_reclaimed) - r0)) skips=$(($(info scrub_dead_journal_skips) - s0))"
    ct_unbeat
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/scrub_ignores_dead_journal
    reset_stale_window
    # Node 2 closes v: the entry is redone by the next sweep.
    "$LPOKE" "$DEV" "$INO" --unreader 2 >/dev/null
    compress_timing
    poke_dead_peer "$DEV" 1 aa
    blockdev --flushbufs "$DEV"
    echo 0 >$P/hb_replay_sweep_off
    mark="$(dmesg_mark)"
    nfmount "$DEV" "$MNT"
    wait_for 60 "dmesg_since '$mark' | grep -q 'journal replay: node 1'" ||
        { fail "setup: the sweep never redid node 1's entry"; ct_exit; }
    sleep 2
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    reset_stale_window
    blockdev --flushbufs "$DEV"
    out="$(ct_fsck "$DEV" 2>&1 || true)"
    if echo "$out" | grep -q "marked FREE"; then RES="$RES fsck=shared"
    else RES="$RES fsck=ok"; fi
}

round_s s 0
S="$RES"
log "S (scoped): $S"
round_s sc 1
SC="$RES"
log "S control (every caller strict): $SC"
round_g g 0
G="$RES"
log "G (scrub guarded): $G"
round_g gc 1
GC="$RES"
log "G control (scrub ignores the dead journal): $GC"

[ "$(get w "$S")" = ok ] && pass "S: a file the kept entry is not for opens" || fail "S: $S"
[ "$(get v "$S")" = fail ] && pass "S: the file the kept entry is for is still refused" || fail "S: $S"
[ "$(get w "$SC")" = fail ] &&
    pass "S control: as before, the kept entry refused the other file too" ||
    fail "S control: w opened without the change -- the suite does not reach it: $SC"
[ "$(get reclaimed "$G")" = 0 ] && [ "$(get skips "$G")" -ge 1 ] &&
    pass "G: the scrub freed nothing while the dead node's journal was dirty" || fail "G: $G"
[ "$(get fsck "$G")" = ok ] && pass "G: the redone extent names a block still in use" || fail "G: $G"
[ "$(get reclaimed "$GC")" -ge 1 ] && [ "$(get fsck "$GC")" = shared ] &&
    pass "G control: the scrub freed the block and the redo published it FREE" ||
    fail "G control: the hazard did not reproduce -- the suite does not reach it: $GC"
ct_exit
