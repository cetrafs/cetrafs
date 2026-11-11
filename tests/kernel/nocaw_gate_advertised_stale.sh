#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the no-CAW mount gate watches a silent row for the window its node advertises, not this mount's own
#
# A device with no atomic CAW may be mounted by one node only, and the
# gate that decides it watches every registered row for a while before
# calling its node dead. It watched for THIS mount's stale window, floored
# at four of the row's beats -- so a peer running a 240 s window was
# declared dead by a mounter running 15 s, after 60 s of silence. Each row
# advertises its node's stale_secs (format 0x000A) and the tools already
# wait the longest one (tool_probe_advertised_stale.sh); the kernel's
# watches now do too (review F2): the gate, the live-peer walk and the
# twin watch at registration share cetrafs_row_watch_window().
#
#  A. compressed timing (our window 3 s), a silent row advertising 20 s:
#     the gate announces 20 s and waits it out before mounting.
#  B. the same with the row advertising nothing (0): our compressed window
#     stands -- the one exception, for a node whose own window only a
#     test knob can set.
#  C. ordinary timing, a row advertising an illegal 5 s: counted as the
#     maximum, 240 s -- garbage makes us wait longer, never act sooner.
#  D. ordinary timing (our window 60 s), a row advertising 30 s: ours is
#     the longer, and it stands.
#
# C and D read the announced window and stop the mount (the wait is
# killable); A runs it through.
#
# DISCRIMINATION (2026-11-11, cetrafs_row_watch_window() reduced to the
# old floor): A announces 3 s and mounts after 3, C announces 60 s.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 nocawadv)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nocawadv)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"

# plant <stale_secs>: row 1, registered, foreign, silent.
plant() {
    "$POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    "$POKE" "$DEV" 1 --stale "$1" >/dev/null
    blockdev --flushbufs "$DEV"
    grep -q "state=1 .*stale_secs=$1\$" <<<"$("$POKE" "$DEV" 1)" ||
        { fail "setup: row 1 not planted advertising $1 s: $("$POKE" "$DEV" 1)"; ct_exit; }
}
# announced <mark>: the window the gate said it would watch.
announced() { dmesg_since "$1" | sed -n 's/.*waiting \([0-9]*\)s to see whether .* still heartbeating.*/\1/p' | tail -1; }

# stop_at_announce: mount in the background, read the announced window,
# then kill the mount. Sets WIN.
stop_at_announce() {
    local mark mp
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null &
    mp=$!
    wait_for 30 "[ -n \"\$(announced '$mark')\" ]" || { fail "setup: the gate announced no window"; kill -9 "$mp" 2>/dev/null; wait "$mp" || true; ct_exit; }
    WIN="$(announced "$mark")"
    kill -9 "$mp" 2>/dev/null || true
    wait "$mp" 2>/dev/null && { umount "$MNT"; fail "setup: the mount finished before it could be stopped"; } || true
    mountpoint -q "$MNT" && umount "$MNT"
    return 0
}

# ------------------------------------------------------------------- A
log "A: compressed timing, a row advertising 20 s"
compress_timing
plant 20
MARK="$(dmesg_mark)"
T0="$(date +%s)"
ct_mount "$DEV" "$MNT"
T1="$(date +%s)"
require_cetrafs_mount "$MNT"
[ "$(announced "$MARK")" = 20 ] && pass "A: the gate watched for the row's advertised 20 s" ||
    fail "A: the gate announced $(announced "$MARK") s, not the row's 20 s"
[ $((T1 - T0)) -ge 19 ] && pass "A: and waited it out ($((T1 - T0)) s) before calling the row dead" ||
    fail "A: the mount went ahead after $((T1 - T0)) s, inside the row's window"
ct_umount "$MNT"

# ------------------------------------------------------------------- B
log "B: compressed timing, a row advertising nothing"
plant 0
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
W="$(announced "$MARK")"
[ -n "$W" ] && [ "$W" -lt 20 ] && pass "B: our compressed window stands for a planted row ($W s)" ||
    fail "B: a row advertising nothing made a compressed-timing mount wait ${W:-?} s"
ct_umount "$MNT"
reset_stale_window

# ------------------------------------------------------------------- C
log "C: ordinary timing, a row advertising an illegal 5 s"
plant 5
stop_at_announce
[ "$WIN" = 240 ] && pass "C: an illegal advertised window counts as the maximum (240 s)" ||
    fail "C: the gate announced $WIN s for a row advertising an illegal 5 s"

# ------------------------------------------------------------------- D
log "D: ordinary timing, a row advertising less than ours"
plant 30
stop_at_announce
OURS="$(cat /sys/module/cetrafs/parameters/stale_secs)"
[ "$WIN" = "$OURS" ] && pass "D: our own longer window stands ($WIN s)" ||
    fail "D: the gate announced $WIN s; ours is $OURS, the row's 30"
"$POKE" "$DEV" 1 0 00 0 >/dev/null
ct_exit
