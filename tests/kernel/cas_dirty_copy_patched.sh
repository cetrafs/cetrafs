#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAS over a block this node holds dirty is not undone when that copy is written back
#
# A swap goes to the device behind the buffer cache; afterwards the
# cached copy is made to agree. For a block of several independently
# swapped regions -- the record CAS among them -- that step only DROPPED
# the buffer, with cetrafs_invalidate_block(), which keeps a dirty one:
# a pending write is the newest content of the rest of the block. But
# that buffer still held the swapped region's pre-image, and its
# write-back put it back over the swap, on the device, for every node
# (audit 2026-11-11 C2). The swap's bytes are now patched into any
# uptodate buffer first.
#
# The mount's CAS selftest (cas_selftest=1) runs it as phase 2e on a
# real CAW target -- the LIO loopback fabric: the cached block is
# dirtied after the swap's own flush (cas_dirty_after_flush_once, a
# local writer landing there), the swap goes out, the dirty copy is
# written back, the device is read.
#
# DISCRIMINATION (2026-11-11, caw.c before this fix, with this
# selftest): "writing back a dirty local copy undid a swap", the
# selftest reports FAILED.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ "$(cat /sys/module/cetrafs/parameters/cas_selftest 2>/dev/null)" = Y ] ||
    { skip "the module was not loaded with cas_selftest=1"; ct_exit; }
IMG="$(ct_image 560 casdirty)"
MNT="$(ct_mnt casdirty)"
WHY="$(ct_tmp casdirty-why)"
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
grep -q "a swap over a dirty local copy survives its write-back" <<<"$D" &&
    pass "a swap over a dirty local copy survives its write-back" ||
    fail "$(grep -E 'CAS selftest.*(undid a swap|over a dirty|FAILED)' <<<"$D" | head -2)"
grep -q 'CAS selftest: PASSED' <<<"$D" && pass "the selftest passed" ||
    fail "the selftest did not pass: $(grep 'CAS selftest' <<<"$D" | grep -iv passed | tail -3)"
echo x >"$MNT/f" && pass "the volume works afterwards" || fail "a write failed after the selftest"
ct_umount "$MNT"
ct_exit
