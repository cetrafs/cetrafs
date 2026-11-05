#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a nofilelock close whose publish failed is retried, not forgotten
#
# The last writer's close publishes the file's size and extents to its
# record. On a mount that takes the whole-file lock, a failed publish keeps
# the lock and queues the close for the heartbeat. Under nofilelock -- and
# for a suspended writer -- there is no lock to keep, and the failure was
# returned as 0: nothing queued, nothing reported, the close's durability
# boundary passed with the record still saying what it said before (audit
# 2026-11-05, class 21). nofilelock is the datastore mode, and the last
# writer's close ahead of a migration is exactly where it lands.
#
# close_publish_fail makes the next close's publish fail without writing.
# The heartbeat must then finish it: the record on the device carries the
# new size within a few ticks, well before VFS writeback's 30 s expiry
# would have published it anyway.
#
# DISCRIMINATION: proven 2026-11-05 with the old `!may_clear` return (knob
# kept): nothing is queued, no retry is logged, and the record still says
# size 0 when the suite reads it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/close_publish_fail ] || { skip "close_publish_fail is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 clpr)"
MNT="$(ct_mnt clpr)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
: >"$MNT/vm.img"
sync
INO="$(stat -c %i "$MNT/vm.img")"
recsize() { "$LOCK_POKE" "$DEV" "$INO" --rec | sed -n 's/^size=\([0-9]*\).*/\1/p'; }
[ "$(recsize)" = 0 ] || { fail "setup: the new file's record does not say size 0 ($(recsize))"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set close_publish_fail 1
dd if=/dev/urandom of="$MNT/vm.img" bs=4096 count=64 conv=notrunc status=none
LEFT="$(cat /sys/module/cetrafs/parameters/close_publish_fail)"
ct_param_set close_publish_fail 0
[ "$LEFT" = 0 ] || { fail "setup: the close never reached its publish (knob still $LEFT)"; umount "$MNT"; ct_exit; }
dmesg_since "$MARK" | grep -q "ino=$INO failed to persist inode state" &&
    pass "setup: the close's publish failed (logged)" ||
    fail "setup: no failed publish logged for ino $INO"

# No fsync: the close is the only boundary that publishes the size, so
# until the retry the record must still say 0 -- asked within writeback's
# 30 s expiry, which would publish it on its own.
GOT=""
for _ in $(seq 1 20); do
    dmesg_since "$MARK" | grep -q "ino=$INO close publish and flock clear finished by the heartbeat" && { GOT=1; break; }
    sleep 1
done
[ -n "$GOT" ] && pass "the heartbeat finished the close's publish" ||
    fail "no retry of the failed close publish within 20 s -- it was not queued"
S="$(recsize)"
[ "$S" = 262144 ] && pass "the record on the device carries the new size ($S)" ||
    fail "the record on the device says size $S, not 262144"
umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
