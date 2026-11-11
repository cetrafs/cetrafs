#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAS whose outcome is unknown is decided from the device, even while this node holds a dirty copy
#
# When a COMPARE AND WRITE times out, a re-read decides whether it
# landed. That re-read went through the buffer cache's forced-fresh
# read, which keeps this node's own DIRTY copy rather than fetch over a
# pending write -- right everywhere else, and here it meant the device
# was never asked: the outcome was declared undecidable and the mount
# stopped (audit 2026-11-11 C3). It now reads the device with a bio.
#
# The mount's CAS selftest (the harness loads with cas_selftest=1) runs
# the case on a real CAW target -- the LIO loopback fabric: a command
# that times out after landing, with the cached copy dirtied right
# before the re-read (cas_verify_dirty_once). Required: decided, no
# mount stop, the delta applied once and still applied after the dirty
# copy is written back.
#
# DISCRIMINATION (2026-11-11, caw.c before this fix, with this
# selftest): "a timeout the device could decide stopped the mount", and
# the selftest reports FAILED.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ "$(cat /sys/module/cetrafs/parameters/cas_selftest 2>/dev/null)" = Y ] ||
    { skip "the module was not loaded with cas_selftest=1"; ct_exit; }
IMG="$(ct_image 560 casvfy)"
MNT="$(ct_mnt casvfy)"
WHY="$(ct_tmp casvfy-why)"
DISK="$(ct_lio_disks "$IMG" 1 2>"$WHY")" || { skip "$(cat "$WHY")"; ct_exit; }
ct_track mnt "$MNT"
ct_mkfs_small "$DISK" >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DISK" "$MNT"
require_cetrafs_mount "$MNT"
grep -q 'available=yes' "$(ct_procdir "$DISK")/properties" ||
    { fail "setup: the LIO disk is not driven with CAW"; ct_exit; }
D="$(dmesg_since "$MARK")"
grep -q "CAS selftest: starting .* via the atomic CAW path" <<<"$D" ||
    { fail "setup: the selftest did not run on the CAW path: $(grep 'CAS selftest' <<<"$D" | head -2)"; ct_exit; }
grep -q "a timeout decided from the device past a dirty local copy, applied once" <<<"$D" &&
    pass "a timed-out swap is decided from the device past a dirty copy, applied once" ||
    fail "$(grep -E 'CAS selftest.*(dirty|decide|FAILED)' <<<"$D" | head -2)"
! grep -q "would stop the mount here" <<<"$D" && pass "and nothing reached the mount stop" ||
    fail "the selftest reached the mount stop: $(grep 'would stop the mount' <<<"$D" | head -1)"
grep -q 'CAS selftest: PASSED' <<<"$D" && pass "the selftest passed" ||
    fail "the selftest did not pass: $(grep 'CAS selftest' <<<"$D" | grep -iv passed | tail -3)"
echo x >"$MNT/f" && pass "the volume works afterwards" || fail "a write failed after the selftest"
ct_umount "$MNT"
ct_exit
