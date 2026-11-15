#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# f_bavail is what THIS node can allocate, not the volume's free space
#
# A node allocates only from Zone Groups it owns and from groups nobody
# owns; a live peer's free space is never taken back. statfs reported
# the whole volume's free space as f_bavail, so Proxmox placement and
# every "storage full" alert saw room this node answers ENOSPC to (audit
# 2026-11-14 A-13). f_bavail now leaves out Zone Groups a peer owns;
# f_bfree stays the volume's figure.
#
# Three Zone Groups; a registered peer row (seen just now, so not yet
# reclaimable) is made the owner of one this node does not own, before
# the mount.
#   setup: the peer's Zone Group has free space, and this node does not own it;
#   1. f_bfree - f_bavail is that Zone Group's free count;
#   2. f_bavail is not more than f_bfree, and not zero.
#
# DISCRIMINATION: the old statfs reports f_bavail == f_bfree: 1 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
DEV="$(ct_dev 2400 sbp)"
MNT="$(ct_mnt sbp)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 3 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set scrub 0
poke_dead_peer "$DEV" 5 ab
"$ZG_POKE" "$DEV" 2 5 >/dev/null
ct_mount "$DEV" "$MNT"
PROC="$(ct_procdir "$DEV")"
grep -P '^\s+zg [0-9]+:' "$PROC/info" | sed 's/^/  /' >&2
PF="$(grep -P '^\s+zg 2: ' "$PROC/info" | grep -oP 'free_data_blocks=\K[0-9]+' || echo 0)"
if ! grep -qP '^\s+zg 2: owner=5 ' "$PROC/info" || [ "$PF" -eq 0 ]; then
    fail "setup: Zone Group 2 is not the peer's, or has no free space (free=$PF)"
    ct_exit
fi
pass "setup: Zone Group 2 belongs to peer row 5, with $PF free blocks"
read -r AV FR <<<"$(stat -f -c '%a %f' "$MNT")"
log "f_bavail=$AV f_bfree=$FR peer_free=$PF"
[ "$((FR - AV))" -eq "$PF" ] && pass "1: f_bavail leaves out the peer's $PF free blocks" ||
    fail "1: f_bfree - f_bavail = $((FR - AV)), the peer's Zone Group has $PF free"
[ "$AV" -le "$FR" ] && [ "$AV" -gt 0 ] && pass "2: 0 < f_bavail <= f_bfree" || fail "2: f_bavail=$AV f_bfree=$FR"
ct_umount "$MNT"
ct_exit
