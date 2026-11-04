#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write-open that fails after claiming the lock gives the lock back
#
# cetrafs_lock_open() takes the exclusive lock by CAS, then refreshes
# the in-core inode from the record; a refresh refused (-ESTALE, -EBUSY,
# -EINTR) failed the open through a label that only dropped lock_mutex.
# ->release is not called for a failed open and the node keeps beating,
# so nobody cleared the claim: every peer write-open got ETXTBSY until
# this node opened and closed the file again.
#
# open_refresh_fail_once fails the next write-open's refresh at that
# point. The open must fail, and the record must then show no lock.
#
# DISCRIMINATION: without the give-back the record still reads
# mode=1 with this node as owner.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/open_refresh_fail_once ] || { skip "open_refresh_fail_once is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 openfail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt openfail)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
echo a >"$MNT/f"
INO="$(stat -c %i "$MNT/f")"
grep -q 'mode=0' <<<"$("$LOCK_POKE" "$IMG" "$INO")" ||
    { fail "setup: the file is locked before the test ($("$LOCK_POKE" "$IMG" "$INO"))"; ct_exit; }

# A write-open that holds it, to prove the poke sees a live claim.
exec 7>>"$MNT/f"
HELD="$("$LOCK_POKE" "$IMG" "$INO")"
exec 7>&-
grep -q "owner=$NID mode=1" <<<"$HELD" ||
    { fail "setup: an open writer's claim is not visible on the device ($HELD)"; ct_exit; }
pass "setup: an open writer's claim reads owner=$NID mode=1"

MARK="$(dmesg_mark)"
ct_param_set open_refresh_fail_once 1
if ERR="$( { echo b >>"$MNT/f"; } 2>&1)"; then
    fail "setup: the write-open succeeded -- the injected refresh failure did not fire"
    ct_exit
fi
dmesg_since "$MARK" | grep -q 'test injection' ||
    { fail "setup: the open failed ($ERR) but not at the injected refresh"; ct_exit; }
pass "setup: the write-open failed at its refresh ($ERR)"

AFTER="$("$LOCK_POKE" "$IMG" "$INO")"
grep -q 'mode=0' <<<"$AFTER" && pass "the claim was given back ($AFTER)" ||
    fail "the failed open left its lock on the device ($AFTER) -- every peer write-open now gets ETXTBSY"

echo c >>"$MNT/f" && pass "a later write-open works" || fail "a later write-open failed"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
