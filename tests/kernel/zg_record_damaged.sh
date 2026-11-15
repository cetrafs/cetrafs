#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# one damaged Zone Group record makes that group unclaimable, not the volume unmountable
#
# A Zone Group record that failed its checksum on every read failed the
# mount's claim sweep -- every mount, read-only ones included -- every
# heartbeat tick of a node that owned no group, and statfs, and under
# corruption=stop it stopped the node: one damaged sector of a group
# nobody needed took the whole volume down (audit 2026-11-15 B-14). A
# record of a group this node does not own is now left out of every
# claim and release, reported once, and counted in `info`.
#
# Four Zone Groups; group 3's cold half damaged before the mount; the
# mount asks for corruption=stop:
#   1. the mount succeeds; df answers; a file is written and read back;
#   2. the damage is reported once across several heartbeat ticks, and
#      counted (zg_unreadable: 1); the mount is not stopped.
#
# DISCRIMINATION: zg_unreadable_fatal=1 (as before): the mount fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/zg_unreadable_fatal ] || { skip "zg_unreadable_fatal is missing"; ct_exit; }
POKE="$(ct_helper csum_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt zgrd)"
ct_track mnt "$MNT"
ct_param_set zg_unreadable_fatal 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <fatal 0|1> -> RES
round() {
    local img dev proc rc=0 mark ok=0 rep
    img="$(ct_image 3200 "zgrd$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 4 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    "$POKE" "$img" zg-cold 3 >/dev/null
    blockdev --flushbufs "$dev"
    echo "$2" >$P/zg_unreadable_fatal
    mark="$(dmesg_mark)"
    mount -t cetrafs -o corruption=stop "$dev" "$MNT" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ]; then
        echo 0 >$P/zg_unreadable_fatal
        RES="mount_rc=$rc"
        return
    fi
    proc="$(ct_procdir "$dev")"
    df "$MNT" >/dev/null && dd if=/dev/urandom of="$MNT/f" bs=1M count=1 conv=fsync status=none &&
        cmp -s <(dd if="$MNT/f" bs=1M status=none) "$MNT/f" && ok=1
    sleep 4 # several heartbeat ticks
    rep="$(dmesg_since "$mark" | grep -c 'ZG 3: its record failed its checksum' || true)"
    RES="mount_rc=0 io=$ok reported=$rep unreadable=$(sed -n 's/^zg_unreadable: //p' "$proc/info")"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    echo 0 >$P/zg_unreadable_fatal
    ct_umount "$MNT"
}

round c 1
C="$RES"
log "control (fatal, as before): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get mount_rc "$R")" = 0 ] && [ "$(get io "$R")" = 1 ] &&
    pass "1: mounted (corruption=stop) over a damaged group record; df, write and read all work" || fail "1: $R"
[ "$(get reported "$R")" = 1 ] && [ "$(get unreadable "$R")" = 1 ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "2: reported once across ticks, counted, and the mount ran on" || fail "2: $R"
[ "$(get mount_rc "$C")" != 0 ] && pass "control: with the old handling the mount failed ($C)" ||
    fail "control: $C -- the poke did not damage a record the mount reads"
ct_exit
