#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a zone group taken over after mount brings only the block groups it owns NOW
#
# Every node keeps an in-core map of which Zone Group owns each Block
# Group (bg_owner_zg[]), read once at mount. Peers change it afterwards:
# an owner hands an empty Block Group back, another node claims it. When
# this node later takes a Zone Group over -- the HA case, reclaiming a
# dead peer's -- it derived the Block Groups it may use from that
# mount-time map, so a group that had since moved to another node's Zone
# Group was treated as ours: the allocator's ownership check turned
# allocations in it into -EPERM, and the scrub, which also takes its
# list from the map, judged the other node's blocks as leaked and freed
# them.
#
# The suite poses as the peers by editing the image while mounted: ZG1
# belongs to a dead node, and its BG1 is moved to ZG2 with every block
# in use. Once this node reclaims ZG1, BG1 must not be among its block
# groups and its scrub must free nothing there.
#
# DISCRIMINATION: on the unfixed code ZG1 still lists BG1 after the
# reclaim and the scrub frees BG1's blocks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"

IMG="$(ct_image 1700 bgmap)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgmap)"
PD="$(basename "$DEV")"
ct_mkfs "$DEV" -z 3 -b 512 -J 0 -N 1024 -f >/dev/null
info() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }
members() { sed -n "s/^ *zg $1: .*block_groups=\([0-9]*\).*/\1/p" "/proc/fs/cetrafs/$PD/info"; }

set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 aa
"$ZG_POKE" "$DEV" 1 1 >/dev/null # ZG1 (with BG1) belongs to node 1
# A fast scrub, scheduled at mount, disarmed until the peers have acted.
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
log "after mount: $(grep 'zg ' "/proc/fs/cetrafs/$PD/info" | tr -s ' ' | tr '\n' ';')"
[ "$(members 1)" = 1 ] && pass "setup: the mount-time map puts BG1 in ZG1" ||
    { fail "setup: ZG1 has $(members 1) block group(s) at mount, not 1"; ct_exit; }

# The peers, while we are mounted: BG1 handed back and claimed into ZG2,
# by a node now using every block of it.
"$BG_POKE" "$DEV" 1 --owner 2 >/dev/null
"$BG_POKE" "$DEV" 1 0 fill-bitmap >/dev/null

# The scrub adopts a dead peer's Zone Group before each cycle -- the
# path that reclaims ZG1 here -- and then scrubs it in the same cycle.
R0="$(info scrub_reclaimed)"
DM="$(dmesg_mark)"
ct_param_set scrub 1
wait_for 30 "dmesg_since '$DM' | grep -q 'reclaiming ZG 1 from stale node 1'" ||
    { fail "setup: ZG1 was never reclaimed from the dead node"; ct_exit; }
pass "setup: this node reclaimed ZG1 from the dead node"
sleep 8 # several scrub cycles over what the reclaim brought in
ct_param_set scrub 0
log "after reclaim: $(grep 'zg ' "/proc/fs/cetrafs/$PD/info" | tr -s ' ' | tr '\n' ';')"
[ "$(members 1)" = 0 ] && [ "$(members 2)" = 2 ] &&
    pass "the reclaim took the block groups ZG1 owns now: none (BG1 is ZG2's)" ||
    fail "after the reclaim ZG1 lists $(members 1) block group(s) and ZG2 $(members 2) -- the map is the mount-time one"
RD=$(($(info scrub_reclaimed) - R0))
[ "$RD" = 0 ] && pass "the scrub freed nothing in another node's block group" ||
    fail "the scrub freed $RD block(s) -- BG1 belongs to ZG2, whose node is using them"
ct_umount "$MNT"
ct_exit
