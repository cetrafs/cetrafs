#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a clean re-attach rewrites only the Block Group counts that drifted
#
# Every ownership entry -- a claim, a steal, the mount's re-attach --
# rewrote every member Block Group's count with its own compare-and-write
# to move its epoch (reconcile_seq), whether the count had drifted or not:
# ~2.5 min of serial CAW per Zone Group on a 64 TiB re-attach (audit
# 2026-11-14 P3). The epoch exists to drop a late delta from the previous
# owner, and there can be none when that owner flushed everything before
# giving the group up: a clean departure (announced only after the final
# flushes succeeded), or a release (which refuses while a delta is
# outstanding). There a count that matches its bitmap keeps its epoch.
#
#   1. clean re-attach: every member keeps its epoch, and the mount's
#      compare-and-writes do not scale with the Block Groups;
#   2. unclean re-attach (the row made to look crashed): every member's
#      epoch moves, as before;
#   3. fsck clean after each, and the free count after the remount is
#      the one before it.
#
# DISCRIMINATION: reconcile_epoch_always=1 rewrites every member on the
# clean re-attach too.
# The unclean round waits out the stale window (120 s) before it can
# register again.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reconcile_epoch_always ] || { skip "reconcile_epoch_always is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"
MNT="$(ct_mnt repoch)"
ct_track mnt "$MNT"

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# remount <clean|crash> <always 0|1> -> "<kept> <cas ops> <free before> <free after>"
# Both counters are module-wide: the difference across the unmount and
# the mount (the unmount's own writes are the same in every round).
remount() {
    local k0 c0 f0 me
    me="$(info this_node_id)"
    f0="$(stat -f -c %f "$MNT")"
    k0="$(info reconcile_epoch_kept)"
    c0="$(info cas_ops)"
    ct_umount "$MNT"
    [ "$1" = crash ] && "$NODE_POKE" "$DEV" "$me" --beat >/dev/null # the row looks crashed
    ct_param_set reconcile_epoch_always "$2"
    ct_mount "$DEV" "$MNT"
    ct_param_set reconcile_epoch_always 0
    echo "$(($(info reconcile_epoch_kept) - k0)) $(($(info cas_ops) - c0)) $f0 $(stat -f -c %f "$MNT")"
}

DEV="$(ct_loop "$(ct_image 8192 repoch)")"
# Small Block Groups, one Zone Group: many members to re-attach.
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NBG="$(info block_group_count)"
dd if=/dev/urandom of="$MNT/f" bs=1M count=64 status=none
sync

read -r K C F0 F1 <<<"$(remount clean 0)"
log "clean re-attach: $K of $NBG member count(s) kept their epoch, $C CAS op(s) at mount; free $F0 -> $F1"
read -r K0 C0 G0 G1 <<<"$(remount clean 1)"
log "control (reconcile_epoch_always): $K0 kept, $C0 CAS op(s) at mount"
read -r KU CU H0 H1 <<<"$(remount crash 0)"
log "unclean re-attach: $KU kept, $CU CAS op(s) at mount"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"

[ "$NBG" -ge 8 ] || { fail "setup: only $NBG Block Groups -- nothing to scale"; ct_exit; }
pass "setup: $NBG Block Groups in the one Zone Group"
[ "$K" -ge $((NBG * 9 / 10)) ] && pass "1: the clean re-attach kept $K of $NBG epochs" ||
    fail "1: the clean re-attach kept only $K of $NBG epochs"
[ "$C0" -ge $((C + NBG * 9 / 10)) ] && pass "1: the mount took $C CAS ops against $C0 rewriting every member" ||
    fail "1: the mount took $C CAS ops, the control $C0 -- the saving does not scale with the $NBG members"
[ "$K0" = 0 ] && pass "control: reconcile_epoch_always rewrote every member" || fail "control: $K0 epochs kept with reconcile_epoch_always"
[ "$KU" = 0 ] && pass "2: the unclean re-attach moved every epoch" || fail "2: the unclean re-attach kept $KU epochs"
[ "$F1" = "$F0" ] && [ "$G1" = "$G0" ] && [ "$H1" = "$H0" ] && pass "3: the free count survived every re-attach" ||
    fail "3: free $F0->$F1, $G0->$G1, $H0->$H1"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "3: fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)" || pass "3: fsck clean"
ct_exit
