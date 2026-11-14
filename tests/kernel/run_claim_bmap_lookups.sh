#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a speculative run claim reads each bitmap block once, not once per block claimed
#
# A sequential writer takes its blocks in runs: after one block is
# allocated, the next ones are claimed by test-and-set from there
# (cetrafs_alloc_run_after()), up to 4096 under alloc_mutex. Each claim
# was its own bitmap-block lookup (audit 2026-11-14 P2); the claim now
# holds one bitmap block per run of bits.
#
# A 64 MiB file written sequentially (16384 blocks):
#   1. it reads back and fsck is clean;
#   2. the run claims made far fewer bitmap lookups than blocks.
#
# DISCRIMINATION: run_claim_per_bit, the old loop: about one lookup per
# block claimed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/run_claim_per_bit ] || { skip "run_claim_per_bit is missing"; ct_exit; }
MNT="$(ct_mnt rcbml)"
ct_track mnt "$MNT"
ct_param_set run_claim_per_bit 0
P=/sys/module/cetrafs/parameters

# <per_bit 0|1> -> "<lookups> <data ok|bad> <fsck clean|ERR>"
round() {
    local dev info l0 l1 sum ok out
    dev="$(ct_dev 560 "rcbml$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    info="$(ct_procdir "$dev")/info"
    echo "$1" >$P/run_claim_per_bit
    l0="$(sed -n 's/^run_claim_bmap_lookups: //p' "$info")"
    head -c $((64 << 20)) /dev/urandom >"$MNT/f"
    sync
    l1="$(sed -n 's/^run_claim_bmap_lookups: //p' "$info")"
    echo 0 >$P/run_claim_per_bit
    sum="$(md5sum <"$MNT/f")"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    [ "$(md5sum <"$MNT/f")" = "$sum" ] && ok=ok || ok=bad
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q '^ERR' <<<"$out" && out=ERR || out=clean
    echo "$((l1 - l0)) $ok $out"
}

read -r L D F <<<"$(round 0)"
log "fixed: $L lookups for 16384 blocks, data $D, fsck $F"
[ "$D" = ok ] && [ "$F" = clean ] && pass "1: the file reads back after a remount and fsck is clean" ||
    fail "1: data $D, fsck $F"
read -r L0 D0 F0 <<<"$(round 1)"
log "per bit: $L0 lookups, data $D0, fsck $F0"
[ "$L0" -ge 8000 ] || { fail "setup: the per-bit claims made $L0 lookups -- the writer did not take runs"; ct_exit; }
[ "$L" -gt 0 ] && [ $((L * 20)) -le "$L0" ] && pass "2: $L bitmap lookups against $L0 per bit" ||
    fail "2: $L bitmap lookups against $L0 per bit"
ct_exit
