#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a claim naming a node outside the registry is reclaimable, not permanent
#
# Registration never hands out a row past node_table_count, so a claim
# naming one -- a lock owner, a presence bit -- belongs to nobody, and
# cetrafs_node_is_stale() says so. But the fence that every reclaim
# takes first refused such an id (-EINVAL), its callers read that as
# "not revoked", and the claim stayed for good: the file could never
# again be opened for write anywhere. The journal replay refused the id
# the same way.
#
# Staged on a 4-row registry: one file locked by node 200, one carrying
# a presence bit for row 40. Both must open for write.
#
# DISCRIMINATION: with the fence refusing an out-of-range id again, both
# opens fail with ETXTBSY.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 unknode)"
MNT="$(ct_mnt unknode)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo l >"$MNT/locked"; echo r >"$MNT/read"
LI="$(stat -c %i "$MNT/locked")"; RI="$(stat -c %i "$MNT/read")"
ct_umount "$MNT"

"$LOCK_POKE" "$DEV" "$LI" 200 1 >/dev/null
"$LOCK_POKE" "$DEV" "$RI" --reader 40 >/dev/null
grep -q 'owner=200 mode=1' <<<"$("$LOCK_POKE" "$DEV" "$LI")" &&
    grep -q 'readers=0x10000000000$' <<<"$("$LOCK_POKE" "$DEV" "$RI")" ||
    { fail "setup: the claims were not planted ($("$LOCK_POKE" "$DEV" "$LI"); $("$LOCK_POKE" "$DEV" "$RI"))"; ct_exit; }
pass "setup: a lock by node 200 and a presence bit for row 40, on a 4-row registry"

ct_mount "$DEV" "$MNT"
for f in locked read; do
    if ERR="$( { echo more >>"$MNT/$f"; } 2>&1)"; then
        pass "$f: opens for write past a claim of a node that cannot exist"
    else
        fail "$f: the write-open failed ($ERR) -- the claim of a node outside the registry is permanent"
    fi
done

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
