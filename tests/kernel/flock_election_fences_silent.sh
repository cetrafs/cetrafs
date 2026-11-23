#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the file-lock-mode election fences a peer it judged dead instead of only skipping it
#
# The first writer to mount sets the cluster's file-lock mode, and a
# mount watches every live peer whose mode differs. One that never beats
# for the window is dead and imposes nothing -- but it was only skipped:
# no lease revoked, no departure recorded. A peer that was merely stalled
# then resumed in its old mode (lock ON) beside a cluster that had gone
# OFF, until some reclaim happened to bump its epoch (audit 2026-11-22
# N-58). The election now publishes its verdict as the no-CAW gate does.
#
# A volume on a LIO disk (atomic CAW, so the no-CAW gate, which fences on
# its own, is out of the way), with a foreign row planted: registered,
# lock ON, never beating. A nofilelock mount:
#   1. leads with lock OFF (the silent row imposed nothing);
#   2. revoked the row's lease and recorded it DEAD, as a reclaim.
# A read-only nofilelock mount over a fresh plant writes nothing to it.
#
# DISCRIMINATION: election_silent_unfenced=1 (as before): the mount leads
# OFF and the row is left as planted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/election_silent_unfenced ] || { skip "election_silent_unfenced is missing"; ct_exit; }
[ -z "${CT_MOUNT_OPTS:-}" ] || { skip "mounts with its own options"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt fefs)"
ct_track mnt "$MNT"
ct_param_set election_silent_unfenced 0
ct_param_set stale_secs "$TEST_STALE_SECS"
ct_param_set hb_interval_secs 1
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <unfenced 0|1> <ro 0|1> -> RES "caw= mode= fence_epoch= departure= fence_reason="
round() {
    local img disk mark opts=nofilelock row
    img="$(ct_image 560 "fefs$1")"
    disk="$(ct_lio_disks "$img" 1)" || { skip "no LIO loopback target here"; ct_exit; }
    ct_mkfs "$disk" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    # row 1: another machine, lock ON, beating every second -- and never again
    "$NPOKE" "$img" 1 1 bb "$(date +%s)" 1 >/dev/null
    "$NPOKE" "$img" 1 --mode 1 >/dev/null
    blockdev --flushbufs "$disk"
    [ "$3" = 1 ] && opts="$opts,ro"
    echo "$2" >$P/election_silent_unfenced
    mark="$(dmesg_mark)"
    mount -t cetrafs -o "$opts" "$disk" "$MNT"
    ct_track mnt "$MNT"
    require_cetrafs_mount "$MNT"
    echo 0 >$P/election_silent_unfenced
    RES="caw=$(dmesg_since "$mark" | grep -c 'atomic CAS unavailable' || true)"
    RES="$RES mode=$(sed -n 's/^file_lock: //p' "$(ct_procdir "$disk")/info" | head -1)"
    ct_umount "$MNT"
    row="$("$NPOKE" "$img" 1)"
    RES="$RES fence_epoch=$(get fence_epoch "$row") departure=$(get departure "$row") fence_reason=$(get fence_reason "$row")"
}

round f 0 0
R="$RES"
log "fixed: $R"
round c 1 0
C="$RES"
log "control (unfenced): $C"
round r 0 1
O="$RES"
log "read-only: $O"
[ "$(get caw "$R")" = 0 ] || { skip "the LIO disk offers no atomic CAW here"; ct_exit; }
[ "$(get fence_epoch "$R")" != "" ] || { fail "setup: the row could not be read back: $R"; ct_exit; }
[ "$(get mode "$R")" = off ] && pass "1: the mount led with lock OFF; the silent row imposed nothing" || fail "1: $R"
[ "$(get fence_epoch "$R")" = 1 ] && [ "$(get departure "$R")" = 2 ] && [ "$(get fence_reason "$R")" = 1 ] &&
    pass "2: the silent row's lease was revoked and it is recorded DEAD ($R)" || fail "2: $R"
[ "$(get fence_epoch "$O")" = 0 ] && [ "$(get departure "$O")" = 0 ] &&
    pass "a read-only mount judged it and wrote nothing to it" || fail "read-only: $O"
[ "$(get fence_epoch "$C")" = 0 ] && [ "$(get departure "$C")" = 0 ] &&
    pass "control: skipped unfenced, the row is left as planted" || fail "control: $C -- something else fenced it"
ct_exit
