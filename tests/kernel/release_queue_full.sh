#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a release queue that overflows stops the mount instead of dropping a claim
#
# A presence bit, file lock or namespace lock this node could not give
# back is queued for the heartbeat (32 each). A full queue used to drop
# the entry with a log line, leaving the claim on the device, owned by a
# live node nobody reclaims from: every peer refused that file
# indefinitely. Now it is the state a crash leaves -- the mount stops,
# the lease lapses, and the peers' stale reclaim clears it all.
#
# Staged on the presence queue: 33 read-only opens whose close fails its
# withdraw, the heartbeat slowed so nothing drains meanwhile.
#
# DISCRIMINATION: with cetrafs_sb_defer_overflow() back to a log line,
# the mount carries on ("stopped: none") with the 33rd bit still set.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/presence_withdraw_fail ] || { skip "presence_withdraw_fail is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 relqfull)"
MNT="$(ct_mnt relqfull)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 30
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
for i in $(seq 1 33); do echo "$i" >"$MNT/f$i"; done
sync

MARK="$(dmesg_mark)"
ct_param_set presence_withdraw_fail 33
python3 - "$MNT" <<'PY'
import os, sys
for i in range(1, 34):
    os.close(os.open("%s/f%d" % (sys.argv[1], i), os.O_RDONLY))
PY
LEFT="$(cat /sys/module/cetrafs/parameters/presence_withdraw_fail)"
ct_param_set presence_withdraw_fail 0
[ "$LEFT" = 0 ] || fail "setup: only $((33 - LEFT)) of 33 withdraws were made to fail"

STOPPED="$(sed -n 's/^stopped: //p' "$INFO")"
log "after 33 failed withdraws with the heartbeat idle: stopped=$STOPPED"
[ "$STOPPED" = error ] && pass "the 33rd unqueueable claim stopped the mount" ||
    fail "the mount carries on (stopped: $STOPPED) holding a claim it can no longer give back"
dmesg_since "$MARK" | grep -q 'presence release for ino=.* could not be queued' &&
    pass "and said why" || fail "the stop did not name the full queue"

ct_umount "$MNT"
ct_exit
