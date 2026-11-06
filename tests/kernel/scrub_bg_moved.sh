#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub frees a block only while its Block Group is still its Zone Group's
#
# The scrub re-checks, at each free, that the Zone Group it judged is
# still this node's. Block Groups are released and claimed one at a
# time, though, so the Zone Group can stay ours while the Block Group
# went back to the pool and on to a peer -- and the free then became a
# foreign free applied to whatever the new owner keeps there (audit
# 2026-11-06 L18).
#
# Staged as scrub.sh: 40 blocks leaked in BG 0, the fast scrub armed;
# scrub_bg_moved_once makes BG 0 read as released at the first free's
# ownership check. The scrub must abandon it and free nothing.
#
# DISCRIMINATION: checking the Zone Group alone, the scrub frees the
# leaked blocks of a Block Group that is no longer its own.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/scrub_bg_moved_once ] || { skip "scrub_bg_moved_once is missing"; ct_exit; }
LEAK="$(ct_helper data_leak_poke)"

DEV="$(ct_dev 560 scrubbg)"
MNT="$(ct_mnt scrubbg)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
info() { cat "$(ct_procdir "$DEV")/info"; }
reclaimed() { info | sed -n 's/^scrub_reclaimed: //p'; }
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
"$LEAK" "$DEV" 0 100 40 >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
BASE="$(reclaimed)"
MARK="$(dmesg_mark)"
ct_param_set scrub_bg_moved_once 1
ct_param_set scrub 1
for _ in $(seq 1 20); do
    [ "$(cat /sys/module/cetrafs/parameters/scrub_bg_moved_once)" = N ] && break
    sleep 0.5
done
ct_param_set scrub 0
[ "$(cat /sys/module/cetrafs/parameters/scrub_bg_moved_once)" = N ] ||
    { fail "setup: the scrub never reached a free in BG 0"; ct_umount "$MNT"; ct_exit; }
sleep 1
REC="$(( $(reclaimed) - BASE ))"
[ "$REC" = 0 ] && pass "the scrub freed nothing in a Block Group that left its Zone Group" ||
    fail "the scrub freed $REC block(s) in a Block Group that is no longer its own"
dmesg_since "$MARK" | grep -q "scrub: BG 0 left ZG 0 mid-cycle" && pass "and said why" ||
    fail "no word about the Block Group moving"
umount "$MNT" # the in-core ownership was faked: nothing more on this mount
ct_exit
