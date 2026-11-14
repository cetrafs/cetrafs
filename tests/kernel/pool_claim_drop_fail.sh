#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a pool claim whose bitmap drop fails goes back to the pool
#
# Claiming a FREE Block Group is one CAS, then a drop of this node's
# cached bitmap. When the drop failed the claim returned with the group
# owned on the device -- by nobody's member map, out of every node's
# reach, and not debited from the pool -- until a Zone Group claim or a
# remount (re-audit of the 2026-11-14 fixes). The claim is now undone.
#
# Setup: two Block Groups, one owned, BG 1 in the pool; the owned one
# is filled with BG 1's drop failing.
#   1. BG 1 reads FREE on the device afterwards;
#   2. with the fault gone, the same mount claims it and writes into it;
#   3. fsck is clean.
#
# DISCRIMINATION: pool_claim_undo_off keeps the claim, as before; BG 1
# then reads owned and the same mount cannot write into it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in bg_invalidate_fail_bg pool_claim_undo_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
MNT="$(ct_mnt pcdf)"
ct_track mnt "$MNT"
ct_param_set bg_invalidate_fail_bg 0
ct_param_set pool_claim_undo_off 0
P=/sys/module/cetrafs/parameters

fill() { # <prefix> -> MiB written
    local i=0
    while dd if=/dev/zero of="$MNT/$1$i" bs=1M count=16 status=none 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 100 ] && break
    done
    echo $((i * 16))
}

# <undo_off> -> "<owner-after-fault> <MiB-with-fault> <MiB-after> <fsck ok|bad>"
probe() {
    local img dev owner a b ok
    img="$(ct_image 1200 "pcdf$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    "$POKE" "$dev" 1 --owner 65535 >/dev/null
    echo "$1" >$P/pool_claim_undo_off
    ct_mount "$dev" "$MNT"
    echo 2 >$P/bg_invalidate_fail_bg
    a="$(fill a)"
    sync
    echo 0 >$P/bg_invalidate_fail_bg
    owner="$("$MAP" "$img" | awk '/^bg 1 /{split($3,o,"="); print o[2]}')"
    b="$(fill b)"
    ct_umount "$MNT"
    echo 0 >$P/pool_claim_undo_off
    ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
    echo "$owner $a $b $ok"
}

R="$(probe 0)"
log "fixed: $R"
set -- $R
[ "$2" -gt 0 ] && [ "$2" -lt 520 ] || { fail "setup: the faulted fill wrote $2 MiB, expected to stop inside the owned group"; ct_exit; }
[ "$1" = 65535 ] && pass "1: the claim whose drop failed was given back (BG 1 owner=$1)" ||
    fail "1: BG 1 reads owner=$1 after the failed drop"
[ "$3" -gt 0 ] && pass "2: with the fault gone the same mount claimed it and wrote $3 MiB" ||
    fail "2: nothing more could be written once the fault was gone"
[ "$4" = ok ] && pass "3: fsck is clean" || fail "3: fsck reports damage"

C="$(probe 1)"
log "control: $C"
set -- $C
[ "$1" != 65535 ] && [ "$3" -eq 0 ] &&
    pass "control: the kept claim is owned (owner=$1) and out of reach -- the suite discriminates" ||
    fail "control: kept claim reads owner=$1, $3 MiB written after -- the suite does not discriminate"
ct_exit
