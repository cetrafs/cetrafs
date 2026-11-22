#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a volume whose inode table was grown mounts with no damage counted, and counts its free inodes right
#
# The mount seeds its free-inode count from one bitmap scan. That scan
# ran before the layout walk, while the inode table was still one
# segment as large as the whole count -- so on a grown table it read
# the blocks past the first segment's bitmap as bitmap: checksum
# failures, a damage mark on the volume at every mount, and a refused
# mount under corruption=stop (audit 2026-11-22 N-6). It now runs after
# the walk, and the first segment is sized by its own count until then.
#
# mkfs -N 1024, offline growfs to -N 40000 (the existing grow_inodes.sh
# stays inside one bitmap block and cannot reach this), then a mount:
#   1. no corruption counted;
#   2. statfs counts the grown inodes free (more than 1024).
#
# DISCRIMINATION: the control, in-suite -- free_inodes_before_walk=1,
# the old order: damage is counted at mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/free_inodes_before_walk ] || { skip "free_inodes_before_walk is missing"; ct_exit; }
GROWFS="$ROOT/userspace/growfs.cetra"
MNT="$(ct_mnt gimc)"
ct_track mnt "$MNT"
ct_param_set free_inodes_before_walk 0

# round <before 0|1> -> "<corruptions> <free inodes> <inodes>"
round() {
    local dev c ff fi
    dev="$(ct_loop "$(ct_image 1400 "gimc$1")")"
    ct_mkfs "$dev" -s 700M -N 1024 -f >/dev/null
    CETRAFS_PEER_PROBE_SECS=3 "$GROWFS" "$dev" -s 1400M -N 40000 >/dev/null 2>&1 || { echo "x x x"; return; }
    echo "$1" >/sys/module/cetrafs/parameters/free_inodes_before_walk
    if ! ct_mount "$dev" "$MNT" 2>/dev/null; then
        echo 0 >/sys/module/cetrafs/parameters/free_inodes_before_walk
        echo "refused 0 0"
        return
    fi
    echo 0 >/sys/module/cetrafs/parameters/free_inodes_before_walk
    c="$(sed -n 's/^corruptions: //p' "$(ct_procdir "$dev")/info")"
    ff="$(stat -f -c %d "$MNT")"
    fi="$(stat -f -c %c "$MNT")"
    ct_umount "$MNT"
    echo "$c $ff $fi"
}

read -r CC CF CI <<<"$(round 1)"
log "control (count before the walk): corruptions $CC, free inodes $CF of $CI"
read -r C F I <<<"$(round 0)"
log "fixed: corruptions $C, free inodes $F of $I"
[ "$I" != x ] && [ "${I:-0}" -gt 1024 ] || { fail "setup: the grow did not take the table past 1024 ($I)"; ct_exit; }
[ "$CC" = refused ] || [ "${CC:-0}" -ge 1 ] && pass "control: counting before the walk marks the grown volume damaged ($CC)" ||
    fail "control: no damage with the old order ($CC) -- the hazard did not reproduce"
[ "$C" = 0 ] && pass "1: the grown volume mounts with no damage counted" || fail "1: corruptions $C at mount"
[ "${F:-0}" -gt 1024 ] && pass "2: statfs counts the grown inodes free ($F of $I)" || fail "2: free inodes $F of $I"
ct_exit
