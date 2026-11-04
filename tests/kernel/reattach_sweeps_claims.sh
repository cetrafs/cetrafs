#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node back from a crash inside the stale window gives back its old claims
#
# Peers reclaim a dead node's claims lazily -- each one when they meet
# it, by finding the holder's registry row stale. A node that crashed
# and remounted inside that window re-attached to its row, the row beat
# again, and every claim of the previous incarnation not yet met read as
# LIVE: file locks, presence bits, namespace locks held by a node with no
# memory of them. HA starting the VM elsewhere got ETXTBSY until this
# node happened to open and close that file.
#
# Staged: a clean unmount, then claims stamped with this node's row are
# planted on three records -- an exclusive lock, a presence bit, a
# namespace lock -- and the row is made to look like a crashed node's
# (last_seen set, as a beat that was never followed by an unmount). The
# remount must re-attach the row AND clear all three.
#
# DISCRIMINATION: without cetrafs_lock_sweep_own_claims() all three
# claims are still on the device after the remount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 reattsweep)"
MNT="$(ct_mnt reattsweep)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
mkdir "$MNT/dir"
for f in locked read; do echo "$f" >"$MNT/$f"; done
LI="$(stat -c %i "$MNT/locked")"; RI="$(stat -c %i "$MNT/read")"; DI="$(stat -c %i "$MNT/dir")"
ct_umount "$MNT"

"$LOCK_POKE" "$DEV" "$LI" "$NID" 1 >/dev/null
"$LOCK_POKE" "$DEV" "$RI" --reader "$NID" >/dev/null
"$LOCK_POKE" "$DEV" "$DI" --ns "$NID" >/dev/null
"$NODE_POKE" "$DEV" "$NID" --beat >/dev/null
grep -q "owner=$NID mode=1" <<<"$("$LOCK_POKE" "$DEV" "$LI")" &&
    grep -q "ns_owner=$NID" <<<"$("$LOCK_POKE" "$DEV" "$DI")" &&
    ! grep -q 'readers=0x0$' <<<"$("$LOCK_POKE" "$DEV" "$RI")" ||
    { fail "setup: the planted claims are not on the device"; ct_exit; }
pass "setup: a lock, a presence bit and a namespace lock of row $NID planted; the row looks crashed"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
NID2="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
[ "$NID2" = "$NID" ] && dmesg_since "$MARK" | grep -q "re-attached row $NID" ||
    { fail "setup: the remount did not re-attach row $NID (got $NID2)"; ct_umount "$MNT"; ct_exit; }

L="$("$LOCK_POKE" "$DEV" "$LI")"; R="$("$LOCK_POKE" "$DEV" "$RI")"; D="$("$LOCK_POKE" "$DEV" "$DI")"
grep -q 'mode=0' <<<"$L" && pass "the old exclusive lock is gone ($L)" || fail "the old exclusive lock is still held: $L"
grep -q 'readers=0x0$' <<<"$R" && pass "the old presence bit is gone ($R)" || fail "the old presence bit is still set: $R"
grep -q 'ns_owner=65535' <<<"$D" && pass "the old namespace lock is gone ($D)" || fail "the old namespace lock is still held: $D"

# And the files work.
echo more >>"$MNT/locked" && pass "the formerly locked file opens for write" || fail "the formerly locked file cannot be written"
touch "$MNT/dir/new" && pass "the formerly locked directory takes a create" || fail "a create in the formerly locked directory failed"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
