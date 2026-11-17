#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a flush never waits for a buffer lock while it holds another: sync and a journaled create both finish
#
# A flush batch locked each held block as it sent it and kept them all
# locked until the batch completed, waiting in turn for any it could not
# take. It walks the held list in block order, and the journal area sits
# below the data, so it held a journal entry's payload and header while it
# waited for the directory block that entry was for -- and that block's
# writer held the directory block while it waited for the same two
# journal blocks. sync and a rename sat in D for good (a KASAN churn run,
# 2026-11-17). A block the batch cannot take at once is now written after
# the batch has unlocked the rest.
#
# Staged on one node: held_unlist_off keeps the directory block listed
# after a first create writes it; journal_entry_stall_ms pauses a second
# create after its entry's blocks are listed, the directory block locked
# throughout; a sync runs inside that pause.
#   setup: the flush met the locked directory block (keep_lock_deferred
#          moved) -- otherwise the round did not arrange the conflict and
#          is tried again;
#   1. the create and the sync both finish;
#   2. both files are there after a remount, and fsck is clean.
#
# DISCRIMINATION: keep_lock_inorder=1 (the old batch) deadlocks this
# round for good -- a create and a sync in D, the module unloadable, the
# node needing a reboot. It is therefore not run here; it was run by hand
# on a disposable node (2026-11-17), and the setup check above is what
# proves every round of this suite reaches the state that deadlocked.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_entry_stall_ms held_unlist_off keep_lock_inorder; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set journal_entry_stall_ms 0
ct_param_set held_unlist_off 0
ct_param_set keep_lock_inorder 0
ct_param_set hb_interval_secs 30 # a tick's own flush would unlist the block first
IMG="$(ct_image 560 hflo)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hflo)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
ct_mkfs "$DEV" -z 1 -b 512 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
mkdir "$MNT/d"
sync
jw0="$(info journal_writes)"

met=""
for r in 1 2 3 4 5; do
    sync
    echo 1 >$P/held_unlist_off
    touch "$MNT/d/a$r"
    d0="$(info keep_lock_deferred)"
    echo 3000 >$P/journal_entry_stall_ms
    touch "$MNT/d/b$r" &
    tp=$!
    sleep 0.5
    sync &
    sp=$!
    t0=$SECONDS
    while kill -0 "$tp" 2>/dev/null || kill -0 "$sp" 2>/dev/null; do
        [ $((SECONDS - t0)) -lt 30 ] || break
        sleep 0.2
    done
    if kill -0 "$tp" 2>/dev/null || kill -0 "$sp" 2>/dev/null; then
        fail "1: round $r: the create or the sync is still blocked after 30 s -- deadlocked"
        ct_exit
    fi
    wait "$tp" || { fail "1: round $r: the create failed"; ct_exit; }
    wait "$sp" || true
    echo 0 >$P/held_unlist_off
    echo 0 >$P/journal_entry_stall_ms
    d1="$(info keep_lock_deferred)"
    log "round $r: keep_lock_deferred $d0 -> $d1"
    if [ "$d1" -gt "$d0" ]; then
        met=$r
        break
    fi
done
[ "$(info journal_writes)" -gt "$jw0" ] || { fail "setup: the creates wrote no journal entry"; ct_exit; }
[ -n "$met" ] || { fail "setup: in 5 rounds the flush never met the locked directory block"; ct_exit; }
pass "setup: the flush met the directory block locked by the stalled create (round $met)"
pass "1: the create and the sync both finished"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ -e "$MNT/d/a$met" ] && [ -e "$MNT/d/b$met" ] && pass "2: both files are there after a remount" ||
    fail "2: after a remount: $(ls "$MNT/d" | tr '\n' ' ')"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "2: fsck is clean" || fail "2: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
