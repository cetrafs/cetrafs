#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a device error while defrag claims its destination run is reported as an I/O error, not a stop and ENOSPC
#
# cetrafs_alloc_data_run_resv() claims a scanned-free run bit by bit.
# A failure there was handled as the one case that cannot happen -- a
# bit taken under the alloc mutex -- whatever it was: the mount was
# stopped and the caller told ENOSPC. A bitmap read error is not that
# case: the defragmenter was sent to look for space on a failing disk,
# and the whole mount went down with it. Now only a taken bit stops the
# mount; a device error is returned as itself, the bits already claimed
# are given back, and a give-back that fails is logged.
#
# run_alloc_fail_once fails the run's SECOND bit with -EIO, so the first
# has to be given back.
#
# DISCRIMINATION: without the change the mount stops ("taken under the
# alloc mutex") and defrag reports "No space left on device".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/run_alloc_fail_once ] || { skip "run_alloc_fail_once is missing"; ct_exit; }

DEV="$(ct_dev 560 runeio)"
MNT="$(ct_mnt runeio)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
for i in $(seq 0 15); do
    dd if=/dev/urandom of="$MNT/frag" bs=4096 seek="$i" count=1 conv=notrunc status=none
    printf x >"$MNT/filler$i"
done
sync
SUM="$(md5sum <"$MNT/frag")"

MARK="$(dmesg_mark)"
ct_param_set run_alloc_fail_once 1
OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/frag" 2>&1)" && RC=0 || RC=$?
LEFT="$(cat /sys/module/cetrafs/parameters/run_alloc_fail_once)"
ct_param_set run_alloc_fail_once 0
[ "$LEFT" = N ] && pass "setup: defrag claimed a run and its second bit failed" ||
    { fail "setup: the knob was not reached ($OUT)"; ct_exit; }
[ "$RC" != 0 ] && grep -qi "input/output error" <<<"$OUT" &&
    pass "defrag reports an I/O error" || fail "defrag rc=$RC: $OUT"
grep -qi "no space" <<<"$OUT" && fail "defrag reported ENOSPC for a device error" || pass "not ENOSPC"
[ "$(sed -n 's/^stopped: //p' "$PROC/info")" = none ] && pass "the mount is not stopped" ||
    fail "the mount stopped: $(dmesg_since "$MARK" | grep -m1 STOPPED)"
[ "$(md5sum <"$MNT/frag")" = "$SUM" ] && pass "the file is unchanged" || fail "the file changed"
OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/frag" 2>&1)" && pass "a second defrag succeeds" ||
    fail "a second defrag failed: $OUT"
[ "$(md5sum <"$MNT/frag")" = "$SUM" ] && pass "and the file still reads the same" || fail "the file changed"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)" ||
    pass "fsck clean: the first bit was given back"
ct_exit
