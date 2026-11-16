#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount failing before its own-claim sweep does not announce a clean departure
#
# A node back from a crash re-attaches its row and sweeps the claims its
# previous incarnation left (reattach_sweeps_claims.sh). A mount failing
# between the re-attach and that sweep tore down like any other and
# announced a CLEAN departure; the next mount read it, skipped the
# sweeps, and every claim of the crashed incarnation read live for as
# long as the node stayed up (audit 2026-11-15 BM-16).
#
# Staged as reattach_sweeps_claims.sh: a lock of this node's row planted
# on a file and the row made to look crashed. A mount then fails just
# after registering (mount_fail_at=1); then a plain mount:
#   1. the failed mount left the row not departed clean;
#   2. the next mount swept the planted lock.
#
# DISCRIMINATION: mount_unswept_clean=1 -- the failed mount departs
# clean and the lock survives the next mount.
# Each round's re-attach after an unclean departure waits out the stale
# window (120 s) before registering: two rounds, hence the limit.
# ct-timeout: 480
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
DEV="$(ct_dev 560 unswept)"
MNT="$(ct_mnt unswept)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set mount_fail_at 0
ct_param_set mount_unswept_clean 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <tag> <unswept_clean 0|1> -> RES
round() {
    local nid li mark rc=0 dep l
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    nid="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
    echo x >"$MNT/locked"
    li="$(stat -c %i "$MNT/locked")"
    ct_umount "$MNT"
    "$LOCK_POKE" "$DEV" "$li" "$nid" 1 >/dev/null
    "$NODE_POKE" "$DEV" "$nid" --beat >/dev/null
    grep -q "owner=$nid mode=1" <<<"$("$LOCK_POKE" "$DEV" "$li")" ||
        { fail "setup: the planted lock is not on the device"; ct_exit; }
    echo "$2" >/sys/module/cetrafs/parameters/mount_unswept_clean
    echo 1 >/sys/module/cetrafs/parameters/mount_fail_at
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null && rc=1
    echo 0 >/sys/module/cetrafs/parameters/mount_fail_at
    echo 0 >/sys/module/cetrafs/parameters/mount_unswept_clean
    [ "$rc" = 0 ] || { fail "setup: the mount did not fail"; ct_umount "$MNT"; ct_exit; }
    dmesg_since "$mark" | grep -q "failing the mount after stage 1" ||
        { fail "setup: the mount failed, but not at the fail point"; ct_exit; }
    dep="$(field departure "$("$NODE_POKE" "$DEV" "$nid")")"
    ct_mount "$DEV" "$MNT"
    l="$("$LOCK_POKE" "$DEV" "$li")"
    ct_umount "$MNT"
    grep -q "owner=$nid mode=1" <<<"$l" && RES="departure=$dep lock=kept" || RES="departure=$dep lock=swept"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (a failed mount departs clean): $C"
[ "$(field departure "$F")" != 1 ] && pass "1: the failed mount did not announce a clean departure ($F)" || fail "1: $F"
[ "$(field lock "$F")" = swept ] && pass "2: the next mount swept the crashed incarnation's lock ($F)" || fail "2: $F"
[ "$(field departure "$C")" = 1 ] && [ "$(field lock "$C")" = kept ] &&
    pass "control: as before, the failed mount departed clean and the lock survived the next mount ($C)" ||
    fail "control: $C -- the suite does not reach the failed teardown"
ct_exit
