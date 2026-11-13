#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# counts a crash leaves behind their entries are recounted online, not by fsck -r
#
# A namespace operation writes its entry first (journaled, synced) and
# publishes the counts that describe it -- a directory's size and nlink,
# an unlinked file's nlink -- only in the swap that releases each
# namespace lock. A crash between the two leaves the entry on the device,
# the count behind it, and the lock still set: found by the crash census
# (tests/crash/crash_residue.sh) at a third of its cuts. Nothing re-derived
# the counts, so they stayed until an offline fsck -r; on a shared
# datastore that stops every VM. An unlinked file whose nlink still said 1
# held its blocks with no name to reach it.
#
# Whoever takes such a lock over now recounts under it
# (cetrafs_ns_reconcile()): this node re-attached after the crash (the
# mount's own-claim sweep), or a peer breaking a dead holder's lock -- in
# the next operation on it (cetrafs_nslock_try()), or in the scrub for a
# file no name reaches (scrub_reconcile_stopped_op()).
#
# Staged as the census's cuts are, without a crash rig: an operation is
# held between its entry write and its release (nslock_release_stall_ms)
# and the backing file is copied -- the device as a crash there leaves
# it. Three: a mkdir (root's size and nlink behind), a create (the
# directory's size behind), an unlink of a file numbered below its
# directory (the directory releases first, so the copy has the name gone
# and the file's nlink still 1). fsck on each copy must see the lag (the
# setup). Then each copy is mounted twice:
#   - re-attaching as this node: the mount alone must leave fsck clean;
#   - with the stopped locks handed to a dead peer: a create in each
#     directory, or a scrub cycle for the nameless file, breaks them, and
#     fsck must then be clean.
#
# DISCRIMINATION: lock_sweep_recount_off (re-attach) and
# nslock_reconcile_off (peer) leave every lag for fsck to find.
# ct-timeout: 1200
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in nslock_release_stall_ms nslock_reconcile_off lock_sweep_recount_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
# Every copy mounted re-attaches a row that looks crashed, and a mount
# watches such a row for the stale window first: shrunk, as the crash
# suites shrink it.
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
# The copies are of a mounted device: fsck watches their live-looking
# row for two beats, not the whole stale window.
export CETRAFS_PEER_PROBE_SECS=1
LAG='^ERR: ((root )?directory (inode [0-9]+ )?has (size [0-9]+ but holds|nlink=[0-9]+ but contains)|inode [0-9]+ is allocated \(nlink=[0-9]+\) but NO directory entry names it)'

DEV="$(ct_dev 560 nscount)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt nscount)"
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

SNAP_MKDIR="$(ct_tmp)"; SNAP_CREATE="$(ct_tmp)"; SNAP_UNLINK="$(ct_tmp)"
# <snapshot> <copy after seconds> <command...>: hold its releases, copy the device.
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
crash_in_window "$SNAP_MKDIR" 1.5 mkdir "$MNT/sub" ||
    { fail "setup: the mkdir was not held in its window for the whole copy"; ct_exit; }
crash_in_window "$SNAP_CREATE" 1.5 touch "$MNT/d/b" ||
    { fail "setup: the create was not held in its window for the whole copy"; ct_exit; }
# The directory (higher number) releases first, 3 s; the copy lands in the
# victim's stall that follows.
crash_in_window "$SNAP_UNLINK" 4.5 rm "$MNT/d2/v" ||
    { fail "setup: the unlink was not held in its window for the whole copy"; ct_exit; }
ct_umount "$MNT"
for s in "mkdir:$SNAP_MKDIR:directory" "create:$SNAP_CREATE:directory" "unlink:$SNAP_UNLINK:inode $VI is allocated"; do
    IFS=: read -r what img want <<<"$s"
    sdev="$(ct_loop "$img")"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    grep -E "$LAG" <<<"$out" | grep -q "$want" ||
        { fail "setup: the $what copy shows no lag: $(grep -m2 '^ERR' <<<"$out" | tr '\n' ' ')"; ct_exit; }
done
pass "setup: copies taken inside the window show the counts behind (mkdir, create, unlink)"


# <snapshot> <knob> <knob value> <reattach|peer> -> 0 when fsck shows no lag; LAST = its errors
recount_round() {
    local img="$1" knob="$2" val="$3" how="$4" work sdev out ino i
    work="$(ct_tmp)"
    cp --sparse=always "$img" "$work"
    sdev="$(ct_loop "$work")"
    if [ "$how" = peer ]; then
        # The stopped operation's locks go to a dead peer: row 1, stale.
        for ino in 1 "$DI" "$D2I" "$VI"; do
            grep -q "ns_owner=$NID" <<<"$("$LOCK_POKE" "$sdev" "$ino")" && "$LOCK_POKE" "$sdev" "$ino" --ns 1 >/dev/null
        done
        poke_dead_peer "$sdev" 1 bb
    fi
    ct_param_set "$knob" "$val"
    ct_mount "$sdev" "$MNT"
    if [ "$how" = peer ]; then
        wait_out_stale_window
        touch "$MNT/e" "$MNT/d/c" "$MNT/d2/c" || true # creates break the directories' locks
        if [ "$img" = "$SNAP_UNLINK" ]; then # and the scrub the nameless file's
            ct_param_set scrub_interval_secs 2
            ct_param_set scrub 1
            for i in $(seq 1 30); do
                grep -q "ns_owner=$NID\|ns_owner=1 " <<<"$("$LOCK_POKE" "$sdev" "$VI") " || break
                sleep 1
            done
            ct_param_set scrub 0
        fi
    fi
    ct_param_set "$knob" 0
    ct_umount "$MNT"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    rm -f "$work"
    LAST="$(grep -m3 '^ERR' <<<"$out" | tr '\n' ' ')"
    ! grep -qE "$LAG" <<<"$out"
}

for what in mkdir create unlink; do
    case "$what" in
    mkdir) img="$SNAP_MKDIR" ;;
    create) img="$SNAP_CREATE" ;;
    unlink) img="$SNAP_UNLINK" ;;
    esac
    recount_round "$img" lock_sweep_recount_off 1 reattach &&
        fail "$what: control: without the sweep's recount the lag is gone anyway -- the round cannot see the fix" ||
        pass "$what: control: without the sweep's recount the lag survives the mount ($LAST)"
    recount_round "$img" lock_sweep_recount_off 0 reattach &&
        pass "$what: re-attaching after the crash recounts -- no lag left for fsck" ||
        fail "$what: the lag survives a re-attaching mount: $LAST"
    recount_round "$img" nslock_reconcile_off 1 peer &&
        fail "$what: control: without the takeover recount the lag is gone anyway -- the round cannot see the fix" ||
        pass "$what: control: without the takeover recount the lag survives a peer breaking the lock ($LAST)"
    recount_round "$img" nslock_reconcile_off 0 peer &&
        pass "$what: a peer breaking the dead holder's locks recounts -- no lag left for fsck" ||
        fail "$what: the lag survives a peer breaking the dead holder's locks: $LAST"
done
ct_exit
