#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group record naming another group is damage, not a mount failure
#
# A Zone Group slot holding a record with a valid checksum and another
# group's zg_id -- a misdirected write, a sector copied over its
# neighbour -- made the reader return -EINVAL. No sweep skips that, so
# the mount's claim scan failed on it, and so did every later claim scan
# and statfs: one wrong sector of a group nobody used took the volume
# down (N-17). It is now damage like a record that never verifies: the
# group is left out, reported once, and counted.
#
# Four Zone Groups; group 2's record copied whole over slot 3 before the
# mount; the mount asks for corruption=stop:
#   1. the mount succeeds; df answers; a file is written and read back;
#   2. the slot is reported once, as naming another group, across
#      several heartbeat ticks, and counted (zg_unreadable: 1); the mount
#      is not stopped.
#
# DISCRIMINATION: zg_unreadable_fatal=1 makes every damaged ZG record
# fail its reader: the mount must fail, which proves the copy reaches a
# record the mount reads. Reverting the fix fails check 1 (mount -EINVAL).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_unreadable_fatal ] || { skip "zg_unreadable_fatal is missing"; ct_exit; }
SBP="$(ct_helper sb_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt zgmd)"
ct_track mnt "$MNT"
ct_param_set zg_unreadable_fatal 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <fatal 0|1> -> RES
round() {
    local img dev proc rc=0 mark ok=0 rep zgt
    img="$(ct_image 3200 "zgmd$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 4 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    zgt="$("$SBP" "$img" | sed -n 's/^zg_table_start=\([0-9]*\)$/\1/p')"
    [ -n "$zgt" ] || { RES="setup=no_zg_table_start"; return; }
    cmp -s <(dd if="$img" bs=4096 skip=$((zgt + 2)) count=1 status=none) \
        <(dd if="$img" bs=4096 skip=$((zgt + 3)) count=1 status=none) && { RES="setup=slots_equal"; return; }
    dd if="$img" of="$img" bs=4096 skip=$((zgt + 2)) seek=$((zgt + 3)) count=1 conv=notrunc status=none
    blockdev --flushbufs "$dev"
    echo "$2" >$P/zg_unreadable_fatal
    mark="$(dmesg_mark)"
    mount -t cetrafs -o corruption=stop "$dev" "$MNT" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ]; then
        echo 0 >$P/zg_unreadable_fatal
        RES="setup=ok mount_rc=$rc"
        return
    fi
    proc="$(ct_procdir "$dev")"
    df "$MNT" >/dev/null && dd if=/dev/urandom of="$MNT/f" bs=1M count=1 conv=fsync status=none &&
        cmp -s <(dd if="$MNT/f" bs=1M status=none) "$MNT/f" && ok=1
    sleep 4 # several heartbeat ticks
    rep="$(dmesg_since "$mark" | grep -c 'ZG 3: its record names another Zone Group' || true)"
    RES="setup=ok mount_rc=0 io=$ok reported=$rep unreadable=$(sed -n 's/^zg_unreadable: //p' "$proc/info")"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    echo 0 >$P/zg_unreadable_fatal
    ct_umount "$MNT"
}

round c 1
C="$RES"
log "control (fatal): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get setup "$R")" = ok ] || fail "setup: $R -- slot 3 was not made a copy of slot 2"
[ "$(get mount_rc "$R")" = 0 ] && [ "$(get io "$R")" = 1 ] &&
    pass "1: mounted (corruption=stop) over a misdirected group record; df, write and read all work" || fail "1: $R"
[ "$(get reported "$R")" = 1 ] && [ "$(get unreadable "$R")" = 1 ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "2: reported once across ticks as naming another group, counted, and the mount ran on" || fail "2: $R"
[ "$(get setup "$C")" = ok ] && [ "$(get mount_rc "$C")" != 0 ] &&
    pass "control: with the record's reader made fatal the mount failed ($C)" ||
    fail "control: $C -- the copy did not land on a record the mount reads"
ct_exit
