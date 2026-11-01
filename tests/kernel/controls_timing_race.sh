#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the two timing knobs constrain each other, so they must be set as a pair
#
# hb_interval_secs and stale_secs are checked against one another: a
# staleness window shorter than CETRAFS_STALE_MIN_BEATS beats declares a
# healthy peer dead on ordinary jitter, which is the failure the floor
# exists to prevent.
#
# Each knob read the OTHER and then wrote its own, with nothing between
# them. Two writers interleaving in that gap both pass their own check
# and leave the pair broken: from hb=10/stale=60, one setting hb=20
# (60 >= 3x20, fine) and one setting stale=30 (30 >= 3x10 against the
# value it read, fine) ends at hb=20/stale=30.
#
# controls_delay_ms holds that gap open. In production it is a few
# instructions, which is why this survived review.
#
# Discrimination: drop the mutex and the pair below comes out violating
# its own invariant.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 ctlrace)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ctlrace)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

CTL="$(ct_procdir "$DEV")/controls"
INFO="$(ct_procdir "$DEV")/controls"
[ -w "$CTL" ] || fail "no writable controls file at $CTL"

get() { sed -n "s/^$1: *\([0-9]*\).*/\1/p" "$INFO" | head -1; }

# A known starting pair, and the minimum ratio the kernel enforces.
echo "stale_secs=120" > "$CTL"
echo "hb_interval_secs=10" > "$CTL"
HB0="$(get hb_interval_secs)"; ST0="$(get stale_secs)"
[ "$HB0" = "10" ] && [ "$ST0" = "120" ] ||
    fail "could not establish a starting pair (hb=$HB0 stale=$ST0)"

ct_param_set controls_delay_ms 700

# Two writers, deliberately interleaved inside the window.
( echo "hb_interval_secs=30" > "$CTL" ) 2>/dev/null &
A=$!
sleep 0.2
( echo "stale_secs=30" > "$CTL" ) 2>/dev/null &
B=$!
wait "$A" 2>/dev/null || true
wait "$B" 2>/dev/null || true

ct_param_set controls_delay_ms 0

HB="$(get hb_interval_secs)"; ST="$(get stale_secs)"
MIN=$(( HB * 3 ))
echo "after the race: hb_interval_secs=$HB stale_secs=$ST (needs stale >= 3x hb = $MIN)"

[ "$HB" != "$HB0" ] || [ "$ST" != "$ST0" ] ||
    fail "neither writer took effect (hb=$HB stale=$ST unchanged) -- no race happened, so this proves nothing"

[ "$ST" -ge "$MIN" ] &&
    pass "the pair still satisfies its own invariant" ||
    fail "hb=$HB with stale=$ST leaves the staleness window below $MIN -- a healthy peer now looks dead"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
