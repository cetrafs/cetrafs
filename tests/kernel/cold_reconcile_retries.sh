#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a cold-tree reconcile that could not read the record tries again
#
# When a peer's publish is noticed, the file's cached extent tree is
# marked cold and a reconcile on the mount's queue drops it and settles
# the mark; until then every tree read goes to the device. A reconcile
# whose allocation or record read failed settled nothing and was never
# queued again -- only a new mark queues it, and a running VM never
# reopens its disk: forced-fresh reads for the life of the open (audit
# 2026-11-05, section 3).
#
# cold_read_fail fails the next reconcile's record read; a stat marks the
# tree. The reconcile must still complete (file_cache_reconciles moves).
#
# DISCRIMINATION: proven 2026-11-05 without the retry: the counter does
# not move and the tree stays cold.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/cold_read_fail ] || { skip "cold_read_fail is missing"; ct_exit; }

DEV="$(ct_dev 560 coldre)"
MNT="$(ct_mnt coldre)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
INFO="$(ct_procdir "$DEV")/info"
rec() { sed -n 's/^file_cache_reconciles: //p' "$INFO"; }
echo data >"$MNT/v"
sync
stat "$MNT/v" >/dev/null
sleep 0.5
R0="$(rec)"
stat "$MNT/v" >/dev/null
sleep 0.5
[ "$(rec)" -gt "$R0" ] || { fail "setup: a stat does not reconcile this file's tree at all ($R0 -> $(rec))"; ct_exit; }

R0="$(rec)"
ct_param_set cold_read_fail 1
stat "$MNT/v" >/dev/null
sleep 2
LEFT="$(cat /sys/module/cetrafs/parameters/cold_read_fail)"
ct_param_set cold_read_fail 0
[ "$LEFT" = 0 ] || { fail "setup: no reconcile ran into the failure (knob still $LEFT)"; ct_exit; }
R1="$(rec)"
[ "$R1" -gt "$R0" ] && pass "a reconcile whose read failed was retried and settled ($R0 -> $R1)" ||
    fail "a reconcile whose read failed was never retried: the tree stays cold ($R0 -> $R1)"
ct_umount "$MNT"
ct_exit
