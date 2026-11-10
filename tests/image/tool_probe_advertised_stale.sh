#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tool watches a live-looking row for the stale window the nodes advertise, not a fixed 240 s
#
# A tool that must decide a registered row's node is gone (mkfs, fsck,
# growfs) waits as long as the most patient live node would. Before the
# window was on the device it could not know it and waited the legal
# maximum, CETRAFS_STALE_MAX_SECS = 240 s, whatever the cluster ran.
# Each row now advertises its node's stale_secs (format 0x000A).
#
#  A. one row advertising 20 s: fsck watches 20 s, then goes ahead.
#  B. two rows, 20 s and 45 s: the longer one wins.
#  C. a row advertising an illegal 5 s: treated as the maximum, 240 s,
#     never as a short window.
#  D. a row advertising 20 s but beating every 30 s: floored at four of
#     its beats, 120 s.
#
# B..D read the announced window and stop the tool; A runs it through.
#
# DISCRIMINATION: with the fixed window every case announces 240 s, so
# A, B and D fail (C is the control that the maximum still applies).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"
unset CETRAFS_PEER_PROBE_SECS

IMG="$(ct_image 560 probeadv)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" -N 2048 >/dev/null
blockdev --flushbufs "$DEV"

# plant <row> <hb_interval> <stale_secs>: a registered, silent row
plant() {
    "$NPOKE" "$IMG" "$1" 1 "$(printf '%02x' $((0xa0 + $1)))" "$(date +%s)" "$2" >/dev/null
    "$NPOKE" "$IMG" "$1" --stale "$3" >/dev/null
    grep -q "state=1 .*hb_interval=$2 .*stale_secs=$3\$" <<<"$("$NPOKE" "$IMG" "$1")" ||
        { fail "setup: row $1 not planted as interval $2, stale $3: $("$NPOKE" "$IMG" "$1")"; ct_exit; }
}
clear_row() { "$NPOKE" "$IMG" "$1" 0 00 0 >/dev/null; }

# announced: start fsck, return the window it says it will watch, stop it
announced() {
    local err pid w=""
    err="$(ct_tmp probeadv-err)"
    : >"$err"
    blockdev --flushbufs "$DEV"
    "$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>"$err" &
    pid=$!
    for _ in $(seq 1 100); do
        w="$(sed -n 's/.*watching for \([0-9]*\)s.*/\1/p' "$err" | head -1)"
        [ -n "$w" ] && break
        sleep 0.1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "${w:-none}"
}

# ------------------------------------------------------------------- A
log "A: one row advertising 20 s"
plant 1 2 20
blockdev --flushbufs "$DEV"
T0="$(date +%s)"
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" && RC=0 || RC=$?
T1="$(date +%s)"
W="$(sed -n 's/.*watching for \([0-9]*\)s.*/\1/p' <<<"$OUT" | head -1)"
[ "$W" = 20 ] && pass "A: fsck announced the advertised 20 s" || fail "A: fsck announced '${W:-nothing}', not 20 s"
[ "$RC" = 0 ] && [ $((T1 - T0)) -ge 20 ] && [ $((T1 - T0)) -lt 60 ] &&
    pass "A: and went ahead after $((T1 - T0)) s" ||
    fail "A: fsck exited $RC after $((T1 - T0)) s: $(tail -1 <<<"$OUT")"
clear_row 1

# ------------------------------------------------------------------- B
log "B: two rows, 20 s and 45 s"
plant 1 2 20
plant 2 2 45
W="$(announced)"
[ "$W" = 45 ] && pass "B: the longer window wins (45 s)" || fail "B: announced '$W', not 45 s"
clear_row 1; clear_row 2

# ------------------------------------------------------------------- C
log "C: a row advertising an illegal 5 s"
plant 1 2 5
W="$(announced)"
[ "$W" = 240 ] && pass "C: an illegal window counts as the maximum (240 s)" || fail "C: announced '$W', not 240 s"
clear_row 1

# ------------------------------------------------------------------- D
log "D: 20 s advertised, beating every 30 s"
plant 1 30 20
W="$(announced)"
[ "$W" = 120 ] && pass "D: floored at four beats (120 s)" || fail "D: announced '$W', not 120 s"
clear_row 1

ct_exit
