#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repairer's lease renewals reach the device, not just its page cache
#
# fsck -r and growfs hold a REPAIR row in the Node Registry and renew it
# every CETRAFS_REPAIR_RENEW_SECS on a timer; a mounting node watches
# hb_seq for CETRAFS_REPAIR_PROBE_SECS and calls the claim dead if it
# does not move. The claim itself was fsync'd, the renewals were plain
# buffered pwrites: they sat in the repairer's page cache until
# writeback (dirty_expire, 30 s by default), so a node on ANOTHER host
# -- which reads the platter -- saw hb_seq frozen for longer than it
# watches, judged the repairer gone and mounted in the middle of the
# repair.
#
# Staged: fsck -r held in a quiet phase on a loop device; the row is
# read from the BACKING FILE, which is what the platter is to another
# host. Its hb_seq must move within the probe window.
#
# DISCRIMINATION: without the fdatasync in cetrafs_repair_renew(), the
# backing file's hb_seq stays at the claim's value for the whole window
# (it moves only when writeback gets round to it, ~30 s).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"

EXPIRE="$(cat /proc/sys/vm/dirty_expire_centisecs)"
[ "$EXPIRE" -ge 2000 ] ||
    { skip "vm.dirty_expire_centisecs=$EXPIRE: writeback alone beats the probe window, the test could not tell"; ct_exit; }

IMG="$(ct_image 560 renewdur)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" >/dev/null
blockdev --flushbufs "$DEV"

hbseq() { sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p' <<<"$("$NPOKE" "$IMG" 0)"; }
state() { sed -n 's/.*state=\([0-9]*\).*/\1/p' <<<"$("$NPOKE" "$IMG" 0)" | head -1; }

(CETRAFS_TEST_REPAIR_HOLD_SECS=22 "$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true) &
FPID=$!
for _ in $(seq 1 40); do [ "$(state)" = 2 ] && break; sleep 0.25; done
[ "$(state)" = 2 ] || { fail "setup: fsck -r's claim never reached the backing file"; wait "$FPID"; ct_exit; }
S1="$(hbseq)"
pass "setup: the claim is on the device (hb_seq $S1)"

# The probe window a mounting node on another host would use.
sleep 15
S2="$(hbseq)"
wait "$FPID" || true

if [ -n "$S2" ] && [ "$S2" -gt "$S1" ]; then
    pass "the renewals reached the device inside the probe window (hb_seq $S1 -> $S2)"
else
    fail "hb_seq on the device stayed at $S1 for 15 s -- a node on another host calls the repairer dead and mounts"
fi
blockdev --flushbufs "$DEV"
[ "$(state)" = 0 ] && pass "the claim was released" || fail "the claim was left in state $(state)"
ct_exit
