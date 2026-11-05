#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node's concurrent free-count flushes never tear each other's seed
#
# Free counts accrue in memory and reach a Block Group descriptor by one
# seeded CAS at each durability boundary. The seed was the live cached
# descriptor buffer itself, copied with no lock -- while another thread
# of the same node (a close, an fsync, a drain: none serialised) patched
# that buffer after its own landed CAS. A half-old, half-new seed fails
# the mutator's checksum guard and the refusal is counted as DAMAGE:
# "corruptions:" climbs, and under corruption=stop the node stops, for a
# race inside one node (audit R15).
#
# The seed is now a snapshot taken under the buffer lock the patch takes.
# bg_seed_copy_stall_ms holds the copy open between the count and its
# checksum; two writers allocating in the same Block Group flush it
# concurrently.
#
# Since a seed the mutator refuses is read fresh instead (caw.c), a torn
# seed no longer counts as damage; it costs a wasted read, counted as
# cas_seed_refused. That counter is what this suite watches: zero under
# the locked copy, and nonzero -- with still no damage -- in the control.
#
# The control (last): bg_seed_unlocked=1 copies without the lock, and the
# same load must tear seeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bg_seed_copy_stall_ms ] || { skip "bg_seed_copy_stall_ms is missing"; ct_exit; }

# A real COMPARE AND WRITE target: without one the CAS ignores its seed
# altogether (a node-local read-decide-write), and there is nothing to tear.
IMG="$(ct_image 560 bgseed)"
MNT="$(ct_mnt bgseed)"
WHY="$(ct_tmp bgseed-why)"
DEV="$(ct_lio_disks "$IMG" 1 2>"$WHY")" || { skip "$(cat "$WHY")"; ct_exit; }
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q 'available=yes' "$(ct_procdir "$DEV")/properties" ||
    { fail "setup: the LIO disk is not driven with CAW"; ct_exit; }
ct_param_set auto_defrag 0
INFO="$(ct_procdir "$DEV")/info"
corrupt() { sed -n 's/^corruptions: //p' "$INFO"; }
refused() { sed -n 's/^cas_seed_refused: //p' "$INFO"; }

load() { # <tag>: two writers, each allocating and closing (a flush) in a loop
    local tag="$1" w
    for w in a b; do
        ( for i in $(seq 1 12); do
              dd if=/dev/zero of="$MNT/$tag$w$i" bs=4096 count=2 conv=fsync status=none 2>/dev/null || true
          done ) &
    done
    wait
}

C0="$(corrupt)"
R0="$(refused)"
[ -n "$R0" ] || { fail "setup: procfs info has no cas_seed_refused counter"; ct_exit; }
ct_param_set bg_seed_copy_stall_ms 150
load locked
ct_param_set bg_seed_copy_stall_ms 0
C1="$(corrupt)"
R1="$(refused)"
log "under the locked seed: corruptions $C0 -> $C1, refused seeds $R0 -> $R1"
[ "$R1" = "$R0" ] && pass "concurrent flushes of one Block Group never tore a seed" ||
    fail "concurrent flushes of one Block Group tore $((R1 - R0)) seed(s)"
[ "$C1" = "$C0" ] && pass "and counted no damage" ||
    fail "concurrent flushes of one Block Group counted $((C1 - C0)) corruption(s)"

ct_param_set bg_seed_unlocked 1
ct_param_set bg_seed_copy_stall_ms 150
load unlocked
ct_param_set bg_seed_copy_stall_ms 0
ct_param_set bg_seed_unlocked 0
C2="$(corrupt)"
R2="$(refused)"
log "with the seed copied unlocked: corruptions $C1 -> $C2, refused seeds $R1 -> $R2"
[ "$R2" -gt "$R1" ] && pass "control: copied without the lock, the same load tears seeds ($((R2 - R1)))" ||
    fail "control: the unlocked copy tore no seed either -- the load never raced, this suite proves nothing"
[ "$C2" = "$C1" ] && pass "and a torn seed is read fresh, not counted as damage" ||
    fail "a torn seed was counted as damage ($((C2 - C1))) -- it must be re-read, it is not the device's image"

ct_umount "$MNT"
ct_exit
