#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace release that loses its staged directory update stops the mount, and the next holder restamps dirent_seq
#
# A create writes its entry to the directory's block, then stages the
# directory's record update -- dirent_seq, size, nlink -- for the
# namespace lock's release to publish in the swap that clears the lock.
# When that swap did not commit after its retries, the release queued a
# deferred retry that only clears the lock, and the staged update was
# simply dropped: the entry on the device, the record describing it not.
# dirent_seq is the stamp every peer's directory cache is gated on, so
# peers whose cached stamp still matched went on serving the old
# directory -- and nothing ever corrected it until somebody's next change
# to it, because breaking a dead holder's lock did not advance the stamp
# either.
#
# Now: (1) a lost staged update is kind 3 -- the mount stops, as for the
# out-of-memory and no-node-id cases in the same function; (2) whoever
# takes a directory's lock from a previous holder (a dead peer, or our
# own leftover after a remount) stamps a fresh dirent_seq, so every
# cache misses once.
#
# DISCRIMINATION: without (1) the mount keeps running; without (2) the
# directory's dirent_seq after the remount still equals the stale one.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/nslock_release_fail ] || { skip "nslock_release_fail is missing"; ct_exit; }

LPOKE="$(ct_helper inode_lock_poke)"
DEV="$(ct_dev 560 nsstaged)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt nsstaged)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { sed -n "s/^$1: //p" "$PROC/info"; }

mkdir "$MNT/d"
DINO="$(stat -c '%i' "$MNT/d")"
sync
seq_of() { blockdev --flushbufs "$DEV"; "$LPOKE" "$BACK" "$DINO" --rec | sed -n 's/.*dirent_seq=\([0-9]*\).*/\1/p'; }
owner_of() { "$LPOKE" "$BACK" "$DINO" | sed -n 's/.* ns_owner=\([0-9]*\) .*/\1/p'; }
S0="$(seq_of)"
[ -n "$S0" ] || { fail "setup: could not read d's dirent_seq"; ct_exit; }

log "1: a create whose release cannot publish the directory's update"
MARK="$(dmesg_mark)"
ct_param_set nslock_release_fail 1
: >"$MNT/d/f" 2>/dev/null || true
ct_param_set nslock_release_fail 0
[ "$(seq_of)" = "$S0" ] && [ "$(owner_of)" != 65535 ] &&
    pass "setup: the entry is written, d's dirent_seq is still $S0 and its lock is left on the record" ||
    { fail "setup: dirent_seq $(seq_of) (was $S0), owner $(owner_of) -- the publish was not lost"; ct_exit; }
[ "$(info stopped)" = error ] && pass "1: the mount stopped (stopped: error)" ||
    fail "1: stopped: $(info stopped) -- the mount kept going with d's record out of date"
dmesg_since "$MARK" | grep -q "STOPPED (error): nslock: ino=$DINO release: the swap that publishes" &&
    pass "1: and says why" || fail "1: no STOPPED line naming the lost publish"
ct_umount "$MNT" || umount -l "$MNT"

log "2: the next holder of d's lock restamps dirent_seq"
ct_mount "$DEV" "$MNT"
chmod 750 "$MNT/d" # takes d's lock (our own leftover) and stages nothing
S1="$(seq_of)"
[ "$S1" != "$S0" ] && pass "2: d's dirent_seq moved off the stale value ($S0 -> $S1)" ||
    fail "2: d's dirent_seq is still $S0 -- a peer that cached it keeps the old directory"
[ "$(owner_of)" = 65535 ] && pass "2: and its lock is free again" || fail "2: d's lock reads owner $(owner_of)"
ls "$MNT/d" | grep -qx f && pass "2: the entry written before the stop is there" || fail "2: f is missing"
ct_umount "$MNT"
"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true # d's size was part of the lost update
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck after -r: $(grep '^ERR' <<<"$OUT" | head -2)" || pass "fsck -r repairs what the stop left"
ct_exit
