#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an unmount with claim releases still queued does not announce a clean departure
#
# A release that failed (a presence withdraw here) waits in a queue for
# the heartbeat. Unmount stopped the heartbeat and then marked the row
# departed (last_seen 0) regardless. The next mount of this node reads
# such a row as a clean departure and skips the sweep of its previous
# life's claims, so the bit read as LIVE again the moment the row beat,
# and nothing ever cleared it: every peer write-open, unlink and truncate
# of that file got ETXTBSY.
#
# Staged: a read close whose withdraw fails, an unmount before any
# heartbeat could retry it (the bit is still set after it -- otherwise
# the case was not reached), then a remount. The row must not read
# departed, and the remount must clear the bit.
#
# DISCRIMINATION: without the check the row reads last_seen=0 and the
# bit survives the remount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/presence_withdraw_fail ] || { skip "presence_withdraw_fail is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 umqueued)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt umqueued)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 5
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
echo a >"$MNT/a"; sync
INO="$(stat -c %i "$MNT/a")"

MARK="$(dmesg_mark)"
python3 - "$MNT/a" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
open("/sys/module/cetrafs/parameters/presence_withdraw_fail", "w").write("1")
os.close(fd)
PY
ct_umount "$MNT"
D="$("$LOCK_POKE" "$IMG" "$INO")"
grep -q 'readers=0x0$' <<<"$D" &&
    { fail "setup: the bit was already withdrawn before the unmount ($D) -- a heartbeat retried first"; ct_exit; }
pass "setup: the unmount ran with the withdraw still queued ($D)"

ROW="$("$NODE_POKE" "$IMG" "$NID")"
log "row after the unmount: $ROW"
grep -q ' last_seen=0 ' <<<"$ROW" &&
    fail "the unmount announced a clean departure over a queued release ($ROW)" ||
    pass "the row was left to go stale, not marked departed"

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
D=""
for _ in $(seq 1 20); do
    D="$("$LOCK_POKE" "$IMG" "$INO")"
    grep -q 'readers=0x0$' <<<"$D" && break
    sleep 1
done
grep -q 'readers=0x0$' <<<"$D" && pass "the remount cleared the previous life's presence bit" ||
    fail "the presence bit of the previous mount is still set after the remount ($D)"
ct_umount "$MNT"
ct_exit
