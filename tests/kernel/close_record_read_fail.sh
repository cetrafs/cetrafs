#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a close whose record read fails publishes nothing and is retried
#
# A last writer's close reads its record (overlaid with the shadow) to
# flush the extent tree's leaves, then publishes the record. A failed
# read skipped the leaf flush and the publish went ahead anyway -- a
# record naming leaves that may never have reached the device (rule 8);
# and with no lock to clear (nofilelock, a suspended writer) the error
# went nowhere (audit 2026-11-06 L7). It is now a failed close like a
# failed leaf flush: nothing published, retried by the heartbeat.
#
# Staged under nofilelock with close_record_read_fail: right after the
# close the record must still say size 0, and the heartbeat must then
# publish it.
#
# DISCRIMINATION: with the read's result ignored, the close publishes at
# once and nothing is queued.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/close_record_read_fail ] || { skip "close_record_read_fail is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 clrr)"
MNT="$(ct_mnt clrr)"
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
ct_param_set close_record_read_fail 1
dd if=/dev/urandom of="$MNT/vm.img" bs=4096 count=64 conv=notrunc status=none
LEFT="$(cat /sys/module/cetrafs/parameters/close_record_read_fail)"
ct_param_set close_record_read_fail 0
[ "$LEFT" = N ] || { fail "setup: the close never reached its record read"; umount "$MNT"; ct_exit; }
S0="$(recsize)"
[ "$S0" = 0 ] && pass "a close whose record read failed published nothing" ||
    fail "a close whose record read failed published anyway (size $S0)"
GOT=""
for _ in $(seq 1 20); do
    [ "$(recsize)" = 262144 ] && { GOT=1; break; }
    sleep 1
done
[ -n "$GOT" ] && pass "the retry published the close (size 262144)" ||
    fail "the failed close was never finished: the record says $(recsize)"
dmesg_since "$MARK" | grep -q "ino=$INO close publish and flock clear finished by the heartbeat" &&
    pass "the heartbeat finished it" || fail "the close was not queued for the heartbeat"
umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
