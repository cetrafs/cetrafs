#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node catches up with a grow it did not make: by heartbeat, on demand, and not at all when it does not verify
#
# Every node but the grower learns of a live grow from the superblock's
# layout_gen (fs.c, cetrafs_sb_layout_refresh()): the heartbeat reads
# block 0 each tick, and any check about to refuse an address past the
# end of the layout it knows catches up first -- a peer may have grown
# the volume and allocated there before this node's heartbeat came
# round, and refusing then is a FALSE corruption verdict that marks a
# healthy file damaged.
#
# One host is one node (node_uuid is fixed at module load), so the peer
# is played by this node itself: grow_skip_local_publish commits a grow
# to the device and leaves this node's layout where it was, which is
# exactly the state of a peer that has not caught up. Each path is then
# made the SOLE path with the other's test knob:
#
#  A. heartbeat: on-demand off. With the heartbeat's refresh also off
#     the node stays behind for several beats (the control); switched
#     back on, it catches up within a few.
#  B. a refresh that does not verify keeps the current layout:
#     layout_refresh_fail_once refuses one; the refusal is counted and
#     the old layout is still in force, and the next beat succeeds.
#  C. on demand: heartbeat refresh off. A file's extent is pointed into
#     the space the grow added (as a peer's allocation would be) and
#     read. With the on-demand refresh off (the control) the read is
#     refused as corrupt; with it on, the read returns the block and the
#     node has caught up -- with no beat involved.
#  D. a grow-shaped superblock whose data area ends past the volume
#     (bg_data_end > total_blocks -- a field a grow may change, outside
#     its bounds) is refused and the node keeps running
#     (GROWFS-LIVE-REVIEW L1); the control puts the field back, keeping
#     the bump, and the very same refresh accepts it.
#  E. a superblock whose layout_gen moved but which changed something a
#     grow never changes (inode_table_start) stops the mount -- a fatal
#     error, the state a crash leaves -- and is never adopted (L5: it
#     used to be logged and the mount carried on); put back, the volume
#     mounts again.
#
# DISCRIMINATION: D passes a bg_data_end past the volume without
# cetrafs_layout_bounds_check(); E leaves the mount running with the
# refresh's fatal call removed (2026-11-08).
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PPOKE="$(ct_helper extent_phys_poke)"
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_big_image 2900 growrefresh)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt growrefresh)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0
ct_param_set layout_past_end_no_refresh 0
ct_param_set layout_refresh_fail_once 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
wait_gen() { # <gen> <beats> -> 0 once this node knows layout_gen <gen>
    local i
    for i in $(seq 1 $(($2 * 4))); do
        [ "$(info layout_gen)" = "$1" ] && return 0
        sleep 0.5
    done
    return 1
}
grow_behind() { # <size> -> growfs output; the grow is committed, this node not switched
    ct_param_set grow_skip_local_publish 1
    ct_growfs "$DEV" -s "$1" 2>&1
}

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for v in v1 v2; do dd if=/dev/zero of="$MNT/$v" bs=4096 count=1 conv=fsync status=none; done
INO1="$(stat -c %i "$MNT/v1")"; INO2="$(stat -c %i "$MNT/v2")"

# ------------------------------------------------------------- A: heartbeat
log "A: the heartbeat catches up (on-demand refresh off)"
ct_param_set layout_past_end_no_refresh 1
ct_param_set layout_refresh_hb_off 1
gen0="$(info layout_gen)"; bgs0="$(info block_group_count)"; r0="$(info layout_refreshes)"
out="$(grow_behind 1400M)" || { fail "A: setup: the grow failed: $(tail -2 <<<"$out")"; ct_exit; }
[ "$(cat /sys/module/cetrafs/parameters/grow_skip_local_publish)" = "N" ] ||
    { fail "A: setup: the grow did not consume grow_skip_local_publish -- this node may have switched itself"; ct_exit; }
[ "$(info layout_gen)" = "$gen0" ] && pass "A: setup: the grow is on the device and this node is still at layout_gen $gen0" ||
    { fail "A: setup: this node switched to layout_gen $(info layout_gen) on its own -- nothing below would test a refresh"; ct_exit; }
sleep 8
[ "$(info layout_gen)" = "$gen0" ] && pass "A: control: with the heartbeat's refresh off the node stays behind for 4 beats" ||
    fail "A: control: the node caught up with the heartbeat refresh off -- some other path did it"
ct_param_set layout_refresh_hb_off 0
if wait_gen "$((gen0 + 1))" 4; then
    pass "A: the heartbeat brought the node to layout_gen $((gen0 + 1))"
else
    fail "A: the node is still at layout_gen $(info layout_gen) four beats after the grow"
fi
[ "$(info block_group_count)" -gt "$bgs0" ] && [ "$(info layout_refreshes)" -gt "$r0" ] &&
    pass "A: it knows $(info block_group_count) Block Groups (was $bgs0), one refresh counted" ||
    fail "A: layout_gen moved but the Block Groups ($(info block_group_count)) or the refresh count did not"

# --------------------------------------------------- B: a refused refresh
log "B: a refresh that does not verify keeps the current layout"
gen1="$(info layout_gen)"; bgs1="$(info block_group_count)"; f0="$(info layout_refresh_refused)"
ct_param_set layout_refresh_hb_off 1
out="$(grow_behind 2100M)" || { fail "B: setup: the grow failed: $(tail -2 <<<"$out")"; ct_exit; }
ct_param_set layout_refresh_fail_once 1
ct_param_set layout_refresh_hb_off 0
for _ in $(seq 1 40); do [ "$(info layout_refresh_refused)" -gt "$f0" ] && break; sleep 0.25; done
g="$(info layout_gen)"; b="$(info block_group_count)"
[ "$(info layout_refresh_refused)" -gt "$f0" ] || { fail "B: setup: no refresh was refused within 10s"; ct_exit; }
[ "$g" = "$gen1" ] && [ "$b" = "$bgs1" ] &&
    pass "B: the refused refresh left layout_gen $g and $b Block Groups in force" ||
    fail "B: a refused refresh still changed the layout ($gen1/$bgs1 -> $g/$b)"
wait_gen "$((gen1 + 1))" 4 && pass "B: and the next beat caught up (layout_gen $((gen1 + 1)))" ||
    fail "B: the node never caught up after the refused refresh"

# ------------------------------------------------------------ C: on demand
log "C: an address in the new space makes the node catch up (heartbeat refresh off)"
ct_param_set layout_refresh_hb_off 1
gen2="$(info layout_gen)"
out="$(grow_behind 2800M)" || { fail "C: setup: the grow failed: $(tail -2 <<<"$out")"; ct_exit; }
NEWBG="$(sed -n 's/.*new BG regions: LBA \([0-9][0-9]*\) .*/\1/p' <<<"$out")"
[ -n "$NEWBG" ] || { fail "C: setup: growfs did not say where the new Block Group is"; ct_exit; }
[ "$(info layout_gen)" = "$gen2" ] || { fail "C: setup: the node switched layout on its own"; ct_exit; }
T1=$((NEWBG + 65536)); T2=$((NEWBG + 65537)) # the middle of the new 512 MiB Block Group: data, not header
printf 'MARKER-ONE\n' | dd of="$IMG" bs=4096 seek="$T1" conv=notrunc,sync status=none
printf 'MARKER-TWO\n' | dd of="$IMG" bs=4096 seek="$T2" conv=notrunc,sync status=none
P1="$("$PPOKE" "$IMG" "$INO1" "$T1")" && P2="$("$PPOKE" "$IMG" "$INO2" "$T2")" ||
    { fail "C: setup: could not aim the extents: $P1 $P2"; ct_exit; }
WAS1="$(sed -n 's/.*phys \([0-9][0-9]*\) ->.*/\1/p' <<<"$P1")"
WAS2="$(sed -n 's/.*phys \([0-9][0-9]*\) ->.*/\1/p' <<<"$P2")"
sync; echo 3 >/proc/sys/vm/drop_caches

ct_param_set layout_past_end_no_refresh 1
mark="$(dmesg_mark)"
if got="$(cat "$MNT/v1" 2>/dev/null | head -c 10)" && [ "$got" = "MARKER-ONE" ]; then
    fail "C: control: the read through the new space succeeded with the on-demand refresh off -- the test does not reach it"
else
    dmesg_since "$mark" | grep -q 'not a data address' &&
        pass "C: control: without the refresh the address is refused as corrupt (the false verdict)" ||
        fail "C: control: the read failed, but not on the address check"
fi
[ "$(info layout_gen)" = "$gen2" ] || fail "C: control: the node caught up with both refresh paths off"

ct_param_set layout_past_end_no_refresh 0
r2="$(info layout_refreshes)"
got="$(head -c 10 "$MNT/v2" 2>/dev/null || true)"
[ "$got" = "MARKER-TWO" ] && pass "C: with the refresh on, the file reads the block the grow added" ||
    fail "C: the read through the new space returned '${got:-an error}'"
[ "$(info layout_gen)" = "$((gen2 + 1))" ] && [ "$(info layout_refreshes)" -gt "$r2" ] &&
    pass "C: and the read itself brought the node to layout_gen $((gen2 + 1)), no beat involved" ||
    fail "C: the node is at layout_gen $(info layout_gen) after the read (expected $((gen2 + 1)))"

# ------------------------------------- D: a grow that breaks its bounds
log "D: a grow-shaped superblock whose data area runs past the volume is refused"
ct_param_set layout_refresh_hb_off 0
gen3="$(info layout_gen)"; bgs3="$(info block_group_count)"; f0="$(info layout_refresh_refused)"
TOT="$("$SBPOKE" "$IMG" | sed -n 's/^total_blocks=//p')"
BDE="$("$SBPOKE" "$IMG" | sed -n 's/^bg_data_end=//p')"
[ -n "$TOT" ] && [ -n "$BDE" ] || { fail "D: setup: could not read total_blocks/bg_data_end"; ct_exit; }
"$SBPOKE" "$IMG" bg_data_end "$((TOT + 64))" >/dev/null # a field a grow may change, out of its bounds
"$SBPOKE" "$IMG" layout_gen "$((gen3 + 1))" >/dev/null
for _ in $(seq 1 40); do [ "$(info layout_refresh_refused)" -gt "$f0" ] && break; sleep 0.25; done
[ "$(info layout_refresh_refused)" -gt "$f0" ] && [ "$(info layout_gen)" = "$gen3" ] &&
    [ "$(info block_group_count)" = "$bgs3" ] && [ "$(info stopped)" = none ] &&
    pass "D: refused, the node keeps layout_gen $gen3 and keeps running" ||
    fail "D: a data area ending past the volume was not refused (layout_gen $(info layout_gen), refused $(info layout_refresh_refused) was $f0, stopped $(info stopped))"
"$SBPOKE" "$IMG" bg_data_end "$BDE" >/dev/null
wait_gen "$((gen3 + 1))" 4 && pass "D: control: with the field put back, the same bump is accepted" ||
    fail "D: control: the bump alone was refused too -- the refusal above proves nothing about the field"

# ----------------------------------------- E: a change that is not a grow
log "E: a superblock that moved more than a grow moves stops the mount"
gen4="$(info layout_gen)"
ITS="$("$SBPOKE" "$IMG" | sed -n 's/^inode_table_start=//p')"
[ -n "$ITS" ] || { fail "E: setup: could not read inode_table_start"; ct_exit; }
mark="$(dmesg_mark)"
"$SBPOKE" "$IMG" inode_table_start "$((ITS + 1))" >/dev/null
"$SBPOKE" "$IMG" layout_gen "$((gen4 + 1))" >/dev/null
for _ in $(seq 1 40); do [ "$(info stopped)" != none ] && break; sleep 0.25; done
[ "$(info stopped)" = error ] && [ "$(info layout_gen)" = "$gen4" ] &&
    dmesg_since "$mark" | grep -q 'in a way a grow does not' &&
    pass "E: the mount stopped (a fatal error), never adopting the rewrite" ||
    fail "E: a superblock with a moved inode table did not stop the mount (stopped $(info stopped), layout_gen $(info layout_gen))"
"$SBPOKE" "$IMG" inode_table_start "$ITS" >/dev/null
"$SBPOKE" "$IMG" layout_gen "$gen4" >/dev/null
compress_timing # a remount after a stop is an unclean re-attach: it waits the stale window for a twin
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(info stopped)" = none ] && [ "$(info layout_gen)" = "$gen4" ] &&
    pass "E: with block 0 put back, the volume mounts again at layout_gen $gen4" ||
    fail "E: the volume did not come back after block 0 was put back"

ct_umount "$MNT"
"$PPOKE" "$IMG" "$INO1" "$WAS1" >/dev/null && "$PPOKE" "$IMG" "$INO2" "$WAS2" >/dev/null ||
    fail "cleanup: could not put the extents back"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck is clean after three grows this node learned of second-hand" ||
    fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
