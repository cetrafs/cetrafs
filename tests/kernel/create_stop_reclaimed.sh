#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create that stops between its inode bit and its record is reclaimed online
#
# A create takes the number's bit, claims its record, then writes it. A
# node that stopped after the bit left whatever the slot held: zeros on
# a fresh volume, and an all-zero record is UNKNOWN to every walk that
# frees (a live record read back as zeros is the same bytes, review
# F-11). So every node's scrub freed nothing, every cycle, until an
# offline fsck -r (audit 2026-11-15 F-12). mkfs now writes every slot as
# a dead record, so a stop leaves one of those, which the orphan scrub
# reclaims like any other.
#
# Staged on the unmounted image, then two scrub cycles:
#   A. a free number's bit set, its slot as mkfs left it (stopped after
#      the bit): the scrub runs, meets no unknown record, and reclaims
#      the number; fsck clean;
#   B. the same, its record also claimed by a dead peer (stopped after
#      the birth claim): the peer is fenced, the claim taken over and the
#      number reclaimed; fsck clean.
#
# DISCRIMINATION: the slot zeroed, as mkfs used to leave it: the scrub
# meets an unknown record every cycle and the number stays allocated.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
SB_POKE="$(ct_helper sb_poke)"
BMAP_POKE="$(ct_helper bmap_poke)"
MNT="$(ct_mnt csr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
P=/sys/module/cetrafs/parameters
N=500 # a number no create here reaches

# <image> <ino> -> 0|1, the number's bit
ibit() {
    "$BMAP_POKE" "$1" "$inode_bmap_start" "$(($2 - 1))"
}
# <image> <ino>: set it
iset() {
    "$BMAP_POKE" "$1" "$inode_bmap_start" "$(($2 - 1))" 1
}
info() { sed -n "s/^$1: //p" "$PROC/info"; }

# <tag> <slot: mkfs|zero> <claim: none|dead> -> RES
round() {
    local img dev c0 u0 o0 dl before
    img="$(ct_image 560 "csr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=16 conv=fsync status=none
    ct_umount "$MNT"
    eval "$("$SB_POKE" "$img" | grep -E '^inode_(table|bmap)_start=')"
    before="$(ibit "$img" "$N")"
    iset "$img" "$N"
    [ "$2" = zero ] && dd if=/dev/zero of="$img" bs=4096 seek=$((inode_table_start + N - 1)) count=1 conv=notrunc,fsync status=none
    if [ "$3" = dead ]; then
        "$LOCK_POKE" "$img" "$N" --ns 1 >/dev/null
        poke_dead_peer "$dev" 1 bb
    fi
    echo 1 >$P/scrub
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    c0="$(info scrub_cycles)" u0="$(info scrub_unknown_records)" o0="$(info scrub_orphan_inodes_reclaimed)"
    [ "$3" = dead ] && wait_out_stale_window
    dl=$((SECONDS + 90))
    while [ "$(info scrub_cycles)" -lt $((c0 + 2)) ] && [ "$(info scrub_unknown_records)" -lt $((u0 + 2)) ] &&
        [ "$SECONDS" -lt "$dl" ]; do
        sleep 1
    done
    RES="before=$before cycles=$(($(info scrub_cycles) - c0)) unknown=$(($(info scrub_unknown_records) - u0))"
    RES="$RES orphans=$(($(info scrub_orphan_inodes_reclaimed) - o0))"
    ct_umount "$MNT"
    echo 0 >$P/scrub
    RES="$RES after=$(ibit "$img" "$N") fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round a mkfs none
A="$RES"
log "A (stopped after the bit): $A"
round b mkfs dead
B="$RES"
log "B (stopped after a dead peer's birth claim): $B"
round c zero none
C="$RES"
log "control (zeroed slot, as mkfs used to leave it): $C"
[ "$(get before "$A")" = 0 ] && [ "$(get before "$B")" = 0 ] || { fail "setup: ino $N was already allocated"; ct_exit; }
[ "$(get cycles "$A")" -ge 2 ] && [ "$(get unknown "$A")" = 0 ] && [ "$(get after "$A")" = 0 ] &&
    [ "$(get orphans "$A")" -ge 1 ] && [ "$(get fsck_err "$A")" = 0 ] &&
    pass "A: the scrub ran $(get cycles "$A") cycles, met nothing unknown, and reclaimed the number; fsck clean" ||
    fail "A: $A"
[ "$(get cycles "$B")" -ge 2 ] && [ "$(get unknown "$B")" = 0 ] && [ "$(get after "$B")" = 0 ] &&
    [ "$(get orphans "$B")" -ge 1 ] && [ "$(get fsck_err "$B")" = 0 ] &&
    pass "B: the dead peer's birth claim was taken over and the number reclaimed; fsck clean" ||
    fail "B: $B"
[ "$(get unknown "$C")" -ge 2 ] && [ "$(get after "$C")" = 1 ] &&
    pass "control: over a zeroed slot every cycle met an unknown record and the number stayed allocated" ||
    fail "control: the zeroed slot did not stop the scrub ($C) -- the suite cannot see the stall"
ct_exit
