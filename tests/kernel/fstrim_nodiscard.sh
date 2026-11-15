#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fstrim honours a mount's discard switch: nodiscard means no UNMAP, the weekly timer's included
#
# FITRIM ignored the discard switch, on the reasoning that the operator
# asked. The operator usually did not: a distribution's fstrim.timer runs
# `fstrim -a` weekly on every node, so the arrays `nodiscard` was set for
# -- slow UNMAP -- got long UNMAPs in flight from every node at once
# (audit 2026-11-15 B-37). FITRIM now answers "not supported" while the
# switch is off; `discard=on` in controls turns it back on.
#
# Half of 40 files deleted inside Block Groups still in use, on a
# nodiscard mount:
#   1. fstrim is refused and issues no discard;
#   2. after `discard=on` in controls, fstrim trims.
#
# DISCRIMINATION: fitrim_ignores_nodiscard=1 (as before): 1 trims.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/fitrim_ignores_nodiscard ] || { skip "fitrim_ignores_nodiscard is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
IMG="$(ct_big_image 1200 fsnd)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsnd)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set scrub 0
ct_param_set fitrim_ignores_nodiscard 0
mount -t cetrafs -o nodiscard "$DEV" "$MNT"
ct_track mnt "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
# punch <from> <to>: write files f<from>..f<to>, then delete every other one
punch() {
    local i
    for i in $(seq "$1" "$2"); do dd if=/dev/urandom of="$MNT/f$i" bs=1M count=4 conv=fsync status=none; done
    sync
    for i in $(seq "$1" 2 "$2"); do rm -f "$MNT/f$i"; done
    sync
    sleep 3
}
# trim -> "rc=<n> cmds=<discards issued>"
trim() {
    local c0 rc=0
    c0="$(info discard_cmds)"
    fstrim "$MNT" >/dev/null 2>&1 || rc=$?
    echo "rc=$rc cmds=$(($(info discard_cmds) - c0))"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

grep -q '^discard: off$' "$PROC/controls" ||
    { fail "setup: the nodiscard mount does not read discard off ($(grep discard "$PROC/controls"))"; ct_exit; }
punch 1 40
R1="$(trim)"
echo 1 >$P/fitrim_ignores_nodiscard
C="$(trim)"
echo 0 >$P/fitrim_ignores_nodiscard
log "1: $R1  control: $C"
[ "$(get rc "$R1")" != 0 ] && [ "$(get cmds "$R1")" = 0 ] &&
    pass "1: fstrim on a nodiscard mount: refused, no discard issued" || fail "1: $R1"
[ "$(get rc "$C")" = 0 ] && [ "$(get cmds "$C")" -gt 0 ] &&
    pass "control: ignoring the switch, the same fstrim issued $(get cmds "$C") discard(s)" ||
    fail "control: $C -- there was nothing to trim, the suite does not reach the check"
punch 41 80
echo discard=on >"$PROC/controls"
R2="$(trim)"
log "2: $R2"
[ "$(get rc "$R2")" = 0 ] && [ "$(get cmds "$R2")" -gt 0 ] &&
    pass "2: with discard=on in controls, fstrim trimmed ($(get cmds "$R2") discard(s))" || fail "2: $R2"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 -E '^ERR' <<<"$out")"
ct_exit
