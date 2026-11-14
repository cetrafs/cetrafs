#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# applying a peer's pending free reads each bitmap block once, not twice per bit
#
# The owner applies a free a peer queued for its group bit by bit, and
# each bit was a bitmap-block lookup to test it and another to clear it
# -- 52 M lookups for a 100 GiB image deleted by the node that did not
# own its groups (audit 2026-11-14 P2; the direct free was fixed in
# free_bmap_lookups.sh). The apply now holds one bitmap block per run of
# bits, as the direct free does.
#
# Staged as pf_apply_lock_chunks.sh stages it: N blocks leaked (set,
# unreferenced), one queued free naming them, the heartbeat drain
# applies it.
#   1. the free count rises by N and fsck is clean;
#   2. the apply looked up at most a few bitmap blocks per 32768 bits.
#
# DISCRIMINATION: pf_apply_per_bit, the old loop: 2N lookups.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LEAK="$(ct_helper data_leak_poke)"
PENDPOKE="$(ct_helper pending_poke)"
[ -w /sys/module/cetrafs/parameters/pf_apply_per_bit ] || { skip "pf_apply_per_bit is missing"; ct_exit; }
N=60000
MNT="$(ct_mnt pfbml)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hb_drain_off 1
ct_param_set pf_apply_per_bit 0
P=/sys/module/cetrafs/parameters

# <per_bit 0|1> -> "<lookups> <free blocks gained> <fsck clean|ERR>"
round() {
    local img dev lba info f0 f1 l0 l1 out i
    img="$(ct_image 560 "pfbml$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    lba="$("$LEAK" "$dev" 0 100 "$N" | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
    [ -n "$lba" ] || { echo "0 0 setup-noleak"; return; }
    ct_mount "$dev" "$MNT"
    info="$(ct_procdir "$dev")/info"
    "$PENDPOKE" "$img" add 0 "$lba" "$N" >/dev/null
    f0="$(sed -n 's/^free_data_blocks: //p' "$info")"
    l0="$(sed -n 's/^pf_apply_bmap_lookups: //p' "$info")"
    echo "$1" >$P/pf_apply_per_bit
    echo 0 >$P/hb_drain_off
    for i in $(seq 60); do
        [ "$("$PENDPOKE" "$img" dump 0 | grep -c .)" -eq 0 ] && break
        sleep 0.5
    done
    sleep 1
    echo 1 >$P/hb_drain_off
    echo 0 >$P/pf_apply_per_bit
    f1="$(sed -n 's/^free_data_blocks: //p' "$info")"
    l1="$(sed -n 's/^pf_apply_bmap_lookups: //p' "$info")"
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q '^ERR' <<<"$out" && out=ERR || out=clean
    echo "$((l1 - l0)) $((f1 - f0)) $out"
}

read -r L G F <<<"$(round 0)"
log "fixed: $L lookups, $G blocks credited, fsck $F"
[ "$G" = "$N" ] && [ "$F" = clean ] && pass "1: the apply credited all $N blocks and fsck is clean" ||
    { fail "1: credited $G of $N, fsck $F"; ct_exit; }
[ "$L" -gt 0 ] && [ "$L" -le 16 ] && pass "2: $L bitmap-block lookups for $N bits" ||
    fail "2: $L bitmap-block lookups for $N bits"
read -r L0 G0 F0 <<<"$(round 1)"
[ "$L0" -ge $((2 * N)) ] && [ "$G0" = "$N" ] &&
    pass "control: the per-bit loop made $L0 lookups for the same apply -- the suite discriminates" ||
    fail "control: per-bit made $L0 lookups, credited $G0 -- the suite cannot tell"
ct_exit
