#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a COMPARE AND WRITE that landed and then reported sense is applied once
#
# On a plain SCSI device the CAW classifier read MEDIUM ERROR, HARDWARE
# ERROR, NOT READY and the rest as "definitely not executed" (-EIO), and
# retried ABORTED COMMAND in place as if it had not run. Neither is what
# the target says: only the absence of a write is promised by a
# MISCOMPARE, a UNIT ATTENTION, a RESERVATION CONFLICT, DATA PROTECT and
# an ILLEGAL REQUEST against the CDB. A delta mutator whose swap had
# landed was then applied again -- by the caller re-accruing after
# -EIO, or by the in-place retry MISCOMPAREing on its own post-image.
# The dm branch already treated them as unknown.
#
# The mount's CAS selftest (the harness loads with cas_selftest=1) runs
# an increment across each such command on a real CAW target -- the LIO
# loopback fabric -- via caw_sense_landed_once, and requires the delta
# applied exactly once.
#
# DISCRIMINATION: with the old classifier the MEDIUM ERROR phase fails
# the increment with -EIO and the ABORTED COMMAND phase applies it twice;
# either way the selftest reports FAILED.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ "$(cat /sys/module/cetrafs/parameters/cas_selftest 2>/dev/null)" = Y ] ||
    { skip "the module was not loaded with cas_selftest=1"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/caw_sense_landed_once ] ||
    { skip "caw_sense_landed_once is missing"; ct_exit; }

IMG="$(ct_image 560 cawsense)"
MNT="$(ct_mnt cawsense)"
WHY="$(ct_tmp cawsense-why)"
DISK="$(ct_lio_disks "$IMG" 1 2>"$WHY")" || { skip "$(cat "$WHY")"; ct_exit; }
ct_track mnt "$MNT"
ct_mkfs_small "$DISK" >/dev/null

MARK="$(dmesg_mark)"
ct_mount "$DISK" "$MNT"
require_cetrafs_mount "$MNT"
grep -q 'available=yes' "$(ct_procdir "$DISK")/properties" ||
    { fail "setup: the LIO disk is not driven with CAW"; ct_exit; }
D="$(dmesg_since "$MARK")"
for what in "MEDIUM ERROR after landing" "ABORTED COMMAND after landing"; do
    if grep -q "TEST caw_sense_landed_once" <<<"$D" &&
        grep -q "a timed-out ($what) command applied the delta exactly once" <<<"$D"; then
        pass "$what: the delta was applied exactly once"
    else
        fail "$what: $(grep -E "CAS selftest.*($what|FAILED)" <<<"$D" | head -2)"
    fi
done
grep -q 'CAS selftest: PASSED' <<<"$D" && pass "the selftest passed" ||
    fail "the selftest did not pass: $(grep 'CAS selftest' <<<"$D" | grep -iv passed | tail -3)"
echo x >"$MNT/f" && pass "the volume works afterwards" || fail "a write failed after the selftest"
ct_umount "$MNT"
ct_exit
