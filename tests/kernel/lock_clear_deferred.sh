#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write lock this node could not give back is retried by the heartbeat, after defrag and for a deleted file too
#
# A close whose lock-clear CAS fails is queued and retried on the
# heartbeat (cetrafs_lock_retry_deferred()). Two ways out of that were
# missing:
#
#   A. Online defrag takes the whole-file lock and gives it back in
#      cetrafs_lock_defrag_end(). A failed clear there was logged and
#      forgotten: the lock stayed on the record of a node that keeps
#      beating -- stale reclaim never comes -- and every peer got
#      -ETXTBSY until this node opened and closed the file again.
#   B. The retry instantiates the inode first. When the file had been
#      deleted meanwhile that fails (-ESTALE), and the entry was simply
#      dropped -- leaving our lock on a dead record, which the orphan
#      scrub skips for as long as a lock is on it.
#
# DISCRIMINATION: A fails without the queueing in defrag_end, B without
# the raw clear in the retry -- in both the lock is still ours after the
# heartbeat has had several ticks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in defrag_clear_fail_once lock_clear_fail_once; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

LPOKE="$(ct_helper inode_lock_poke)"
DEV="$(ct_dev 560 lockdefer)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt lockdefer)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set hb_interval_secs 2

mode_of() { "$LPOKE" "$BACK" "$1" | sed -n 's/.* mode=\([0-9]*\) .*/\1/p'; }
wait_clear() { # <ino>: up to 20 s for the record's lock to be cleared
    local _
    for _ in $(seq 1 20); do
        [ "$(mode_of "$1")" = 0 ] && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------- A
log "A: online defrag whose lock clear fails"
# The BACKGROUND defrag: the manual tool holds a write fd, so its own
# close gives the lock back and defrag_end never clears. The worker
# claims the idle file's lock itself. Fixture as in defrag_auto.sh:
# one block per append with a small file between, run allocation off so
# the file really fragments.
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
for i in $(seq 0 15); do
    dd if=/dev/urandom of="$MNT/frag" bs=4096 seek="$i" count=1 conv=notrunc status=none
    printf x >"$MNT/filler$i"
done
sync
INO="$(stat -c %i "$MNT/frag")"
ct_param_set auto_defrag 1
ct_param_set defrag_clear_fail_once 1
MARK="$(dmesg_mark)"
: >>"$MNT/frag" # a bare write-open + close triggers the worker
for _ in $(seq 1 20); do
    dmesg_since "$MARK" | grep -q "ino=$INO defrag could not give the lock back" && break
    sleep 0.5
done
ct_param_set auto_defrag 0
blockdev --flushbufs "$DEV"
if dmesg_since "$MARK" | grep -q "ino=$INO defrag could not give the lock back"; then
    pass "A: setup: defrag's lock clear failed and was queued"
else
    fail "A: setup: no failed defrag clear -- defrag did not take the lock (knob left $(cat /sys/module/cetrafs/parameters/defrag_clear_fail_once))"
    ct_exit
fi
wait_clear "$INO" && pass "A: the heartbeat gave the lock back" ||
    fail "A: the lock is still on the record after 20 s: $("$LPOKE" "$BACK" "$INO")"

# ---------------------------------------------------------------- B
log "B: a close whose clear fails, of a file then deleted"
MARK="$(dmesg_mark)"
ct_param_set lock_clear_fail_once 1
echo data >"$MNT/gone"
INO="$(stat -c %i "$MNT/gone")"
blockdev --flushbufs "$DEV"
[ "$(mode_of "$INO")" != 0 ] && pass "B: setup: the close left the lock on ino $INO" ||
    { fail "B: setup: the lock was cleared at close -- lock_clear_fail_once was not reached"; ct_exit; }
rm "$MNT/gone"
sync
wait_clear "$INO" && pass "B: the heartbeat cleared the deleted file's lock" ||
    fail "B: the deleted record still carries our lock after 20 s: $("$LPOKE" "$BACK" "$INO")"
dmesg_since "$MARK" | grep -q "ino=$INO is gone; its lock was cleared by the heartbeat" &&
    pass "B: through the raw clear" || fail "B: the lock went, but not through the retry's raw clear"
ct_exit
