#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node back from a crash read-only recovers like ext4: replay, then sweep
#
# A read-only mount skipped this node's own journal replay ("an
# observer must not write") and with it the claim sweep, which needs the
# replay first. The node re-attached its row and beat, so every claim of
# its previous incarnation -- file lock, presence bit, namespace lock --
# read LIVE for as long as it stayed mounted read-only: ETXTBSY on its
# files on every other node. ext4 and XFS recover their logs on a
# read-only mount; so does this now. A read-only DEVICE cannot carry a
# registry row at all, and is refused as ext4 refuses one needing
# recovery.
#
# Staged as reattach_sweeps_claims.sh, remounting read-only.
#
# DISCRIMINATION: with replay and sweep gated on !sb_rdonly, all three
# claims are still on the device after the read-only mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 roreatt)"
MNT="$(ct_mnt roreatt)"
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
mount -t cetrafs -o ro "$DEV" "$MNT" || { fail "the read-only mount failed"; ct_exit; }
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -q "re-attached row $NID" ||
    { fail "setup: the read-only mount did not re-attach row $NID"; ct_umount "$MNT"; ct_exit; }

L="$("$LOCK_POKE" "$DEV" "$LI")"; R="$("$LOCK_POKE" "$DEV" "$RI")"; D="$("$LOCK_POKE" "$DEV" "$DI")"
grep -q 'mode=0' <<<"$L" && pass "read-only: the old exclusive lock is gone" || fail "read-only: the old lock is still held: $L"
grep -q 'readers=0x0$' <<<"$R" && pass "read-only: the old presence bit is gone" || fail "read-only: the old presence bit is still set: $R"
grep -q 'ns_owner=65535' <<<"$D" && pass "read-only: the old namespace lock is gone" || fail "read-only: the old namespace lock is still held: $D"
cat "$MNT/locked" >/dev/null && pass "and the volume reads" || fail "a read failed on the read-only mount"
ct_umount "$MNT"

# An unknown RO_COMPAT feature: mountable read-only because this build
# must not write the volume -- so it must not replay into it either. A
# crashed row is refused; a cleanly departed one mounts.
"$NODE_POKE" "$DEV" "$NID" --beat >/dev/null
"$(ct_helper sb_poke)" "$DEV" features_ro_compat 0x8000000000000000 >/dev/null
blockdev --flushbufs "$DEV"
MARK="$(dmesg_mark)"
if mount -t cetrafs -o ro "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"; fail "unknown RO_COMPAT: a crashed row was recovered by a build that does not know the volume"
else
    dmesg_since "$MARK" | grep -q "cannot recover it" && pass "unknown RO_COMPAT: a crashed row is refused, and says why" ||
        fail "unknown RO_COMPAT: refused, but not for this: $(dmesg_since "$MARK" | grep -m1 -i 'refus\|fail\|unsupported')"
fi
"$NODE_POKE" "$DEV" "$NID" 1 00 0 >/dev/null 2>&1 || true   # departed cleanly
blockdev --flushbufs "$DEV"
mount -t cetrafs -o ro "$DEV" "$MNT" 2>/dev/null && { pass "unknown RO_COMPAT: a cleanly departed node mounts read-only"; ct_umount "$MNT"; } ||
    fail "unknown RO_COMPAT: a clean read-only mount was refused"
"$(ct_helper sb_poke)" "$DEV" features_ro_compat 0 >/dev/null

# A read-only device: refused, and nothing written.
blockdev --flushbufs "$DEV"
SUM="$(dd if="$DEV" bs=1M count=8 status=none | sha256sum)"
blockdev --setro "$DEV"
MARK="$(dmesg_mark)"
if mount -t cetrafs -o ro "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"; fail "a read-only device was mounted"
else
    dmesg_since "$MARK" | grep -q "the device is read-only" && pass "a read-only device is refused, and says why" ||
        fail "a read-only device was refused without the reason: $(dmesg_since "$MARK" | grep -m1 -i 'refus\|fail')"
fi
blockdev --setrw "$DEV"
[ "$(dd if="$DEV" bs=1M count=8 status=none | sha256sum)" = "$SUM" ] && pass "and nothing was written to it" ||
    fail "the refused mount wrote to the device"
ct_exit
