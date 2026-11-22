#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every fsck knob that removes a repair gate is refused off a test device
#
# fsck's test knobs that switch a repair gate off -- clear leaks past an
# unread directory, revive any inode, free dead runs that are damaged or
# shared, clear or repair over unreplayed journal entries, restamp a
# record that does not verify, trust a damaged bitmap in a rebuild --
# were read through cetrafs_test_env(), honoured on any device with a
# stderr banner as the only sign. A shell that inherited one from a test
# session ran fsck -r on a production LUN with that gate gone (audit
# 2026-11-22 N-12). They now go through cetrafs_test_env_damaging(),
# judged right after open() before the first read: exit 2 off an image
# file, a loop device or a dm stack over loops.
#
# As growfs_damaging_knobs_gate.sh: the device is /dev/zero, which the
# gate treats as any device that is not a test device.
#
# DISCRIMINATION (measured on the unfixed code): the knobs are not
# judged, and fsck runs on into the device size probe and fails there,
# without the damaging-knob message.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
FSCK="$ROOT/userspace/fsck.cetra"
DMG="damages the volume and is honoured only on"

for knob in CETRAFS_TEST_FSCK_LEAK_UNGATED CETRAFS_TEST_FSCK_REVIVE_ANY CETRAFS_TEST_FSCK_DEAD_DAMAGED_OK \
    CETRAFS_TEST_FSCK_DEAD_SHARE_OK CETRAFS_TEST_FSCK_CLEAR_OVER_JOURNAL CETRAFS_TEST_FSCK_PENDING_JOURNAL_OK \
    CETRAFS_FSCK_RESTAMP_UNVERIFIED CETRAFS_FSCK_TEST_REBUILD_TRUST_BAD_SECTOR; do
    rc=0
    OUT="$(env "$knob=1" timeout 20 "$FSCK" /dev/zero 2>&1)" || rc=$?
    if [ "$rc" = 2 ] && grep -q "$DMG" <<<"$OUT"; then
        pass "$knob refused on a non-test device, exit 2, before any read"
    else
        fail "$knob was not refused (exit $rc): $(tail -1 <<<"$OUT")"
    fi
done
ct_exit
