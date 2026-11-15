#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node that wakes past its lease is fenced before it writes, whatever jiffies say
#
# The lease -- how long this node may write after its last renewal --
# was judged by jiffies. jiffies stop across a suspend and a stunned
# guest's catch up only as ticks replay, while a peer's watch runs on a
# clock that did not stop: a node waking from a suspend past its lease
# read its lease as still running and wrote over what a peer had
# reclaimed (audit 2026-11-15 A-15). The lease is now judged by
# boottime, which counts the time asleep.
#
# A box cannot be suspended under a suite, so the sleep is modelled:
# lease_clock_skew_secs adds seconds to boottime only, as a suspend does.
# With a file being written, 600 s of "sleep":
#   the next write fails (EIO), the mount reports its lease expired, and
#   the row's heartbeat does not advance afterwards -- the tick found the
#   lapse before renewing.
#
# What this cannot show: a real suspend or VM stun. The model is the
# clock difference that makes one dangerous, nothing else.
#
# DISCRIMINATION: lease_clock_jiffies=1 (the old clock, blind to the
# sleep, as to a suspend): the write succeeds and the node renews.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in lease_clock_skew_secs lease_clock_jiffies; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
NPOKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt lcb)"
ct_track mnt "$MNT"
ct_param_set lease_clock_skew_secs 0
ct_param_set lease_clock_jiffies 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set hb_interval_secs 2

seq_of() { "$NPOKE" "$1" 0 2>/dev/null | sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p'; }
# <tag> <jiffies 0|1> -> RES
round() {
    local img dev mark rc=0 s0 s1
    img="$(ct_image 560 "lcb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    echo "$2" >$P/lease_clock_jiffies
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/a" bs=4096 count=4 conv=fsync status=none
    sleep 3 # a renewal or two: the lease is armed and running
    mark="$(dmesg_mark)"
    echo 600 >$P/lease_clock_skew_secs
    dd if=/dev/urandom of="$MNT/b" bs=4096 count=4 conv=fsync status=none 2>/dev/null || rc=1
    blockdev --flushbufs "$dev" 2>/dev/null || true
    s0="$(seq_of "$img")"
    sleep 5 # two more ticks
    blockdev --flushbufs "$dev" 2>/dev/null || true
    s1="$(seq_of "$img")"
    RES="write_rc=$rc expired=$(dmesg_since "$mark" | grep -c 'lease expired' || true) seq0=$s0 seq1=$s1"
    echo 0 >$P/lease_clock_skew_secs
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/lease_clock_jiffies
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round c 1
C="$RES"
log "control (jiffies): $C"
round f 0
R="$RES"
log "boottime: $R"
[ -n "$(get seq0 "$R")" ] && [ -n "$(get seq0 "$C")" ] || { fail "setup: could not read the row's hb_seq ($R | $C)"; ct_exit; }
[ "$(get write_rc "$R")" = 1 ] && [ "$(get expired "$R")" -ge 1 ] && [ "$(get seq1 "$R")" = "$(get seq0 "$R")" ] &&
    pass "after 600 s of sleep the write failed, the lease read expired, and no renewal landed" || fail "$R"
[ "$(get write_rc "$C")" = 0 ] && [ "$(get seq1 "$C")" -gt "$(get seq0 "$C")" ] &&
    pass "control: judged by jiffies, the sleep went unseen -- the write landed and the node renewed" ||
    fail "control: ($C) -- the suite cannot see the clock"
ct_exit
