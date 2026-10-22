#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# what the filesystem does when its LUN goes away under a live mount
#
# A shared SAN path drops. Nothing tested this, and pulling the device
# out from under a real mount turned up two faults that are invisible
# any other way:
#
#   - /proc/fs/cetrafs/<dev>/info returned EIO for the WHOLE file, so
#     an operator could not read `fenced:` or `write_ready:` at exactly
#     the moment those answers matter. Both are answerable from memory;
#     the file failed because the live free-space figures it prints
#     first need device reads.
#   - the heartbeat's per-peer sweep retried every one of its 64
#     registry rows twelve times per tick against a dead device, which
#     flooded the log with ~1500 lines in half a minute.
#
# The heartbeat itself behaves correctly throughout -- it fails to renew
# this node's row, so peers see it go stale while this node stays
# mounted holding its claims, which is precisely the state a cluster
# needs to detect. That part is asserted here too, because it is what
# the real two-node fence scenario will be built on.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_failable_dev 560 devfail)"
[ -n "$DEV" ] || { log "device-mapper unavailable -- skipping"; ct_exit; }
MNT="$(ct_mnt devfail)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"

echo hello >"$MNT/f"; sync
grep -q "^fenced: no" "$PROC/info" && pass "a healthy mount reports fenced: no" ||
    fail "baseline info is wrong: $(cat "$PROC/info" 2>&1 | head -3)"

# Beat often enough that several ticks land inside the outage. The wait
# is not optional: changing the parameter does not reschedule the tick
# already queued, so the first 2-second tick is up to one OLD interval
# (15s) away -- without this the outage ends before a single tick runs
# and both heartbeat assertions below pass vacuously.
ct_param_set hb_interval_secs 2
sleep 18

log "the device fails under a live mount"
MARK="$(dmesg_mark)"
ct_dev_fail "$DEV"
sleep 8

# The point of the whole exercise: these two answers need no device I/O,
# so an outage must not be able to hide them.
OUT="$(cat "$PROC/info" 2>&1 || true)"
echo "$OUT" | grep -q "^fenced:" &&
    pass "info still reports 'fenced' while the device is unreachable" ||
    fail "info is unreadable during an outage, which is when it is needed: $(echo "$OUT" | head -2)"
echo "$OUT" | grep -q "^write_ready:" &&
    pass "and 'write_ready'" ||
    fail "write_ready unavailable during an outage: $(echo "$OUT" | head -2)"
echo "$OUT" | grep -qE "free_data_blocks: (unavailable|[0-9])" &&
    pass "and says so for the figures it genuinely cannot read" ||
    fail "free_data_blocks neither a number nor marked unavailable: $(echo "$OUT" | grep free_data || true)"

# The heartbeat must FAIL to renew -- that is what makes a peer see this
# node as stale while it is still mounted and still holding its claims.
# Wait for the signal rather than sleeping a guessed interval: a fixed
# window sometimes ended between ticks, and the assertion then "passed"
# or failed on timing rather than on behaviour.
RENEWED=0
for _ in $(seq 1 20); do
    if dmesg_since "$MARK" | grep -q "failed to renew our own row"; then RENEWED=1; break; fi
    sleep 1
done
[ "$RENEWED" = "1" ] &&
    pass "the heartbeat stops renewing, so peers will see this node stale" ||
    fail "no renew failure logged in 20s -- a dead device went unnoticed"

# ...without drowning the log doing it. One line per failing row per
# tick is ~64x more than anyone needs to learn the device is gone.
NOISE="$(dmesg_since "$MARK" | grep -c "unreadable (forced-fresh)" || true)"
[ "$NOISE" -lt 60 ] && pass "and does not flood the log ($NOISE forced-fresh warnings in 8s)" ||
    fail "log flood: $NOISE 'unreadable' lines in 8s -- a real outage would bury everything else"

log "and the mount recovers when the device comes back"
ct_dev_restore "$DEV"
sleep 4
grep -q "^fenced: no" "$PROC/info" && pass "info reads normally again" ||
    fail "info still broken after recovery: $(cat "$PROC/info" 2>&1 | head -3)"
echo back >"$MNT/g" && sync && pass "writes work again" || fail "write failed after recovery"
[ "$(cat "$MNT/f")" = "hello" ] && pass "and the data written before the outage is intact" ||
    fail "pre-outage data lost"

log "a node that loses its device KEEPS its claims"
# This is the state the two-node fence scenario is built on, so it has
# to be real rather than assumed: a node whose device has gone stops
# beating (peers will call it stale) but is still mounted and still
# holding the on-disk exclusive lock on whatever it had open for write.
# A peer reclaiming that lock is what bumps this node's fence epoch.
LOCKPOKE="$(ct_helper inode_lock_poke)"
: >"$MNT/held"
exec 9>"$MNT/held"          # a live write-open: claims the on-disk lock
sync
HELD_INO="$(stat -c '%i' "$MNT/held")"
blockdev --flushbufs "$DEV"
BEFORE="$("$LOCKPOKE" "$DEV" "$HELD_INO" 2>&1 || true)"
echo "$BEFORE" | grep -qE "lock_mode=[1-9]|owner=0" &&
    pass "the open file's exclusive lock is claimed on disk ($BEFORE)" ||
    fail "no lock claimed before the outage: $BEFORE"

ct_dev_fail "$DEV"
sleep 6
# A write cannot silently succeed while the device is unreachable --
# that would be an acknowledged write that no device ever saw.
( : >"$MNT/during-outage" ) 2>/dev/null && fail "a create succeeded with no reachable device" ||
    pass "a create fails rather than being acknowledged"
ct_dev_restore "$DEV"
sleep 3

blockdev --flushbufs "$DEV"
AFTER="$("$LOCKPOKE" "$DEV" "$HELD_INO" 2>&1 || true)"
[ "$AFTER" = "$BEFORE" ] &&
    pass "and the claim is exactly as it was once the device returns"  ||
    fail "the lock changed across the outage: '$BEFORE' -> '$AFTER'"

exec 9>&-
sync; sleep 1
blockdev --flushbufs "$DEV"
CLEARED="$("$LOCKPOKE" "$DEV" "$HELD_INO" 2>&1 || true)"
# The helper runs under "|| true", so a silent failure leaves CLEARED
# empty -- and an empty value makes the != below true, passing this
# without the lock ever having been checked.
[ -n "$CLEARED" ] || fail "the lock poke produced no output -- nothing was actually checked"
[ "$CLEARED" != "$AFTER" ] &&
    pass "closing the file releases it normally afterwards ($CLEARED)" ||
    fail "the lock was never released after recovery: $CLEARED"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null
pass "fsck clean after an outage and recovery"
ct_exit
