#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free dropped inside the queue-full backoff does not push the next scan back
#
# A free that finds a Zone Group's pending-free queue full remembers it
# for pf_full_backoff_ms, so a burst does not rescan the whole queue per
# extent (pending_free_backoff.sh). But every dropped free re-armed that
# deadline, including those made inside the backoff that scanned
# nothing: under a sustained delete the deadline slid forward with each
# free, the node never looked at the queue again, and every free after
# the first full scan leaked to the scrub however much room the owner's
# drain had made (audit 2026-11-22 N-59). Only a scan that found the
# queue full arms it now.
#
# Staged on one node: pf_force_foreign routes frees through the queue
# and pf_force_queue_full reports it full; pf_full_backoff_ms=1000. Thirty
# files deleted one every 250 ms (each evicted, so each frees): about
# 7.5 s of sustained frees. A rescan is due each second, so at least 4
# scans; sliding, there is one.
#
# DISCRIMINATION: the control, in-suite -- pf_backoff_rearm_any=1, the
# old re-arm on every drop.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in pf_backoff_rearm_any pf_force_foreign pf_force_queue_full; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
DEV="$(ct_dev 1200 pfbnr)"
MNT="$(ct_mnt pfbnr)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
counter() { awk -v k="^$1:" '$0 ~ k {print $2}' "$INFO"; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set pf_backoff_rearm_any 0
ct_param_set pf_full_backoff_ms 1000

# burst <tag> <rearm_any> -> "<drops> <scans>"
burst() {
    local s0 d0 i
    mkdir -p "$MNT/$1"
    for i in $(seq 1 30); do dd if=/dev/zero of="$MNT/$1/f$i" bs=4k count=1 status=none; done
    sync
    ct_param_set pf_force_foreign 1
    ct_param_set pf_force_queue_full 1
    echo "$2" >/sys/module/cetrafs/parameters/pf_backoff_rearm_any
    sleep 1.5 # any backoff left from before has expired
    s0="$(counter pf_full_scans)"
    d0="$(counter pf_drop_runs)"
    for i in $(seq 1 30); do
        rm -f "$MNT/$1/f$i"
        echo 2 >/proc/sys/vm/drop_caches # evicted: the free happens now
        sleep 0.25
    done
    echo 0 >/sys/module/cetrafs/parameters/pf_backoff_rearm_any
    ct_param_set pf_force_queue_full 0
    ct_param_set pf_force_foreign 0
    echo "$(($(counter pf_drop_runs) - d0)) $(($(counter pf_full_scans) - s0))"
}

read -r CD CS <<<"$(burst ctl 1)"
log "control (re-arm on every drop): $CD drop(s), $CS scan(s)"
read -r D S <<<"$(burst fixed 0)"
log "fixed: $D drop(s), $S scan(s)"
[ "$D" -ge 20 ] && [ "$CD" -ge 20 ] ||
    { fail "setup: only $D / $CD drops -- the deletes did not reach the drop path"; ct_umount "$MNT"; ct_exit; }
[ "$CS" -le 2 ] && pass "control: re-armed by every drop, the queue was scanned $CS time(s) in 7.5 s of frees" ||
    fail "control: $CS scans with the re-arm on every drop -- the hazard did not reproduce"
[ "$S" -ge 4 ] && pass "a sustained delete rescans the queue once a backoff period ($S scans for $D drops)" ||
    fail "a sustained delete scanned the queue $S time(s) in 7.5 s -- the backoff slid"
ct_umount "$MNT"
ct_exit
