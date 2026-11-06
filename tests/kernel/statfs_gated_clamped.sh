#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# statfs answers within the volume's capacity, and not at all on a stopped mount
#
# statfs sums cached counts: the Zone Group aggregates, the pool, a
# node-local free-inode count. A cache can be wrong -- an aggregate a
# crashed owner left high -- and df then reported more free space than
# the volume has. And it had no read gate, so a stopped mount went on
# answering df from a frozen view (audit 2026-11-06 L17).
#
#  (1) Zone Group B (not this node's, so no mount reconciles it) carries
#      an aggregate far past the volume's size: free must not exceed
#      total.
#  (2) The mount is stopped (shutdown=now): statfs must fail.
# NOT COVERED: the free-inode count driven negative -- nothing here can
# stage it; the clamp is the same shape as (1)'s.
#
# DISCRIMINATION: unclamped, (1) reports free > total; ungated, (2)
# succeeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"

DEV="$(ct_dev 1200 statfsclamp)"
MNT="$(ct_mnt statfsclamp)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
info() { cat "$(ct_procdir "$DEV")/info"; }
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
OWNED="$(info | sed -n 's/.*zg \([0-9]*\): owner=[0-9]* (this node).*/\1/p')"
[ "$(wc -w <<<"$OWNED")" = 1 ] || { fail "setup: this node owns Zone Groups '$OWNED', want one"; ct_umount "$MNT"; ct_exit; }
OTHER=$((1 - OWNED))
ct_umount "$MNT"
"$ZG_POKE" "$DEV" "$OTHER" free 1000000000000 >/dev/null
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
read -r TOT FREE <<<"$(stat -f -c '%b %f' "$MNT")"
info | grep -qE "zg $OTHER: .*free_data_blocks=1000000000000" ||
    log "note: zone group $OTHER's aggregate as this node sees it: $(info | grep "zg $OTHER:")"
[ "$FREE" -le "$TOT" ] && pass "1: df's free ($FREE) does not exceed the volume ($TOT) whatever an aggregate says" ||
    fail "1: df reports $FREE free blocks on a volume of $TOT"

echo shutdown=now >"$(ct_procdir "$DEV")/controls"
if stat -f "$MNT" >/dev/null 2>&1; then
    fail "2: a stopped mount still answered statfs"
else
    pass "2: a stopped mount refuses statfs"
fi
umount "$MNT" 2>/dev/null || umount -l "$MNT"
ct_exit
