#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# applying a peer's pending free lets go of alloc_mutex between chunks, and credits every block
#
# A queued free is one extent, up to a whole Block Group, and the owner
# applied it bit by bit in one hold of the node-wide alloc_mutex: every
# allocating write on that node -- a guest write into a hole -- stalled
# for the whole entry, 100 ms per 1 GiB, back to back through a drain
# (audit 2026-11-14 P1). It now lets go every 4096 blocks, as the direct
# free does (free_extent_lock_chunks.sh), re-checking the group's stamp
# and owner after each relock.
#
# Staged: a range of N blocks leaked (set, unreferenced), and one queued
# free naming it, as a peer deleting a file in our group would queue it.
# The heartbeat drain applies it; a kprobe on cetrafs_sb_alloc_unlock()
# counts the releases. The split credit must add up: the free count
# rises by N, fsck is clean.
#
# DISCRIMINATION: pf_apply_one_hold applies the entry in one hold; the
# releases then fall to a handful.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LEAK="$(ct_helper data_leak_poke)"
PENDPOKE="$(ct_helper pending_poke)"
[ -w /sys/module/cetrafs/parameters/pf_apply_one_hold ] || { skip "pf_apply_one_hold is missing"; ct_exit; }
T=/sys/kernel/tracing
[ -w "$T/tracing_on" ] || { skip "no tracefs: a kprobe would record nothing"; ct_exit; }
TRACING0="$(cat "$T/tracing_on")"
echo 1 >"$T/tracing_on" # a kprobe records nothing with tracing off; restored at exit

N=60000
MNT="$(ct_mnt pfchunk)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hb_drain_off 1
ct_param_set pf_apply_one_hold 0
EV=cetrafs_pfch_$$
kp_off() {
    echo 0 >"$T/events/kprobes/$EV/enable" 2>/dev/null || true
    echo "-:kprobes/$EV" >>"$T/kprobe_events" 2>/dev/null || true
    echo "$TRACING0" >"$T/tracing_on" 2>/dev/null || true
}
echo "p:kprobes/$EV cetrafs:cetrafs_sb_alloc_unlock" >>"$T/kprobe_events" 2>/dev/null ||
    { skip "cannot place a kprobe on cetrafs_sb_alloc_unlock"; ct_exit; }
ct_track cmd kp_off # after the unmounts, at cleanup -- a trap of our own would replace the harness's

# <one_hold 0|1> -> "<releases> <free blocks gained> <fsck: clean|ERR...>"
round() {
    local img dev lba f0 f1 rel out
    img="$(ct_image 560 "pfchunk$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    lba="$("$LEAK" "$dev" 0 100 "$N" | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
    [ -n "$lba" ] || { echo "setup-noleak 0 x"; return; }
    ct_mount "$dev" "$MNT"
    "$PENDPOKE" "$img" add 0 "$lba" "$N" >/dev/null
    f0="$(sed -n 's/^free_data_blocks: //p' "$(ct_procdir "$dev")/info")"
    echo "$1" >/sys/module/cetrafs/parameters/pf_apply_one_hold
    : >"$T/trace"
    echo 1 >"$T/events/kprobes/$EV/enable"
    echo 0 >/sys/module/cetrafs/parameters/hb_drain_off
    local i
    for i in $(seq 60); do
        [ "$("$PENDPOKE" "$img" dump 0 | grep -c .)" -eq 0 ] && break
        sleep 0.5
    done
    sleep 1
    echo 1 >/sys/module/cetrafs/parameters/hb_drain_off
    echo 0 >"$T/events/kprobes/$EV/enable"
    rel="$(grep -c "$EV:" "$T/trace" || true)"
    f1="$(sed -n 's/^free_data_blocks: //p' "$(ct_procdir "$dev")/info")"
    echo 0 >/sys/module/cetrafs/parameters/pf_apply_one_hold
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q '^ERR' <<<"$out" && out=ERR || out=clean
    echo "$rel $((f1 - f0)) $out"
}

read -r REL GAIN FS <<<"$(round 0)"
log "chunked: $REL alloc_mutex release(s), free count +$GAIN, fsck $FS"
[ "$GAIN" = "$N" ] || fail "setup: the drain freed $GAIN blocks, not the $N queued -- the entry was not applied"
[ "$REL" -ge $((N / 4096)) ] && pass "the apply let go of alloc_mutex $REL times across $N blocks" ||
    fail "the apply released alloc_mutex only $REL time(s) for $N blocks -- held across the whole entry"
[ "$GAIN" = "$N" ] && pass "and every block was credited ($GAIN)" || fail "credited $GAIN of $N blocks"
[ "$FS" = clean ] && pass "fsck clean" || fail "fsck reports errors after the chunked apply"
read -r REL1 GAIN1 FS1 <<<"$(round 1)"
log "one hold: $REL1 release(s), free count +$GAIN1"
[ "$GAIN1" = "$N" ] && [ "$REL1" -lt $((N / 4096)) ] &&
    pass "control: in one hold the same apply releases $REL1 time(s) -- the suite discriminates" ||
    fail "control: one hold gave $REL1 releases (+$GAIN1) -- the suite cannot tell"
ct_exit
