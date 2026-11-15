#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an undecidable replay entry is kept on its own; the rest of the area is replayed, in order per block
#
# One entry replay could not decide -- a target it could not place, an
# owner it could not read, a write the device refused -- aborted the
# whole area, so every other block the area would have repaired waited
# for that one entry (audit 2026-11-15 A-10, B-6). Now the entry is kept,
# the area stays DIRTY for the next replay, and the rest is redone.
#
# Keeping entries apart needs one order kept: two entries for the same
# block are a chain, the newer guarded against what the older puts
# there. Judged while the older one waits, the newer read CHANGED and
# was consumed unapplied, and the older redo then left the block at the
# older image -- the newer write lost. A newer entry now waits behind an
# older one for its block.
#
# Node 1 is a dead peer whose area holds three entries: E1 and E2 a
# chain on the root's dirent block (s0 -> s1 -> s2), E3 on another
# directory's (d0 -> d1). This node's heartbeat sweep replays it.
#   K. the first replay cannot place E1 (journal_replay_lookup_fail=1):
#      E3 is redone at once, E1 and E2 are kept, the area stays DIRTY;
#      a later sweep redoes the chain -- root at s2, CLEAN, fsck clean;
#   D. E1's owner cannot be read on the first pass
#      (journal_owner_read_fail=5): it waits, E2 waits behind it, and
#      the root ends at s2, not s1.
#
# DISCRIMINATION: journal_kept_aborts=1 (K): the first replay redoes
# nothing -- E3's block is still d0. journal_unordered=1 (D): the root
# ends at s1, E2's write lost.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_kept_aborts journal_unordered journal_replay_lookup_fail journal_owner_read_fail; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt jrk)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set journal_kept_aborts 0
ct_param_set journal_unordered 0
ct_param_set journal_replay_lookup_fail 0
ct_param_set journal_owner_read_fail 0
compress_timing

get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }
first_target() { dmesg_since "$1" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1; }
blk() { dd if="$1" of="$3" bs=4096 skip="$2" count=1 iflag=direct status=none; }
put() { dd if="$3" of="$1" bs=4096 seek="$2" count=1 oflag=direct conv=notrunc status=none; }
# which image block <lba> of <dev> holds now: the name of the matching file, or "other"
which_img() {
    local cur n
    cur="$(ct_tmp "jrk-cur")"
    blk "$1" "$2" "$cur"
    shift 2
    for n in "$@"; do cmp -s "$cur" "$n" && { basename "$n"; return; }; done
    echo other
}
state() { "$JPOKE" "$1" 1 --dump | head -1 | sed -n 's/^state=\([0-9]*\).*/\1/p'; }

# <tag> <knob> <value> <control knob 0|1> -> RES
round() {
    local img dev mark t d dir ctl
    img="$(ct_image 560 "jrk$1")"
    dev="$(ct_loop "$img")"
    dir="$(ct_tmp "jrk-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    touch "$MNT/d/x0"
    mark="$(dmesg_mark)"
    touch "$MNT/d/x1"
    d="$(first_target "$mark")"
    mark="$(dmesg_mark)"
    touch "$MNT/alpha"
    t="$(first_target "$mark")"
    ct_umount "$MNT"
    [ -n "$t" ] && [ -n "$d" ] && [ "$t" != "$d" ] ||
        { fail "setup: no distinct journal targets logged (root=$t d=$d)"; ct_exit; }
    blk "$dev" "$t" "$dir/s0"
    blk "$dev" "$d" "$dir/d0"
    ct_mount "$dev" "$MNT"
    touch "$MNT/beta"
    ct_umount "$MNT"
    blk "$dev" "$t" "$dir/s1"
    ct_mount "$dev" "$MNT"
    touch "$MNT/gamma" "$MNT/d/x2"
    ct_umount "$MNT"
    blk "$dev" "$t" "$dir/s2"
    blk "$dev" "$d" "$dir/d1"
    ! cmp -s "$dir/s0" "$dir/s1" && ! cmp -s "$dir/s1" "$dir/s2" && ! cmp -s "$dir/d0" "$dir/d1" ||
        { fail "setup: the creates did not change the dirent blocks"; ct_exit; }
    # node 1 died before any of the three redos landed
    put "$dev" "$t" "$dir/s0"
    put "$dev" "$d" "$dir/d0"
    poke_dead_peer "$dev" 1 aa
    JOURNAL_POKE_TXN=1 "$JPOKE" "$dev" 1 0 "$t" "$dir/s1" --guard-current >/dev/null
    JOURNAL_POKE_TXN=2 JOURNAL_POKE_PREV_FROM="$dir/s1" "$JPOKE" "$dev" 1 1 "$t" "$dir/s2" --guard-current >/dev/null
    JOURNAL_POKE_TXN=3 "$JPOKE" "$dev" 1 2 "$d" "$dir/d1" --guard-current >/dev/null
    [ "$(state "$dev")" = 1 ] || { fail "setup: the planted entries did not dirty node 1's area"; ct_exit; }

    echo "$4" >"$P/$( [ "$2" = journal_replay_lookup_fail ] && echo journal_kept_aborts || echo journal_unordered)"
    echo "$3" >"$P/$2"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    # the first replay ends in its summary line -- or, aborted, in the abort
    ctl='journal replay: node 1 replayed'
    [ "$4" = 1 ] && ctl="$ctl\\|could not tell where target"
    wait_for 60 "dmesg_since '$mark' | grep -q '$ctl'" || true
    sleep 1
    RES="first_root=$(which_img "$dev" "$t" "$dir/s0" "$dir/s1" "$dir/s2")"
    RES="$RES first_d=$(which_img "$dev" "$d" "$dir/d0" "$dir/d1") first_state=$(state "$dev")"
    RES="$RES kept_logged=$(dmesg_since "$mark" | grep -c 'kept undecided' || true)"
    echo 0 >"$P/$2"
    echo 0 >$P/journal_kept_aborts
    echo 0 >$P/journal_unordered
    wait_for 90 "[ \"\$(\"$JPOKE\" '$dev' 1 --dump | head -1 | sed -n 's/^state=\([0-9]*\).*/\1/p')\" = 0 ]" || true
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    ct_umount "$MNT"
    RES="$RES end_root=$(which_img "$dev" "$t" "$dir/s0" "$dir/s1" "$dir/s2")"
    RES="$RES end_d=$(which_img "$dev" "$d" "$dir/d0" "$dir/d1") end_state=$(state "$dev")"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round kc journal_replay_lookup_fail 1 1
KC="$RES"
log "K control (one entry aborts the area): $KC"
round k journal_replay_lookup_fail 1 0
K="$RES"
log "K: $K"
round dc journal_owner_read_fail 5 1
DC="$RES"
log "D control (judged past an older entry): $DC"
round d journal_owner_read_fail 5 0
D="$RES"
log "D: $D"

[ "$(get first_state "$K")" = 1 ] && [ "$(get kept_logged "$K")" -ge 1 ] ||
    { fail "setup: the first replay of K kept nothing ($K)"; ct_exit; }
[ "$(get first_d "$K")" = d1 ] && [ "$(get first_root "$K")" = s0 ] && [ "$(get stopped "$K")" = 0 ] &&
    pass "K1: the first replay redid E3 and kept the chain; the area stayed DIRTY" || fail "K1: $K"
[ "$(get end_root "$K")" = s2 ] && [ "$(get end_d "$K")" = d1 ] && [ "$(get end_state "$K")" = 0 ] &&
    [ "$(get fsck_err "$K")" = 0 ] &&
    pass "K2: a later sweep redid E1 then E2 -- root at s2, area CLEAN, fsck clean" || fail "K2: $K"
[ "$(get first_d "$KC")" = d0 ] &&
    pass "K control: with one entry aborting the area, the first replay redid nothing" ||
    fail "K control: E3 was redone with the abort on ($KC) -- the suite does not see the keep"
[ "$(get end_root "$D")" = s2 ] && [ "$(get end_d "$D")" = d1 ] && [ "$(get end_state "$D")" = 0 ] &&
    [ "$(get fsck_err "$D")" = 0 ] &&
    pass "D: E2 waited behind E1's deferral; the root ends at s2; fsck clean" || fail "D: $D"
[ "$(get end_root "$DC")" = s1 ] &&
    pass "D control: judged past the waiting E1, E2 was consumed unapplied and the root ended at s1" ||
    fail "D control: the chain survived without the ordering ($DC) -- the suite does not reach it"
ct_exit
