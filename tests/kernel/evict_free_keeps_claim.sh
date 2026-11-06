#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free that freed blocks keeps its claim until the number is free too
#
# Evict claims the dead record, frees its blocks, then frees the number
# (cetrafs_free_inode_begin()/_finish()). Once a block is freed, the
# claim may not go back over a number still allocated: the next evict of
# the same file -- a peer's in-core copy -- would win it, find the number
# set and free the same blocks again, by then perhaps another file's.
# So a number free that fails keeps the claim and the heartbeat finishes
# it, and a node back from a crash with such a claim frees the number
# before it releases (cetrafs_lock_sweep_own_claims()).
#
#   (1) evict_number_free_fail: right after the unlink the record is
#       still claimed by this node and its number allocated; within a
#       few beats the heartbeat has freed the number and released.
#   (2) an allocated, dead record claimed by this node's row is planted
#       on the image and the row made to look crashed: the remount frees
#       the number as well as clearing the claim.
#
# DISCRIMINATION: releasing the claim on a failed number free, (1) reads
# the record unclaimed with the number still set; with the sweep only
# releasing, (2) leaves the number allocated.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/evict_number_free_fail ] || { skip "evict_number_free_fail is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
ORPHAN_POKE="$(ct_helper orphan_poke)"

DEV="$(ct_dev 560 evclaim)"
MNT="$(ct_mnt evclaim)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_param_set scrub 0 # the orphan scrub would free the planted number on its own
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
nsowner() { "$LOCK_POKE" "$DEV" "$1" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p'; }
# the number's bit, as fsck reports an allocated dead record
# (captured first: grep -q exits at the match and, under pipefail, the
# fsck it cut off would turn a found line into a miss)
orphaned() { local o; o="$(ct_fsck "$DEV" 2>&1 || true)"; grep -q "inode $1 is allocated but has nlink=0" <<<"$o"; }

# (1) the heartbeat finishes a free whose number could not be cleared
dd if=/dev/urandom of="$MNT/f" bs=4096 count=64 status=none
sync
INO="$(stat -c %i "$MNT/f")"
MARK="$(dmesg_mark)"
ct_param_set evict_number_free_fail 1
rm "$MNT/f"
O="$(nsowner "$INO")"
LEFT="$(cat /sys/module/cetrafs/parameters/evict_number_free_fail)"
ct_param_set evict_number_free_fail 0
[ "$LEFT" = 0 ] || { fail "setup: the evict never reached its number free"; ct_exit; }
[ "$O" = "$NID" ] && pass "a failed number free keeps the claim (ns_owner $O)" ||
    fail "a free that had freed its blocks released its claim with the number still allocated (ns_owner $O)"
GOT=""
for _ in $(seq 1 20); do
    dmesg_since "$MARK" | grep -q "ino=$INO: an evict's number free finished by the heartbeat" && { GOT=1; break; }
    sleep 1
done
[ -n "$GOT" ] && pass "the heartbeat finished the number free" || fail "no heartbeat finished the number free in 20 s"
O="$(nsowner "$INO")"
[ "$O" = 65535 ] && pass "and released the claim after it" || fail "the claim is still held after the finish (ns_owner $O)"
ct_umount "$MNT"
orphaned "$INO" && fail "the number is still allocated after the finish" || pass "the number is free on the device"

# (2) a node back from a crash finishes the free it had claimed
PINO=200
"$ORPHAN_POKE" "$DEV" "$PINO" 0 0 >/dev/null
"$LOCK_POKE" "$DEV" "$PINO" --ns "$NID" >/dev/null
# checked before the row is made to look crashed: the tools wait out a
# live-looking row's stale window (up to 240 s) before they will read
[ "$(nsowner "$PINO")" = "$NID" ] && orphaned "$PINO" ||
    { fail "setup: the planted claimed dead record is not on the device"; ct_exit; }
"$NODE_POKE" "$DEV" "$NID" --beat >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
dmesg_since "$MARK" | grep -q "re-attached row $NID" ||
    { fail "setup: the remount did not re-attach row $NID"; ct_umount "$MNT"; ct_exit; }
ct_umount "$MNT"
O="$(nsowner "$PINO")"
[ "$O" = 65535 ] && pass "the re-attach released the old claim" || fail "the old claim is still held (ns_owner $O)"
orphaned "$PINO" && fail "the re-attach released the claim and left the number allocated" ||
    pass "the re-attach freed the number before releasing the claim"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
