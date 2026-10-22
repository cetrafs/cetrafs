#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free-count delta is never applied to a Zone Group a peer has taken
#
# The release path flushes before giving a ZG back, so a delta cannot
# outlive ownership that way. It can outlive ownership the OTHER way: a
# node declared stale has its ZG stolen, and knows nothing about it --
# its own ownership bit is still set locally, so a cached check sees
# "mine" and applies the delta. The new owner has by then reconciled
# that aggregate from the bitmaps, which already include these frees,
# so the delta double counts the lot.
#
# The check therefore lives inside the compare-and-swap, against the
# IMAGE, where the answer cannot go stale between deciding and writing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 zgsteal)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt zgsteal)"
ZG_POKE="$(ct_helper zg_poke)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"

pending() { grep -oP '^zg_pending_deltas: \K[0-9]+' "$PROC/info"; }

dd if=/dev/zero of="$MNT/f" bs=4096 count=64 conv=fsync status=none
sync
[ "$(pending)" = "0" ] && pass "no deltas outstanding to begin with" || fail "$(pending) pending at the start"

# Accrue a delta without flushing: fallocate takes no namespace lock and
# the file never closes, so neither durability boundary fires.
exec 9<>"$MNT/f"
fallocate -p -o 0 -l $((64 * 4096)) "$MNT/f"
[ "$(pending)" -ge 1 ] && pass "the punch leaves a delta pending" ||
    fail "nothing pending after the punch -- the rest of this suite would prove nothing"

# Simulate the steal: a peer that found this node stale takes ZG0. This
# node still believes it owns it; only the on-disk record disagrees.
BEFORE="$("$ZG_POKE" "$DEV" 0 2>&1 | grep -oP 'free_data_blocks=\K[0-9]+')"
"$ZG_POKE" "$DEV" 0 7 >/dev/null
AGG_AFTER_POKE="$("$ZG_POKE" "$DEV" 0 2>&1 | grep -oP 'free_data_blocks=\K[0-9]+')"
grep -q "^zg 0: owner=0" <(sed 's/^ *//' "$PROC/info") &&
    pass "this node still believes it owns the stolen ZG, as a stale node would" ||
    pass "ownership view after the poke: $(grep -P '^\s+zg 0:' "$PROC/info")"

MARK="$(dmesg_mark)"
sync   # reaches ->sync_fs, which flushes the pending deltas
sleep 1

AGG_NOW="$("$ZG_POKE" "$DEV" 0 2>&1 | grep -oP 'free_data_blocks=\K[0-9]+')"
[ "$AGG_NOW" = "$AGG_AFTER_POKE" ] &&
    pass "the delta was not written into the stolen ZG ($AGG_NOW unchanged)" ||
    fail "the delta landed on a ZG this node no longer owns: $AGG_AFTER_POKE -> $AGG_NOW -- the new owner's reconciled aggregate is now double counted"

dmesg_since "$MARK" | grep -q "dropped: this zone group now belongs to node" &&
    pass "and it says so rather than dropping it silently" ||
    fail "no warning logged for a dropped delta: $(dmesg_since "$MARK" | grep -i 'zg ' | tail -2)"

[ "$(pending)" = "0" ] && pass "the delta is consumed, not left to retry forever" ||
    fail "$(pending) delta(s) still pending after the flush"

exec 9>&-
ct_umount "$MNT"
ct_exit
