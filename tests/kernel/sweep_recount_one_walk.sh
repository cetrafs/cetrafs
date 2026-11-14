#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount that finds many stopped namespace claims counts their names in one walk
#
# A node that stops inside namespace operations leaves its namespace lock
# on each record it was changing. On its next mount the sweep recounts
# each such file's names before clearing the lock -- and a file's count
# is a walk of every inode and dirent block on the volume, so N stopped
# claims were N whole-volume walks (audit 2026-11-14 N2). The locks are
# all still this node's for the whole sweep, so no name of any of them
# can change: their names are now counted in one walk.
#
# 20 files get this node's namespace lock planted, as a stopped
# operation would leave it; the next mount sweeps them:
#   1. the sweep's name counts took one walk;
#   2. every planted lock is cleared, and fsck is clean.
#
# DISCRIMINATION: sweep_walk_each, one walk per file as before: 20.
# The sweep runs only on an unclean re-attach: each round makes the row
# look crashed, so the remount waits out the stale window (120 s).
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/sweep_walk_each ] || { skip "sweep_walk_each is missing"; ct_exit; }
LPOKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
MNT="$(ct_mnt swonew)"
ct_track mnt "$MNT"
ct_param_set sweep_walk_each 0
P=/sys/module/cetrafs/parameters
N=20

# <each 0|1> -> "<walks> <locks left> <fsck clean|ERR>"
round() {
    local img dev me me2 inos ino w w0 left out
    img="$(ct_image 560 "swone$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    me="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info")"
    w0="$(sed -n 's/^sweep_name_walks: //p' "$(ct_procdir "$dev")/info")" # module-wide: a difference
    mkdir "$MNT/d"
    for i in $(seq $N); do echo "f$i" >"$MNT/d/f$i"; done
    inos="$(for i in $(seq $N); do stat -c %i "$MNT/d/f$i"; done)"
    ct_umount "$MNT"
    for ino in $inos; do "$LPOKE" "$img" "$ino" --ns "$me" >/dev/null; done
    "$NODE_POKE" "$dev" "$me" --beat >/dev/null # the row looks crashed
    echo "$1" >$P/sweep_walk_each
    ct_mount "$dev" "$MNT"
    echo 0 >$P/sweep_walk_each
    me2="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info")"
    [ "$me2" = "$me" ] || { echo "notreattached 0 ERR"; ct_umount "$MNT"; return; }
    w="$(sed -n 's/^sweep_name_walks: //p' "$(ct_procdir "$dev")/info")"
    ct_umount "$MNT"
    left=0
    for ino in $inos; do
        "$LPOKE" "$img" "$ino" | grep -q "ns_owner=$me " && left=$((left + 1))
    done
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q '^ERR' <<<"$out" && out=ERR || out=clean
    echo "$((w - w0)) $left $out"
}

read -r D L F <<<"$(round 0)"
[ "$D" = notreattached ] && { fail "setup: the remount did not re-attach the same row"; ct_exit; }
log "one walk: $D walks, $L locks left, fsck $F"
read -r D0 L0 F0 <<<"$(round 1)"
log "per file: $D0 walks, $L0 locks left, fsck $F0"
[ "$L" = 0 ] && [ "$F" = clean ] && pass "2: all $N planted locks were cleared and fsck is clean" ||
    fail "2: $L locks left, fsck $F"
[ "$D0" -ge "$N" ] || { fail "setup: the per-file sweep walked $D0 times -- the $N claims were not swept"; ct_exit; }
[ "$D" = 1 ] && pass "1: the sweep counted $N files' names in one walk (per file: $D0)" ||
    fail "1: the sweep walked $D times for $N files (per file: $D0)"
ct_exit
