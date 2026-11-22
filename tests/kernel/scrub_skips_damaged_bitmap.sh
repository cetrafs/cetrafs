#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a damaged data-bitmap block keeps the scrub out of its group, not out of the volume
#
# The scrub read each group's data bitmap whole, and any failure -- a
# sector failing its checksum included -- ended the whole cycle, every
# cycle: one damaged bitmap block and no leak anywhere on the volume was
# reclaimed again, while the allocator, which skips a damaged block, went
# on (audit 2026-11-22 N-64; with the queue-full backoff and the drain,
# one of three ways freed space stopped coming back). A damaged block now
# gives its group no candidates this cycle; an I/O error still stops it.
#
# Staged on one node, one Zone Group of two Block Groups: a sector of
# BG0's data bitmap damaged (its checksum fails), 64 blocks leaked in
# BG1. A fast scrub must reclaim the 64; scrub_bmap_damaged counts BG0.
#
# DISCRIMINATION: the control, in-suite -- scrub_damaged_aborts=1, the
# old abort: nothing is reclaimed in the same wait.
# ct-timeout: 240
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/scrub_damaged_aborts ] || { skip "scrub_damaged_aborts is missing"; ct_exit; }
LEAK="$(ct_helper data_leak_poke)"
BG_POKE="$(ct_helper bg_poke)"
MNT="$(ct_mnt ssdb)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_damaged_aborts 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set trim_quarantine_secs 1

# round <aborts 0|1> -> "<reclaimed> <damaged groups seen>"
round() {
    local dev proc d start bmap r0 m0 r=0
    dev="$(ct_loop "$(ct_image 1200 "ssdb$1")")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$BG_POKE" "$dev" 1 --dump >/dev/null 2>&1 && echo y)" = y ] || { echo "setup: no BG1"; return; }
    d="$("$BG_POKE" "$dev" 0 --dump)"
    start="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d")"
    bmap="$(sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p' <<<"$d")"
    # The last sector of BG0's first bitmap block: high block numbers,
    # nothing allocated there; its checksum now fails.
    printf '\xa5\xa5\xa5\xa5' | dd of="$dev" bs=1 seek=$(((start + bmap) * 4096 + 7 * 512 + 100)) conv=notrunc,fsync status=none
    "$LEAK" "$dev" 1 1000 64 >/dev/null
    blockdev --flushbufs "$dev"
    echo "$1" >/sys/module/cetrafs/parameters/scrub_damaged_aborts
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    r0="$(sed -n 's/^scrub_reclaimed: //p' "$proc/info")"
    m0="$(sed -n 's/^scrub_bmap_damaged: //p' "$proc/info")"
    echo 1 >/sys/module/cetrafs/parameters/scrub
    for _ in $(seq 1 30); do
        r=$(($(sed -n 's/^scrub_reclaimed: //p' "$proc/info") - r0))
        [ "$r" -ge 64 ] && break
        sleep 1
    done
    echo 0 >/sys/module/cetrafs/parameters/scrub
    echo 0 >/sys/module/cetrafs/parameters/scrub_damaged_aborts
    echo "$r $(($(sed -n 's/^scrub_bmap_damaged: //p' "$proc/info") - m0))"
    ct_umount "$MNT"
}

read -r CR CM <<<"$(round 1)"
log "control (abort): reclaimed $CR, damaged groups seen $CM"
read -r R M <<<"$(round 0)"
log "fixed: reclaimed $R, damaged groups seen $M"
[ "${M:-0}" -ge 1 ] && [ "${CM:-0}" -ge 1 ] ||
    { fail "setup: the scrub never met the damaged bitmap ($M, $CM)"; ct_exit; }
[ "${CR:-0}" = 0 ] && pass "control: aborting at the damaged block, none of BG1's leak came back" ||
    fail "control: $CR reclaimed with the abort -- the hazard did not reproduce"
[ "$R" = 64 ] && pass "BG1's 64 leaked blocks reclaimed past BG0's damaged bitmap ($M skip(s))" ||
    fail "reclaimed $R of BG1's 64 leaked blocks"
ct_exit
