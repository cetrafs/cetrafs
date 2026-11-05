#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a suspended-writer mark whose clear failed is retried
#
# A writer that hands its lock over (flock LOCK_UN on a default mount)
# marks itself in suspended_writer_nodes; resuming (LOCK_EX), or closing
# while suspended, clears the mark. The presence withdraw clears it too,
# but only with the presence bit -- and a local reader keeps the bit. A
# clear that failed was dropped with (void): the mark outlived the
# writer, and the access rule then read this node's live reader as a
# writer handing over -- a peer's write-open passed it, a peer's
# read-open was refused (audit R20).
#
# Now the failed clear is queued for the heartbeat's presence retry.
#
# DISCRIMINATION: with the clear dropped, the mark is still set when the
# wait ends.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { skip "flock(1) not installed"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/suspend_unmark_fail_once ] || { skip "suspend_unmark_fail_once is missing"; ct_exit; }
LPOKE="$(ct_helper inode_lock_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 smark)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt smark)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/f" bs=4096 count=2 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
sw() { "$LPOKE" "$IMG" --sw "$INO"; }

exec 8<"$MNT/f"            # a local reader: keeps the presence bit
exec 9>>"$MNT/f"           # the writer
flock -u 9 || { fail "setup: flock(LOCK_UN) failed"; ct_exit; }
grep -q "suspended=0x0 " <<<"$(sw)" && { fail "setup: the suspend set no mark ($(sw))"; ct_exit; }
pass "setup: suspended ($(sw))"

ct_param_set suspend_unmark_fail_once 1
flock -x 9 || fail "resume: flock(LOCK_EX) failed"
log "right after the resume: $(sw)"
grep -q "suspended=0x0 " <<<"$(sw)" && { fail "setup: the clear did not fail -- nothing to retry"; ct_exit; }
pass "setup: the resume's clear failed, the mark is still set"

OK=0
for _ in $(seq 1 15); do
    grep -q "suspended=0x0 " <<<"$(sw)" && { OK=1; break; }
    sleep 1
done
[ "$OK" = 1 ] && pass "the heartbeat cleared the stale mark ($(sw))" ||
    fail "the mark outlived the writer: $(sw) 15 s after the resume"
grep -qv "readers=0x0$" <<<"$(sw)" && pass "and the local reader's presence stayed" ||
    fail "the retry took the local reader's presence too: $(sw)"

exec 9>&- 8<&-
ct_umount "$MNT"
ct_exit
