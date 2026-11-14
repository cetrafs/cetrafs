#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every growfs knob that damages the volume is refused off a test device
#
# growfs reads its test knobs through cetrafs_test_env_damaging(), which
# refuses the run (exit 2) before anything is written unless the device is
# an image file, a loop device or a dm stack over loops. Four knobs were
# gated. CETRAFS_GROWFS_TEST_BG_OFFSET (headers written over live groups),
# CETRAFS_GROWFS_TEST_DESC_SHIFT (descriptors written at a shifted place)
# and CETRAFS_GROWFS_TEST_KEEP_DEAD_CREDIT (accounting left wrong) were
# honoured on any device: a shell that inherited one from a test session
# grew a production volume with a stderr banner as the only sign (audit
# 2026-11-14 U4).
#
# A real non-test block device is not available to this suite (only loop
# devices are, and only through the harness), so the device here is
# /dev/zero: a character device, which the gate treats exactly as it
# treats any device that is not a test device. growfs must refuse each
# knob with the damaging-knob message and exit 2. The gate runs right
# after open(), before the first read or write, so the refusal is also
# what keeps the write path from being reached.
#
# DISCRIMINATION (measured on the unfixed code): the three knobs are not
# gated, growfs runs on into BLKGETSIZE64 and dies with exit 1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
GROW="$ROOT/userspace/growfs.cetra"
DMG="damages the volume and is honoured only on"

for knob in CETRAFS_GROWFS_TEST_BG_OFFSET CETRAFS_GROWFS_TEST_DESC_SHIFT CETRAFS_GROWFS_TEST_KEEP_DEAD_CREDIT; do
    rc=0
    OUT="$(env "$knob=1" timeout 20 "$GROW" /dev/zero 2>&1)" || rc=$?
    if [ "$rc" = 2 ] && grep -q "$DMG" <<<"$OUT"; then
        pass "$knob refused on a non-test device, exit 2, before any write"
    else
        fail "$knob was not refused (exit $rc): $(tail -1 <<<"$OUT")"
    fi
done
ct_exit
