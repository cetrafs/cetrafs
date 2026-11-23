#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create stopped between its record and its name is reclaimed online
#
# A create writes the new record, then adds its name. A node stopping in
# between left a record with nlink 1 that no name reaches -- for a file
# or an empty directory -- unlocked and unflagged, so nothing online
# ever reclaimed it: only an offline fsck -r (audit 2026-11-15 BM-29).
# The record is now written holding its own namespace lock until the
# name lands; the stop leaves the lock of a stopped holder, and breaking
# it recounts: no name, nlink 0, freed.
#
# Staged as ns_count_reconcile.sh stages its cuts: the create is held
# between its record and its name (create_name_stall_ms) and the backing
# file copied. fsck on the copy must name the orphan (the setup). Each
# copy (a file, a directory) is then mounted:
#   reattach: as this node again -- its re-attach sweep breaks its own
#             stopped lock;
#   peer:     with the lock handed to a dead peer -- the scrub breaks it;
# and with the scrub on, the orphan's number must come free: fsck after
# names nothing about it.
# DISCRIMINATION: born_unlocked=1 when the copy is taken -- the record
# born unlocked, as before: the orphan survives both mounts.
# ct-timeout: 1200
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in create_name_stall_ms born_unlocked; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
ct_param_set born_unlocked 0
export CETRAFS_PEER_PROBE_SECS=1
# An empty file is a WARN to fsck ("a create stopped before adding its
# name"), anything else an ERR; either names the number third.
ORPHAN='^(ERR|WARN): inode [0-9]+ is (allocated \(nlink=[1-9][0-9]*\) but NO directory entry names it|an empty file \(nlink=[1-9][0-9]*\) that no directory entry names)'

DEV="$(ct_dev 560 crstop)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt crstop)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"

# <snapshot> <born_unlocked> <command...>: hold the create, copy the device.
stop_in_window() {
    local snap="$1" unl="$2" op b=0 a=0
    shift 2
    ct_param_set born_unlocked "$unl"
    ct_param_set create_name_stall_ms 3000
    ("$@") &
    op=$!
    sleep 1.5
    kill -0 "$op" 2>/dev/null && b=1
    cp --sparse=always "$BACK" "$snap"
    kill -0 "$op" 2>/dev/null && a=1
    wait "$op" || true
    ct_param_set create_name_stall_ms 0
    ct_param_set born_unlocked 0
    [ "$b$a" = 11 ]
}
declare -A SNAP
n=0
for what in file dir; do
    for unl in 0 1; do
        n=$((n + 1))
        SNAP[$what$unl]="$(ct_tmp)"
        if [ "$what" = file ]; then cmd=(touch "$MNT/f$n"); else cmd=(mkdir "$MNT/d$n"); fi
        stop_in_window "${SNAP[$what$unl]}" "$unl" "${cmd[@]}" ||
            { fail "setup: the $what create was not held for the whole copy"; ct_exit; }
    done
done
ct_umount "$MNT"

# <snapshot> -> ORPH: the orphan's number fsck names on it
orphan_of() {
    local sdev out
    sdev="$(ct_loop "$1")"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    ORPH="$(grep -E "$ORPHAN" <<<"$out" | head -1 | awk '{print $3}' || true)"
    LASTF="$(grep -m2 "^ERR\|^WARN" <<<"$out" | tr "\n" " " || true)"
}
for k in file0 file1 dir0 dir1; do
    orphan_of "${SNAP[$k]}"
    [ -n "$ORPH" ] || { fail "setup: the $k copy shows no unnamed record: $LASTF"; ct_exit; }
done
pass "setup: every copy holds a record no name reaches"

# <snapshot> <reattach|peer> -> 0 when fsck names the orphan no more; LAST
round() {
    local img="$1" how="$2" work sdev out i c0
    orphan_of "$img"
    work="$(ct_tmp)"
    cp --sparse=always "$img" "$work"
    sdev="$(ct_loop "$work")"
    if [ "$how" = peer ]; then
        for i in 1 "$ORPH"; do
            grep -q "ns_owner=$NID" <<<"$("$LOCK_POKE" "$sdev" "$i")" && "$LOCK_POKE" "$sdev" "$i" --ns 1 >/dev/null
        done
        poke_dead_peer "$sdev" 1 bb
    fi
    ct_param_set trim_quarantine_secs 1 # else every claim holds the scrub off for 600 s
    ct_mount "$sdev" "$MNT"
    [ "$how" = peer ] && wait_out_stale_window
    ct_param_set scrub_interval_secs 2
    ct_param_set scrub_gap_floor_secs 1
    ct_param_set scrub_gap_secs 1
    ct_param_set scrub 1
    # Three whole cycles: one breaks the lock (the file's recount frees
    # it as it evicts), the next reclaims a number left dead.
    c0="$(sed -n 's/^scrub_cycles: //p' "$(ct_procdir "$sdev")/info")"
    wait_for 60 "[ \$(sed -n 's/^scrub_cycles: //p' '$(ct_procdir "$sdev")/info') -ge $((c0 + 3)) ]" || true
    ct_param_set scrub 0
    ct_umount "$MNT"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    rm -f "$work"
    LAST="$(grep -m2 '^ERR\|^WARN' <<<"$out" | tr '\n' ' ')"
    ! grep -qE "^(ERR|WARN): inode $ORPH " <<<"$out"
}

for what in file dir; do
    for how in reattach peer; do
        round "${SNAP[${what}1]}" "$how" &&
            fail "$what/$how: control: born unlocked, the orphan went anyway -- the round cannot see the fix" ||
            pass "$what/$how: control: born unlocked, the orphan survives ($LAST)"
        round "${SNAP[${what}0]}" "$how" &&
            pass "$what/$how: born holding its lock, the orphan is reclaimed online" ||
            fail "$what/$how: the orphan survives: $LAST"
    done
done
ct_exit
