#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a takeover recount that fails keeps the lock until a recount succeeds
#
# Whoever takes over a namespace lock a stopped operation left recounts
# under it (cetrafs_ns_reconcile(), tests/kernel/ns_count_reconcile.sh).
# When that recount failed, the inode was marked damaged on this node
# until fsck -- for an out-of-memory, a read error, or a peer's grow not
# yet caught up, none of them damage -- and the lock was RELEASED: nothing
# asked for the count again, and every other node built on it.
#
# Now the lock stays set under this node's id, the operation fails with
# the recount's error, and the heartbeat recounts before it clears
# (cetrafs_nslock_retry_deferred()). Staged as ns_count_reconcile.sh
# stages a create stopped between its entry write and its release, the
# lock handed to a dead peer; nslock_recount_fail makes the first three
# recounts fail, the takeover's and two retries'.
#
# DISCRIMINATION: nslock_recount_fail_release=1 takes the old path: the
# lock is released, the directory refused (EUCLEAN), and fsck still
# finds the count behind.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in nslock_release_stall_ms nslock_recount_fail nslock_recount_fail_release; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
export CETRAFS_PEER_PROBE_SECS=1
LAG='^ERR: ((root )?directory (inode [0-9]+ )?has (size [0-9]+ but holds|nlink=[0-9]+ but contains))'

DEV="$(ct_dev 560 nsrfail)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt nsrfail)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
mkdir "$MNT/d"
: >"$MNT/d/a"
sync
DI="$(stat -c %i "$MNT/d")"

# A create held between its entry write and its release; the copy is
# the device as a crash there leaves it.
SNAP="$(ct_tmp)"
ct_param_set nslock_release_stall_ms 3000
touch "$MNT/d/b" &
op=$!
sleep 1.5
b=0; a=0
kill -0 "$op" 2>/dev/null && b=1
cp --sparse=always "$BACK" "$SNAP"
kill -0 "$op" 2>/dev/null && a=1
wait "$op" || true
ct_param_set nslock_release_stall_ms 0
ct_umount "$MNT"
[ "$b$a" = 11 ] || { fail "setup: the create was not held in its window for the whole copy"; ct_exit; }
sdev="$(ct_loop "$SNAP")"
out="$(ct_fsck "$sdev" 2>&1 || true)"
losetup -d "$sdev" 2>/dev/null || true
grep -qE "$LAG" <<<"$out" || { fail "setup: the copy shows no lag: $(grep -m2 '^ERR' <<<"$out" | tr '\n' ' ')"; ct_exit; }
pass "setup: the copy has the directory's count behind and its lock set"

ns_owner() { "$LOCK_POKE" "$1" "$DI" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p'; }

# <tag> <fail count> <fail_release>
round() {
    local tag="$1" fails="$2" rel="$3" work sdev rc=0 err owner i mark
    work="$(ct_tmp)"
    cp --sparse=always "$SNAP" "$work"
    sdev="$(ct_loop "$work")"
    [ "$(ns_owner "$sdev")" = "$NID" ] || { fail "$tag: setup: d's lock is not this node's in the copy"; return 0; }
    "$LOCK_POKE" "$sdev" "$DI" --ns 1 >/dev/null
    poke_dead_peer "$sdev" 1 bb
    ct_mount "$sdev" "$MNT"
    wait_out_stale_window
    mark="$(dmesg_mark)"
    ct_param_set nslock_recount_fail_release "$rel"
    ct_param_set nslock_recount_fail "$fails"
    err="$(touch "$MNT/d/c" 2>&1)" || rc=$?
    owner="$(ns_owner "$sdev")"
    if [ "$rc" = 0 ]; then
        fail "$tag: setup: the create succeeded -- the takeover recount did not fail"
        ct_param_set nslock_recount_fail 0; ct_param_set nslock_recount_fail_release 0
        ct_umount "$MNT"; losetup -d "$sdev" 2>/dev/null || true; return 0
    fi
    if [ "$rel" = 1 ]; then
        [ "$owner" != "$NID" ] && pass "$tag: the old path released the lock (owner now $owner)" ||
            fail "$tag: the old path kept the lock -- the knob does not reproduce it"
        err="$(touch "$MNT/d/c" 2>&1)" && rc=0 || rc=$?
        grep -q "Structure needs cleaning" <<<"$err" &&
            pass "$tag: the directory is refused as damaged for a failure that was not damage" ||
            fail "$tag: second create rc=$rc: $err"
    else
        [ "$owner" = "$NID" ] && pass "$tag: the failed recount kept the lock under this node's id ($err)" ||
            fail "$tag: the lock was not kept (owner $owner): $err"
        for i in $(seq 1 30); do
            [ "$(ns_owner "$sdev")" = "$NID" ] || break
            sleep 1
        done
        dmesg_since "$mark" | grep -q "ino=$DI recount still failing" &&
            dmesg_since "$mark" | grep -q "ino=$DI recounted on retry" &&
            [ "$(ns_owner "$sdev")" != "$NID" ] &&
            pass "$tag: the heartbeat retried the recount past its failures, then cleared the lock" ||
            fail "$tag: retry: owner $(ns_owner "$sdev"); log: $(dmesg_since "$mark" | grep "ino=$DI" | tr '\n' ' ')"
        touch "$MNT/d/c" 2>&1 && pass "$tag: the directory takes a create again (not refused as damaged)" ||
            fail "$tag: the directory is still refused"
    fi
    ct_param_set nslock_recount_fail 0
    ct_param_set nslock_recount_fail_release 0
    ct_umount "$MNT"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    if [ "$rel" = 1 ]; then
        grep -qE "$LAG" <<<"$out" && pass "$tag: fsck still finds the count behind" ||
            fail "$tag: fsck finds no lag -- the round cannot see the fix"
    else
        ! grep -qE "$LAG" <<<"$out" && pass "$tag: fsck finds the count recounted" ||
            fail "$tag: fsck: $(grep -m3 '^ERR' <<<"$out" | tr '\n' ' ')"
    fi
}

round control 1 1
round main 3 0
ct_exit
