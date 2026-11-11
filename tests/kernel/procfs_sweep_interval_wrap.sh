#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a large bg_sweep_min_secs keeps procfs from sweeping the BG table, it does not wrap to "every read"
#
# procfs info sweeps every foreign Block Group descriptor at most once
# per bg_sweep_min_secs. The interval was secs * HZ in 32 bits, so a
# large setting wrapped -- to a small interval as easily as to a large
# one, and a value near 2^32 / HZ swept on every read: the device
# round trips the knob exists to rate-limit (audit 2026-11-11 P1).
#
#  1. CONTROL, 0 (sweep every read): a second read 1.5 s later sweeps
#     again -- the counter can see a sweep.
#  2. a value whose product with HZ wraps to under a second: the second
#     read does not sweep.
#
# DISCRIMINATION (2026-11-11, the unclamped 32-bit product): 2 sweeps.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
HZ="$(sed -n 's/^CONFIG_HZ=//p' "/boot/config-$(uname -r)" 2>/dev/null || true)"
[ -n "$HZ" ] || { skip "cannot read this kernel's CONFIG_HZ"; ct_exit; }

IMG="$(ct_image 1200 swrap)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt swrap)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
refreshed() { awk '$1 == "bg_desc_refreshed:" { print $2 }' "$INFO"; }

sweeps_again() {
    local a b
    ct_param_set bg_sweep_min_secs 0
    refreshed >/dev/null # sweep once, stamping the last-sweep time
    ct_param_set bg_sweep_min_secs "$1"
    refreshed >/dev/null
    a="$(refreshed)"
    sleep 1.5
    b="$(refreshed)"
    [ "$b" -gt "$a" ]
}

log "1: CONTROL -- 0 sweeps every read"
sweeps_again 0 && pass "1: a read 1.5 s later swept again (the counter sees a sweep)" ||
    { fail "1 setup: no sweep counted even at 0 -- there are no foreign groups to refresh"; ct_exit; }

WRAP=$(((4294967296 + HZ - 1) / HZ))
log "2: bg_sweep_min_secs=$WRAP (x HZ=$HZ wraps to $((WRAP * HZ % 4294967296)) jiffies in 32 bits)"
sweeps_again "$WRAP" && fail "2: a read 1.5 s after a sweep swept again -- the interval wrapped" ||
    pass "2: no sweep: the interval is long, as set"
ct_umount "$MNT"
ct_exit
