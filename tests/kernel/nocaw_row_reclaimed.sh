#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a no-CAW mount's post-registration re-check sees a row re-claimed by another machine
#
# The post-registration single-mounter re-check watches every foreign row
# for a stale window and refuses the mount if one moves. It compared the
# row's hb_seq alone. A row re-claimed by a DIFFERENT machine restarts at
# hb_seq 1, so the same hb_seq can read "has not moved" over a row that
# changed hands while it was watched (audit C9). The watch now compares
# the whole row mark: hb_seq, incarnation and node UUID.
#
# Staged in two windows. The pre-registration gate watches a dead-looking
# row (2, uuid cc) and its verdict marks that row departed. A second row
# (1, uuid aa) appears while the gate is waiting, so the gate never
# samples it; it is a live-looking row when the post-registration re-check
# samples it. The re-check's log line means it has. Then row 1 is
# re-claimed by another machine (uuid bb, hb_seq 1 again, as a fresh
# registration writes it). The mount must refuse it.
#
# DISCRIMINATION: with the hb_seq-only compare (the pre-fix code) the watch
# sees hb_seq 1 both times, the row reads as dead, and the mount succeeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 nocawreclm)"
MNT="$(ct_mnt nocawreclm)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_param_set stale_secs 15 # before the poke: the row carries the window it was planted with
poke_dead_peer "$DEV" 2 cc
blockdev --flushbufs "$DEV"
ct_track mnt "$MNT"
NPOKE="$(ct_helper node_poke)"

MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" 2>"$(ct_tmp nocawreclm-err)" &
MPID=$!
stop_mount() { kill -9 "$MPID" 2>/dev/null || true; wait "$MPID" 2>/dev/null || true; }
for _ in $(seq 1 60); do
    dmesg_since "$MARK" | grep -q "to see whether 1 other node" && break
    sleep 0.25
done
dmesg_since "$MARK" | grep -q "to see whether 1 other node" ||
    { fail "setup: the pre-registration gate never started"; stop_mount; ct_exit; }
# Appears while the gate waits: the gate sampled only row 2.
"$NPOKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null ||
    { fail "setup: could not plant the live-looking row"; stop_mount; ct_exit; }
for _ in $(seq 1 240); do
    dmesg_since "$MARK" | grep -q "watching 1 registry row" && break
    sleep 0.25
done
dmesg_since "$MARK" | grep -q "watching 1 registry row" ||
    { fail "setup: the post-registration watch never started"; stop_mount; ct_exit; }
sleep 1
"$NPOKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null ||
    { fail "setup: could not re-claim the row"; stop_mount; ct_exit; }
RC=0
wait "$MPID" || RC=$?
LOG="$(dmesg_since "$MARK")"
if mountpoint -q "$MNT"; then
    fail "the mount succeeded while a foreign row was re-claimed under it"
    umount "$MNT"
else
    pass "the mount did not complete over the re-claimed row"
fi
grep -q "lost a simultaneous-mount race" <<<"$LOG" &&
    pass "and the re-check refused it: another node registered while the mount was in flight" ||
    fail "no lost-race refusal in dmesg (rc=$RC): the re-claimed row read as unmoved"
ct_exit
