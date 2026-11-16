#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a dirent block torn under a peer's namespace lock is not counted as damage
#
# Every dirent write runs under its directory's namespace lock and is
# journaled. A peer that dies mid-write leaves the block torn until the
# reclaim that breaks its lock replays its journal -- up to the stale
# window. Readers on every other node counted it as damage after their
# ~255 ms retry budget: needs-fsck raised volume-wide, and under
# corruption=stop every node that listed the directory stopped, for one
# node's crash (audit 2026-11-15 M-16/BM-26).
#
#   F. the block torn, the directory's namespace lock held by a peer:
#      the listing fails, nothing is counted, and the log says why;
#   N. the same with the lock free: still counted as damage.
#
# DISCRIMINATION: dirent_tear_lock_ignored=1 (as before): F counts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
MNT="$(ct_mnt dtpl)"
ct_track mnt "$MNT"
PEER=5
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <held 0|1> <knob 0|1> -> RES
round() {
    local img dev di db mark out c0 c1 ls=ok
    img="$(ct_image 560 "dtpl$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_param_set dirent_tear_lock_ignored "$3"
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    for i in 1 2 3; do touch "$MNT/d/e$i"; done
    sync
    di="$(stat -c %i "$MNT/d")"
    db="$("$IPOKE" "$img" extents "$di" | sed -n 's/^ext 0 logical=0 phys=\([0-9]*\) .*/\1/p')"
    [ -n "$db" ] || { fail "setup: no dirent block"; ct_exit; }
    c0="$(sed -n 's/^corruptions: //p' "$(ct_procdir "$dev")/info")"
    printf '\xff\xff\xff\xff' | dd of="$img" bs=1 seek=$((db * 4096 + 4092)) conv=notrunc status=none
    if [ "$2" = 1 ]; then
        "$LPOKE" "$img" "$di" --ns "$PEER" >/dev/null || { fail "setup: inode_lock_poke --ns"; ct_exit; }
    fi
    "$IPOKE" "$img" bumpseq "$di" 2>/dev/null
    mark="$(dmesg_mark)"
    ls "$MNT/d" >/dev/null 2>&1 && ls=listed
    c1="$(sed -n 's/^corruptions: //p' "$(ct_procdir "$dev")/info")"
    out="$(dmesg_since "$mark")"
    RES="ls=$ls tail=$(grep -c 'dirent block .* failed its tail checksum\|reads torn while node' <<<"$out" || true)"
    RES="$RES explained=$(grep -c "reads torn while node $PEER holds its namespace lock" <<<"$out" || true)"
    RES="$RES counted=$((c1 - c0))"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    ct_param_set dirent_tear_lock_ignored 0
}

round c 1 1
C="$RES"
log "control (held, as before): $C"
round f 1 0
R="$RES"
log "held: $R"
round n 0 0
N="$RES"
log "free: $N"
for x in "$R" "$C" "$N"; do
    [ "$(get ls "$x")" = ok ] && [ "$(get tail "$x")" -ge 1 ] || { fail "setup: the torn block was not reached: $x"; ct_exit; }
done
[ "$(get counted "$R")" = 0 ] && [ "$(get explained "$R")" -ge 1 ] &&
    pass "F: torn under a peer's namespace lock -- refused, not counted as damage" || fail "F: $R"
[ "$(get counted "$C")" -ge 1 ] && pass "control: as before, the tear was counted as damage" ||
    fail "control: not counted without the change -- the suite does not reach it: $C"
[ "$(get counted "$N")" -ge 1 ] && [ "$(get explained "$N")" = 0 ] &&
    pass "N: with the lock free the same tear is still damage" || fail "N: $N"
ct_exit
