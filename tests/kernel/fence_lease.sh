#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the fence lease: noticing a peer revoked it, and refusing to renew past it
#
# A node's lease is its Node Registry row's fence_epoch. Any node that
# reclaims a stale peer's ZG, file lock, namespace lock or journal area
# bumps that peer's epoch; the peer notices on its next tick and fences
# itself rather than carrying on writing into state it no longer owns.
#
# The second half exists because the first could not fail: the heartbeat
# pre-check caught every revocation before the renew's own blind write --
# the code that actually held the bug -- was ever reached. Seven green
# assertions, zero coverage. fence_skip_precheck takes the pre-check out
# of the way so the renew is the SOLE path to the observable.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

# BEFORE the mount, not after: cetrafs_heartbeat_start() queues the first
# tick with whatever the interval is at mount time, so compressing later
# would still leave the first tick up to the production 15s away -- and
# the short sleeps below would race it.
compress_timing

# A volume with one file, 'victim', whose inode number the pokes below
# address. Every suite that touches the on-disk lock fields starts from
# exactly this state, freshly built -- nothing here inherits anything
# from another suite.
LOCK_IMG="$(ct_image 560 lock)"
LOCK_LOOPDEV="$(ct_loop "$LOCK_IMG")"
LOCK_MNT="$(ct_mnt lock-mnt)"
ct_mkfs_small "$LOCK_LOOPDEV" >/dev/null
ct_track mnt "$LOCK_MNT"
ct_mount "$LOCK_LOOPDEV" "$LOCK_MNT"
require_cetrafs_mount "$LOCK_MNT"
echo "victim content" >"$LOCK_MNT/victim"
VICTIM_INO="$(stat -c '%i' "$LOCK_MNT/victim")"

# Every wait below is for a heartbeat tick to notice something, so run
# on the compressed tick rather than the production 15s one.

log "checking the fence lease"
# A node's lease lives in its Node Registry row: any node that reclaims a
# stale peer's ZG, file lock, namespace lock or journal area bumps that
# peer's fence_epoch, and the peer notices on its next heartbeat tick and
# fences itself rather than carrying on writing into state it no longer
# owns.
#
# Simulated by poking our OWN row's epoch forward behind the live
# mount's back -- exactly what a peer's reclaim does.
FENCE_BEFORE="$("$NODE_POKE" "$LOCK_LOOPDEV" 0)"
case "$FENCE_BEFORE" in
    *"fence_epoch=0 "*|*fence_epoch=0) pass "fence: a freshly registered row starts at epoch 0" ;;
    *) fail "fence: expected fence_epoch=0 on a fresh row, got '$FENCE_BEFORE'" ;;
esac

# Nothing has reclaimed anything, so several ticks must NOT fence us --
# a lease that fires spuriously is worse than none.
touch "$LOCK_MNT/fence-probe-1" 2>/dev/null &&
    pass "fence: writes work normally before any revocation" ||
    fail "fence: could not write before any revocation"

DMESG_MARK_FENCE="$(dmesg_mark)"
"$NODE_POKE" "$LOCK_LOOPDEV" 0 --bump-fence 1 >/dev/null
# Wait for a heartbeat tick to observe it.
FENCE_SEEN=no
for _ in $(seq 1 30); do
    sleep "$TEST_HB_SECS"
    if dmesg_since "$DMESG_MARK_FENCE" | grep -q "lease was revoked"; then
        FENCE_SEEN=yes
        break
    fi
done
[ "$FENCE_SEEN" = yes ] &&
    pass "fence: a revoked lease is noticed by the heartbeat tick" ||
    fail "fence: epoch moved but the node never fenced itself"

# Fencing is a one-way latch for the life of the mount: every mutating
# path must refuse, so the node cannot keep writing into state a peer
# has already taken.
if touch "$LOCK_MNT/fence-probe-2" 2>/dev/null; then
    fail "fence: still able to create after being fenced"
else
    pass "fence: mutations are refused once fenced"
fi
# Reads keep working by design -- fencing stops writes, not access.
[ -e "$LOCK_MNT/fence-probe-1" ] &&
    pass "fence: reads still work while fenced" ||
    fail "fence: reads broke while fenced"

grep -q "fenced: yes" "/proc/fs/cetrafs/$(basename "$LOCK_LOOPDEV")/info" &&
    pass "fence: procfs reports the fenced state" ||
    fail "fence: procfs does not report the fenced state"

# Recovery is unmount + remount: the fresh join baselines the lease at
# whatever the row says now, so a past revocation must not fence us again.
umount "$LOCK_MNT"
mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
touch "$LOCK_MNT/fence-probe-3" 2>/dev/null &&
    pass "fence: a remount rejoins cleanly and is not re-fenced" ||
    fail "fence: still fenced after a remount (the lease baseline is wrong)"
rm -f "$LOCK_MNT/fence-probe-1" "$LOCK_MNT/fence-probe-3"

# ---------------------------------------------------------------------
# The above proves the lease is noticed. It does NOT prove the RENEW is
# what notices it: the pre-check runs first and jumps straight to the
# reschedule, so a poke landing between ticks is always caught there.
# That is why this section passed just as happily against the renew's
# old read / modify / blind-write form, which never compared the epoch
# at all and relied entirely on the pre-check -- while a peer revoking
# in the gap between the two had its bump reverted and the node never
# fenced again.
#
# The gap itself is microseconds wide and cannot be hit from userspace,
# so take the pre-check out of the way and make the renew the sole
# detector. Reverting cetrafs_node_renew_heartbeat() to a blind write
# makes the two assertions below fail (verified).
#
# Note what this does and does not cover. Measured against the reverted
# build, the two assertions with teeth here are "the renew detects it"
# and "a refused renew writes nothing" -- those are what the blind write
# fails. The epoch-survives assertion passes either way on this harness,
# because a poke that lands between ticks is simply re-read by the blind
# write; it only discriminates in the real read-to-write window, which
# is microseconds wide and needs CAW hardware to exercise. It is kept as
# the direct statement of the invariant.
log "checking that the heartbeat RENEW itself refuses a revoked lease"
SKIP_PRECHECK=/sys/module/cetrafs/parameters/fence_skip_precheck
if [ ! -w "$SKIP_PRECHECK" ]; then
    fail "fence-renew: $SKIP_PRECHECK is missing (the test hook is not built in)"
else
    echo Y > "$SKIP_PRECHECK"

    # Let a tick land with the pre-check off and nothing revoked: the
    # renew must still renew normally, or the rest proves nothing.
    HB_A="$("$NODE_POKE" "$LOCK_LOOPDEV" 0)"
    sleep $((TEST_HB_SECS * 4))
    HB_B="$("$NODE_POKE" "$LOCK_LOOPDEV" 0)"
    SEQ_A="${HB_A#*hb_seq=}"; SEQ_A="${SEQ_A%% *}"
    SEQ_B="${HB_B#*hb_seq=}"; SEQ_B="${SEQ_B%% *}"
    [ "$SEQ_B" -gt "$SEQ_A" ] &&
        pass "fence-renew: the renew still renews when the lease is intact" ||
        fail "fence-renew: hb_seq did not advance with the pre-check off ($SEQ_A -> $SEQ_B)"

    DMESG_MARK_RENEW="$(dmesg_mark)"
    EPOCH_B="${HB_B#*fence_epoch=}"; EPOCH_B="${EPOCH_B%% *}"
    "$NODE_POKE" "$LOCK_LOOPDEV" 0 --bump-fence 1 >/dev/null
    EPOCH_WANT=$((EPOCH_B + 1))

    RENEW_SEEN=no
    for _ in $(seq 1 30); do
        sleep "$TEST_HB_SECS"
        if dmesg_since "$DMESG_MARK_RENEW" | grep -q "found while renewing it"; then
            RENEW_SEEN=yes
            break
        fi
    done
    [ "$RENEW_SEEN" = yes ] &&
        pass "fence-renew: the renew itself detects the revoked lease" ||
        fail "fence-renew: the renew never noticed the epoch move (it is not comparing it)"

    # A renew that refused must have written NOTHING: a row whose hb_seq
    # advanced is a row this node re-asserted liveness on after losing
    # its lease, and its epoch would be whatever that write carried.
    HB_C="$("$NODE_POKE" "$LOCK_LOOPDEV" 0)"
    SEQ_C="${HB_C#*hb_seq=}"; SEQ_C="${SEQ_C%% *}"
    EPOCH_C="${HB_C#*fence_epoch=}"; EPOCH_C="${EPOCH_C%% *}"
    [ "$SEQ_C" = "$SEQ_B" ] &&
        pass "fence-renew: a refused renew writes nothing (hb_seq frozen at $SEQ_C)" ||
        fail "fence-renew: hb_seq advanced past the revocation ($SEQ_B -> $SEQ_C)"
    [ "$EPOCH_C" = "$EPOCH_WANT" ] &&
        pass "fence-renew: the peer's epoch bump survives the renew" ||
        fail "fence-renew: epoch is $EPOCH_C, expected $EPOCH_WANT (the renew reverted it)"

    echo N > "$SKIP_PRECHECK"
    umount "$LOCK_MNT"
    mount -t cetrafs "$LOCK_LOOPDEV" "$LOCK_MNT"
    touch "$LOCK_MNT/fence-probe-4" 2>/dev/null &&
        pass "fence-renew: a remount rejoins cleanly afterwards" ||
        fail "fence-renew: still fenced after a remount"
    rm -f "$LOCK_MNT/fence-probe-4"
fi


ct_exit
