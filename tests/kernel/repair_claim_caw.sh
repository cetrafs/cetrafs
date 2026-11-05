#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair claim is a COMPARE AND WRITE where the device has one
#
# fsck -r and growfs claim a registry row before they write. They wrote
# it blind, then settled and looked again for a collision. A second
# repairer that read the row FREE, stalled, and wrote after the first
# had settled and looked, landed on top of the first claim and found
# itself the owner: both repaired, until the first one's next renewal
# found its row gone. The claim (and the renewals, the release and the
# reap) are now a SCSI COMPARE AND WRITE through SG_IO wherever the
# device has the command, so the late claim miscompares instead.
#
# A loop device has no CAW: this runs on a LIO loopback disk
# (ct_lio_disks). The late claimant is held between its read of the row
# and its claim (CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS) while the other
# claims, settles and holds.
#
# CONTROL, built in: the same race with CETRAFS_TEST_TOOLS_NO_CAW=1 (the
# blind path, which a device without CAW still takes) lets the late
# claimant through -- proving the staging reaches the race.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3

IMG="$(ct_image 600 rccaw)"
DISK="$(ct_lio_disks "$IMG" 1)" || { skip "no LIO loopback target here"; ct_exit; }
ct_mkfs "$DISK" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null

OUT="$("$FSCK" -r "$DISK" 2>&1 || true)"
grep -q "registry claim written by COMPARE AND WRITE" <<<"$OUT" &&
    pass "fsck -r claims by COMPARE AND WRITE on a disk that has it" ||
    { fail "fsck -r did not use CAW on a CAW disk: $(grep -m2 'registry claim\|ERR' <<<"$OUT")"; ct_exit; }

# race <no_caw:0|1>: B reads the row and stalls; A claims meanwhile; B
# claims late. Prints "<B reached its repair:0|1> <A lost its claim:0|1>".
race() {
    local env=() ob oa pb pa bin=0 alost=0
    [ "$1" = 1 ] && env=(CETRAFS_TEST_TOOLS_NO_CAW=1)
    ob="$(ct_tmp rccaw-b)"; oa="$(ct_tmp rccaw-a)"
    env "${env[@]}" CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS=7 CETRAFS_TEST_REPAIR_HOLD_SECS=8 "$FSCK" -r "$DISK" >"$ob" 2>&1 &
    pb=$!
    sleep 1
    env "${env[@]}" CETRAFS_TEST_REPAIR_HOLD_SECS=16 "$FSCK" -r "$DISK" >"$oa" 2>&1 &
    pa=$!
    wait "$pb" || true
    wait "$pa" || true
    grep -q "claimed registry row" "$ob" && bin=1
    grep -q "claim was taken away" "$oa" && alost=1
    grep -q "claimed registry row" "$oa" || { echo "SETUP $(tr '\n' '|' <"$oa" | tail -c 400)"; return; }
    echo "$bin $alost"
}

read -r CB CA < <(race 1)
[ "$CB" = SETUP ] && { fail "setup: the first claimant never claimed: $CA"; ct_exit; }
log "control (blind writes): late claimant repaired=$CB, first lost its claim=$CA"
[ "$CB" = 1 ] && pass "control: with blind writes the late claim lands on the first -- the race is staged" ||
    { fail "setup: even blind writes did not let the late claim through ($CB/$CA) -- this proves nothing"; ct_exit; }

read -r RB RA < <(race 0)
[ "$RB" = SETUP ] && { fail "setup: the first claimant never claimed: $RA"; ct_exit; }
log "CAW: late claimant repaired=$RB, first lost its claim=$RA"
[ "$RB" = 0 ] && pass "CAW: the late claim miscompared and that repairer stopped" ||
    fail "CAW: the late claimant repaired over a live claim"
[ "$RA" = 0 ] && pass "CAW: the first repairer kept its claim" || fail "CAW: the first repairer lost its claim"

OUT="$(ct_fsck "$DISK" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
