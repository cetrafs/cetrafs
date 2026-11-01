#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a last close whose lock clear failed is finished by the heartbeat, not left for a remount
#
# The last writer's close publishes the record and then clears the
# file lock. If either step fails, the lock is kept on purpose: handing
# the file over without this writer's state would be worse. But a lock
# kept by a node that keeps heartbeating is never reclaimed, so every
# other node got -ETXTBSY on that file until something on THIS node
# opened and closed it again -- for a VM image, until the VM moved or
# the node remounted. The close is now queued and the heartbeat
# finishes it.
#
# lock_clear_fail_once makes one close's clear CAS fail.
#
# DISCRIMINATION (measured on the unfixed code): the lock is still held
# 20 s after the close, with no opener anywhere. And with the retry's
# "no local writer" check removed, it clears the lock under a live
# local writer.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 lkretry)"
MNT="$(ct_mnt lkretry)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo data >"$MNT/vm.img"
INO="$(stat -c %i "$MNT/vm.img")"
dump() { "$LOCK_POKE" "$DEV" "$INO"; }
dump | grep -q 'mode=0 ' && pass "setup: the file starts unlocked ($(dump))" || { fail "setup: $(dump)"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set lock_clear_fail_once 1
echo more >>"$MNT/vm.img"
[ "$(cat /sys/module/cetrafs/parameters/lock_clear_fail_once)" = N ] &&
    pass "setup: the close's lock clear was failed" || { fail "setup: the knob was not consumed"; ct_exit; }
dump | grep -q 'mode=1 ' && pass "the failed clear left the lock held ($(dump))" ||
    { fail "setup: the lock is not held after the failed clear: $(dump)"; ct_exit; }

# Nothing on this node touches the file again. Several heartbeat ticks.
if wait_for 20 'dump | grep -q "mode=0 "'; then
    pass "the heartbeat finished the close: the lock is free ($(dump))"
else
    fail "the lock is still held 20 s after the close with no opener anywhere: $(dump)"
fi
dmesg_since "$MARK" | grep -q 'finished by the heartbeat' && pass "the retry is logged" || fail "no retry logged"
[ "$(cat "$MNT/vm.img")" = "$(printf 'data\nmore')" ] && pass "the data is intact" || fail "content: $(cat "$MNT/vm.img")"


log "a local writer reopens before the heartbeat: the retry must leave its lock alone"
# Maintenance sleeps before it acts, so the reopen below certainly lands
# between the failed close and the retry that follows it.
ct_param_set hb_maint_delay_ms 1500
ct_param_set lock_clear_fail_once 1
echo again >>"$MNT/vm.img"
dump | grep -q 'mode=1 ' || { fail "setup: the second failed clear did not leave the lock held: $(dump)"; ct_exit; }
exec 8>>"$MNT/vm.img" # the new local writer, opened at once
sleep 6               # several retry passes with the entry queued
dump | grep -q 'mode=1 ' && pass "a live local writer kept its lock across the retry ($(dump))" ||
    fail "the retry cleared the lock under a live local writer: $(dump)"
echo held >&8
exec 8>&-
ct_param_set hb_maint_delay_ms 0
dump | grep -q 'mode=0 ' && pass "the writer's own close released it ($(dump))" ||
    fail "after the writer's close the lock is $(dump)"

ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
