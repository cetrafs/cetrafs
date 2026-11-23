#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a recount that fails flags the record, and the next acquirer recounts
#
# Whoever takes over a namespace lock a stopped operation left recounts
# under it (cetrafs_ns_reconcile(), tests/kernel/ns_count_reconcile.sh).
# When that recount failed, the inode was marked damaged until fsck --
# for an out-of-memory, a read error, or a grow not yet caught up, none
# of them damage -- and the lock was released: nothing asked for the
# count again and every node built on it.
#
# Now a failure that a short retry does not absorb sets
# CETRAFS_INODE_COUNT_UNVERIFIED on the record as the lock is released.
# Peers are not blocked; whoever acquires it next recounts first and
# clears the flag; the mount sweep flags what it cannot recount; the
# scrub takes a flagged record no name reaches. Only damage marks the
# inode.
#
# Staged as ns_count_reconcile.sh stages it: operations held between
# their entry write and their release, the device copied. nslock_recount_fail
# makes the next N recounts fail with -ENOMEM.
#
#   flag:     the takeover's recount fails past its retries: the create
#             fails, the lock is free, the record flagged; the next create
#             recounts and clears it; fsck clean.
#   inline:   two failures are absorbed by the retry: the create succeeds.
#   reattach: the mount sweep's recount fails: the mount goes on, the
#             record is flagged and the lock clear; a create recounts.
#   scrub:    an unlinked file whose sweep recount failed is flagged with
#             nlink 1 and no name; the scrub takes it and it is freed.
#
# DISCRIMINATION: nslock_unverified_ignore=1 (acquirers do not honour the
# flag) leaves the lag for fsck in flag and scrub; nslock_recount_fail_release=1
# (the old path) refuses the directory and leaves the lag.
# ct-timeout: 1500
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in nslock_release_stall_ms nslock_recount_fail nslock_recount_fail_release nslock_unverified_ignore; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
export CETRAFS_PEER_PROBE_SECS=1
LAG='^ERR: ((root )?directory (inode [0-9]+ )?has (size [0-9]+ but holds|nlink=[0-9]+ but contains)|inode [0-9]+ is allocated \(nlink=[0-9]+\) but NO directory entry names it)'
UNV=0x10 # CETRAFS_INODE_COUNT_UNVERIFIED

DEV="$(ct_dev 560 nsrfail)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt nsrfail)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
echo victim >"$MNT/v" # numbered before the directory it is unlinked from
mkdir "$MNT/d" "$MNT/d2"
mv "$MNT/v" "$MNT/d2/v"
: >"$MNT/d/a"
sync
DI="$(stat -c %i "$MNT/d")"; D2I="$(stat -c %i "$MNT/d2")"; VI="$(stat -c %i "$MNT/d2/v")"
[ "$VI" -lt "$D2I" ] || { fail "setup: the victim ($VI) is not numbered below its directory ($D2I)"; ct_exit; }

SNAP_CREATE="$(ct_tmp)"; SNAP_UNLINK="$(ct_tmp)"
# <snapshot> <copy after seconds> <command...>
crash_in_window() {
    local snap="$1" at="$2" op b a
    shift 2
    ct_param_set nslock_release_stall_ms 3000
    ("$@") &
    op=$!
    sleep "$at"
    b=0; a=0
    kill -0 "$op" 2>/dev/null && b=1
    cp --sparse=always "$BACK" "$snap"
    kill -0 "$op" 2>/dev/null && a=1
    wait "$op" || true
    ct_param_set nslock_release_stall_ms 0
    [ "$b$a" = 11 ]
}
crash_in_window "$SNAP_CREATE" 1.5 touch "$MNT/d/b" ||
    { fail "setup: the create was not held in its window for the whole copy"; ct_exit; }
crash_in_window "$SNAP_UNLINK" 4.5 rm "$MNT/d2/v" ||
    { fail "setup: the unlink was not held in its window for the whole copy"; ct_exit; }
ct_umount "$MNT"
for s in "create:$SNAP_CREATE:directory" "unlink:$SNAP_UNLINK:inode $VI is allocated"; do
    IFS=: read -r what img want <<<"$s"
    sdev="$(ct_loop "$img")"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    grep -E "$LAG" <<<"$out" | grep -q "$want" ||
        { fail "setup: the $what copy shows no lag: $(grep -m2 '^ERR' <<<"$out" | tr '\n' ' ')"; ct_exit; }
done
pass "setup: copies taken inside the window show the counts behind (create, unlink)"

owner() { "$LOCK_POKE" "$1" "$2" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p'; }
recflags() { "$LOCK_POKE" "$1" "$2" --rec | sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p'; }
flagged() { local f; f="$(recflags "$1" "$2")"; [ -n "$f" ] && [ $((f & UNV)) != 0 ]; }

SDEV=""
# <snapshot> <reattach|peer>: a working copy mounted, the stopped locks
# this node's (reattach) or a dead peer's (peer).
start() {
    local work ino
    work="$(ct_tmp)"
    cp --sparse=always "$1" "$work"
    SDEV="$(ct_loop "$work")"
    if [ "$2" = peer ]; then
        for ino in 1 "$DI" "$D2I" "$VI"; do
            [ "$(owner "$SDEV" "$ino")" = "$NID" ] && "$LOCK_POKE" "$SDEV" "$ino" --ns 1 >/dev/null
        done
        poke_dead_peer "$SDEV" 1 bb
    fi
    ct_mount "$SDEV" "$MNT"
    [ "$2" = peer ] && wait_out_stale_window
    true
}
# -> fsck output in FOUT
finish() {
    ct_param_set nslock_recount_fail 0
    ct_param_set nslock_recount_fail_release 0
    ct_param_set nslock_unverified_ignore 0
    ct_param_set scrub 0
    ct_umount "$MNT"
    FOUT="$(ct_fsck "$SDEV" 2>&1 || true)"
    losetup -d "$SDEV" 2>/dev/null || true
}
clean() { ! grep -qE "$LAG" <<<"$FOUT" && ! grep -q "counts unverified" <<<"$FOUT"; }

# --- flag, and its control: the takeover's recount fails past its retries
for ign in 0 1; do
    tag=flag; [ "$ign" = 1 ] && tag="flag control"
    start "$SNAP_CREATE" peer
    ct_param_set nslock_recount_fail 10
    rc=0; err="$(touch "$MNT/d/c" 2>&1)" || rc=$?
    ct_param_set nslock_recount_fail 0
    if [ "$rc" = 0 ]; then
        fail "$tag: setup: the create succeeded -- the recount did not fail"
    else
        [ "$(owner "$SDEV" "$DI")" != "$NID" ] && flagged "$SDEV" "$DI" &&
            pass "$tag: the failed recount left the lock free and the record flagged ($err)" ||
            fail "$tag: owner $(owner "$SDEV" "$DI"), record: $("$LOCK_POKE" "$SDEV" "$DI" --rec)"
        ct_param_set nslock_unverified_ignore "$ign"
        touch "$MNT/d/c" && pass "$tag: the next create succeeds (not refused as damaged)" ||
            fail "$tag: the next create failed"
        if [ "$ign" = 0 ]; then
            ! flagged "$SDEV" "$DI" && pass "$tag: it recounted and cleared the flag" ||
                fail "$tag: still flagged after a create"
        fi
    fi
    finish
    if [ "$ign" = 0 ]; then
        clean && pass "$tag: fsck clean" || fail "$tag: fsck: $(grep -m3 -E '^ERR|unverified' <<<"$FOUT" | tr '\n' ' ')"
    else
        grep -qE "$LAG" <<<"$FOUT" && pass "$tag: an acquirer ignoring the flag leaves the lag for fsck" ||
            fail "$tag: no lag without the flag honoured -- the round cannot see the fix"
    fi
done

# --- inline: two failures absorbed by the retry
start "$SNAP_CREATE" peer
ct_param_set nslock_recount_fail 2
touch "$MNT/d/c" && ! flagged "$SDEV" "$DI" && pass "inline: two failed attempts absorbed, the create succeeded" ||
    fail "inline: the retry did not absorb two failures"
finish
clean && pass "inline: fsck clean" || fail "inline: fsck: $(grep -m3 -E '^ERR|unverified' <<<"$FOUT" | tr '\n' ' ')"

# --- release control: the old path
start "$SNAP_CREATE" peer
ct_param_set nslock_recount_fail_release 1
ct_param_set nslock_recount_fail 10
touch "$MNT/d/c" 2>/dev/null || true
ct_param_set nslock_recount_fail 0
err="$(touch "$MNT/d/c" 2>&1)" || true
grep -q "Structure needs cleaning" <<<"$err" && pass "release control: the old path refuses the directory as damaged" ||
    fail "release control: second create: $err"
finish
grep -qE "$LAG" <<<"$FOUT" && pass "release control: and fsck still finds the count behind" ||
    fail "release control: fsck finds no lag"

# --- reattach: the mount sweep's recount fails
ct_param_set nslock_recount_fail 10
start "$SNAP_CREATE" reattach
ct_param_set nslock_recount_fail 0
[ "$(owner "$SDEV" "$DI")" != "$NID" ] && flagged "$SDEV" "$DI" &&
    pass "reattach: the mount went on; the lock is clear and the record flagged" ||
    fail "reattach: owner $(owner "$SDEV" "$DI"), record: $("$LOCK_POKE" "$SDEV" "$DI" --rec)"
touch "$MNT/d/c" && ! flagged "$SDEV" "$DI" && pass "reattach: a create recounted it and cleared the flag" ||
    fail "reattach: after a create: $("$LOCK_POKE" "$SDEV" "$DI" --rec)"
finish
clean && pass "reattach: fsck clean" || fail "reattach: fsck: $(grep -m3 -E '^ERR|unverified' <<<"$FOUT" | tr '\n' ' ')"

# --- scrub, and its control: an unlinked file no name reaches
for ign in 0 1; do
    tag=scrub; [ "$ign" = 1 ] && tag="scrub control"
    ct_param_set nslock_recount_fail 10
    ct_param_set trim_quarantine_secs 1 # else every claim holds the scrub off for 600 s
    ct_param_set scrub_interval_secs 2 # before the mount: it schedules the first cycle
    start "$SNAP_UNLINK" reattach
    ct_param_set nslock_recount_fail 0
    flagged "$SDEV" "$VI" || { fail "$tag: setup: the nameless file is not flagged after the failed sweep"; finish; continue; }
    ct_param_set nslock_unverified_ignore "$ign"
    ct_param_set scrub 1
    for i in $(seq 1 40); do
        f="$(recflags "$SDEV" "$VI" 2>/dev/null || true)"
        [ -n "$f" ] && [ $((f & UNV)) = 0 ] && break
        sleep 1
    done
    log "$tag: waited ${i}s, flags now '$f'"
    sleep 3 # the eviction after the recount
    finish
    if [ "$ign" = 0 ]; then
        clean && pass "$tag: the scrub recounted the flagged records and the nameless file was freed" ||
            fail "$tag: fsck: $(grep -m3 -E '^ERR|unverified' <<<"$FOUT" | tr '\n' ' ')"
    else
        grep -q "inode $VI is allocated" <<<"$FOUT" && pass "$tag: without the flag honoured the file keeps its blocks" ||
            fail "$tag: the file was freed anyway -- the round cannot see the fix"
    fi
done
ct_exit
