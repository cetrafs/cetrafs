#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a no-CAW row claim is read back after a settle; a claim another machine overwrote refuses the mount
#
# On a volume without atomic CAW, two machines claiming the same FREE
# registry row at once both read it free; the second write takes it.
# The post-registration check excludes our own UUID, so the first mounter
# ran it before the overwrite landed and both mounts went ahead (audit
# 2026-11-22 N-36). A claim's read-to-write span is now bounded, and the
# claimer waits twice the bound and reads its row again.
#
# On a loop device (no CAW), each on a fresh volume:
#   1. a plain mount claims row 0 and comes up;
#   2. the racer's late write played (nocaw_settle_steal: right after the
#      claim, row 0 rewritten as another machine's): the mount is
#      refused, saying another node claimed the row;
#   3. a claim slower than the bound (cas_nocaw_stall_ms): given back, the
#      mount refused; row 0 is FREE again and the next mount comes up.
#
# DISCRIMINATION: nocaw_settle_off=1 (as before): the overwritten claim
# is trusted and the mount comes up on a row that is not its own.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in nocaw_settle_off nocaw_settle_steal cas_nocaw_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
NPOKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt ncs)"
ct_track mnt "$MNT"
ct_param_set nocaw_settle_off 0
ct_param_set nocaw_settle_steal 0
ct_param_set cas_nocaw_stall_ms 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# try <tag> <off> <steal> <stall_ms> -> RES "rc= stole= slow= state= uuid= rc2="
try() {
    local img dev mark rc=0 row
    img="$(ct_image 560 "ncs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    echo "$2" >$P/nocaw_settle_off
    echo "$3" >$P/nocaw_settle_steal
    echo "$4" >$P/cas_nocaw_stall_ms
    mark="$(dmesg_mark)"
    mount -t cetrafs "$dev" "$MNT" 2>/dev/null || rc=$?
    echo 0 >$P/nocaw_settle_off
    echo 0 >$P/nocaw_settle_steal
    echo 0 >$P/cas_nocaw_stall_ms
    [ "$rc" = 0 ] && ct_track mnt "$MNT" && umount "$MNT"
    RES="rc=$rc stole=$(dmesg_since "$mark" | grep -c 'another node claimed row 0 at the same instant' || true)"
    RES="$RES slow=$(dmesg_since "$mark" | grep -c 'claiming row 0 took' || true)"
    row="$("$NPOKE" "$img" 0)"
    RES="$RES state=$(get state "$row")"
    if [ "$4" != 0 ]; then
        rc=0
        mount -t cetrafs "$dev" "$MNT" 2>/dev/null || rc=$?
        [ "$rc" = 0 ] && ct_track mnt "$MNT" && umount "$MNT"
        RES="$RES rc2=$rc"
    fi
}

try p 0 0 0
A="$RES"
log "plain: $A"
try s 0 1 0
S="$RES"
log "overwritten: $S"
try c 1 1 0
C="$RES"
log "control (no settle): $C"
try b 0 0 400
B="$RES"
log "slow claim: $B"
[ "$(get rc "$A")" = 0 ] && pass "1: a plain mount claims its row and comes up" || fail "1: $A"
[ "$(get rc "$S")" != 0 ] && [ "$(get stole "$S")" = 1 ] &&
    pass "2: the claim another machine overwrote was found, and the mount refused" || fail "2: $S"
[ "$(get rc "$B")" != 0 ] && [ "$(get slow "$B")" = 1 ] && [ "$(get state "$B")" = 0 ] && [ "$(get rc2 "$B")" = 0 ] &&
    pass "3: a claim slower than the bound was given back; the next mount came up" || fail "3: $B"
[ "$(get rc "$C")" = 0 ] && [ "$(get stole "$C")" = 0 ] &&
    pass "control: without the settle the overwritten claim was trusted and the mount came up ($C)" ||
    fail "control: $C -- the overwrite does not reach the claim"
ct_exit
