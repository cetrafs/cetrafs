#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a new node in a peer's row is not judged stale from its predecessor's sample
#
# A peer is judged dead by watching its row's hb_seq stand still for a
# window of OUR clock. The watch was keyed on hb_seq alone -- and hb_seq
# restarts at 1 when a row is registered afresh, so a sample of the row's
# previous holder could match the new holder's first beat with its
# seen_at long in the past: a live, just-registered node judged stale at
# once, its lock broken and its lease revoked (audit 2026-11-05, class
# 28). The watch now restarts when another machine holds the row.
#
# Staged with a 20 s window: mount samples peer row 1 (uuid aa, hb_seq 1,
# holding a file's lock); 10 s later row 1 is a fresh registration of
# another machine (uuid bb, hb_seq 1). 25 s after the mount the lock must
# still be refused -- the new holder has been watched 15 s, not 25. And
# once IT has stood still for a full window, it is reclaimed: the
# judgement still works.
#
# DISCRIMINATION: proven 2026-11-05 with the uuid left out of the key:
# the open at 25 s reclaims the new holder's lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 pwinc)"
MNT="$(ct_mnt pwinc)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo content >"$MNT/held"
sync
INO="$(stat -c %i "$MNT/held")"
ct_umount "$MNT"

ct_param_set hb_interval_secs 2
ct_param_set stale_secs 20
# The peer appears after the mount: planted before it, the no-CAW mount
# gate would watch it for the whole window and reclaim from it first.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
"$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null # a peer, registered, never beating again
"$LOCK_POKE" "$DEV" "$INO" 1 1 >/dev/null            # holding the file's lock
T0="$(date +%s)"
tryopen() { python3 -c 'import os,sys
try:
    os.close(os.open(sys.argv[1], os.O_RDWR)); print("open")
except OSError as e:
    print("errno%d" % e.errno)' "$MNT/held"; }
R="$(tryopen)" # also this node's first sample of row 1
[ "$R" != open ] || { fail "setup: the peer's lock did not hold ($R)"; ct_exit; }

sleep $((T0 + 10 - $(date +%s)))
"$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null # another machine registers row 1 afresh
"$LOCK_POKE" "$DEV" "$INO" 1 1 >/dev/null            # and holds the lock
pass "setup: row 1 changed hands at +$(( $(date +%s) - T0 )) s, hb_seq back at 1"
R="$(tryopen)" # a sample right after the change
[ "$R" != open ] || { fail "setup: the lock was reclaimed at +$(( $(date +%s) - T0 )) s, before any window could pass"; ct_exit; }

sleep $((T0 + 25 - $(date +%s)))
R="$(tryopen)"
[ "$R" != open ] && pass "+25 s: the new holder's lock is still refused ($R) -- watched 15 s, not 25" ||
    fail "+25 s: the new holder's lock was reclaimed on its predecessor's sample"

sleep $((T0 + 36 - $(date +%s)))
R="$(tryopen)"
[ "$R" = open ] && pass "+36 s: a full window after the change, the silent new holder is judged dead and reclaimed" ||
    fail "+36 s: the new holder, silent for a full window, is still not reclaimed ($R)"
ct_umount "$MNT"
ct_exit
