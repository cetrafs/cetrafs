#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live grow whose claim is lost before its publish publishes nothing
#
# The ioctl checks the caller's growfs claim at its entry; the pool
# credits, the table writes and the link run after that, and only then
# the superblock publish. A claim lost in between -- reaped, retaken by
# another grower -- still published (audit 2026-11-14 L8, rule 15). The
# claim is now judged again just before the publish.
#
# A grow is held just before its publish (grow_publish_stall_ms) and its
# claim row is given another nonce, as a second grower retaking it would:
#   1. growfs fails, and layout_gen has not moved;
#   2. after a remount the volume is its old size and fsck is clean.
#
# DISCRIMINATION: grow_publish_recheck_off publishes without the second
# look; the same grow then lands.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in grow_publish_stall_ms grow_publish_recheck_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt gcl)"
ct_track mnt "$MNT"
ct_param_set grow_publish_stall_ms 0
ct_param_set grow_publish_recheck_off 0
P=/sys/module/cetrafs/parameters
FSCK0="$(ct_tmp gcl0)"
FSCK1="$(ct_tmp gcl1)"

# <recheck_off 0|1> -> "<growfs rc> <layout_gen before> <after> <fsck ok|bad>"
probe() {
    local img dev pd g0 g1 rc=0 r row="" st ok f
    img="$(ct_image 1600 "gcl$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    pd="$(ct_procdir "$dev")"
    g0="$(sed -n 's/^layout_gen: //p' "$pd/info")"
    echo "$1" >$P/grow_publish_recheck_off
    echo 5000 >$P/grow_publish_stall_ms
    ct_growfs "$dev" -s 1400M >/dev/null 2>&1 &
    local gpid=$!
    # Find the claim while the grow is held, and retake it.
    for _ in $(seq 1 30); do
        sleep 0.2
        for r in $(seq 0 63); do
            st="$("$NPOKE" "$img" "$r" 2>&1 || true)"
            case "$st" in *state=2*) row="$r"; break ;; esac
        done
        [ -n "$row" ] && dmesg | tail -5 | grep -q "pausing .* before the publish" && break
    done
    [ -n "$row" ] && "$NPOKE" "$img" "$row" --uuid "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" >/dev/null
    blockdev --flushbufs "$dev"
    wait "$gpid" || rc=$?
    echo 0 >$P/grow_publish_stall_ms
    echo 0 >$P/grow_publish_recheck_off
    g1="$(sed -n 's/^layout_gen: //p' "$pd/info")"
    ct_umount "$MNT" >/dev/null
    # The retaken row is a stranger's claim now: its holder would release
    # it; free it, as it would, before the remount heals the dead grow's
    # credit (cetrafs_grow_heal_pool()).
    [ -n "$row" ] && "$NPOKE" "$img" "$row" 0 00 0 >/dev/null 2>&1 || true
    ct_mount "$dev" "$MNT"
    ct_umount "$MNT" >/dev/null
    if [ "$1" = 0 ]; then f="$FSCK0"; else f="$FSCK1"; fi
    ct_fsck "$dev" >"$f" 2>&1 && ok=ok || ok=bad
    echo "$rc $g0 $g1 $ok ${row:-none}"
}
read -r RC G0 G1 OK ROW <<<"$(probe 0)"
read -r RC0 H0 H1 OK0 ROW0 <<<"$(probe 1)"
log "claim retaken before the publish: growfs rc $RC, layout_gen $G0 -> $G1, fsck $OK (row $ROW)"
log "control (no re-check): growfs rc $RC0, layout_gen $H0 -> $H1, fsck $OK0 (row $ROW0)"
[ "$ROW" != none ] && [ "$ROW0" != none ] || fail "setup: the grow's claim row was never found"
[ "$RC" != 0 ] && [ "$G1" = "$G0" ] && pass "1: the grow failed and published nothing (layout_gen $G0)" ||
    fail "1: a grow whose claim was retaken published (rc $RC, layout_gen $G0 -> $G1)"
[ "$OK" = ok ] && pass "2: after a remount fsck is clean" ||
    fail "2: fsck is not clean after the refused grow: $(grep -m3 '^ERR' "$FSCK0" | tr '\n' ' ')"
[ "$H1" != "$H0" ] && pass "control: without the re-check the same grow published -- the suite discriminates" ||
    fail "control: the grow did not publish even without the re-check -- the suite cannot tell"
ct_exit
