#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a claim scan passes over a group whose owner's row it cannot read
#
# The scan for a Zone Group to claim asks, of each foreign-owned group,
# whether its owner is stale. An owner row that failed its checksum made
# that question an error, and the scan returned it: no group was
# claimed although unowned ones sat further down the table, so the
# mount -- or any write needing a group -- failed over one peer's row
# (N-30). Unreadable Zone Group records were already skipped; an
# unreadable owner row now is too: an owner that cannot be called stale
# is not eligible, as a live one.
#
# Three Zone Groups; this node owns ZG 0, whose Block Groups are full.
# While mounted, ZG 1 is planted as node 1's and node 1's row is given a
# broken checksum; then a write needs a group:
#   1. the write's claim passes over ZG 1 and takes ZG 2; the write lands;
#   2. ZG 1 is still node 1's.
#
# DISCRIMINATION: with the scan returning the error, the mount fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt zgsuo)"
ct_track mnt "$MNT"

IMG="$(ct_image 1600 zgsuo)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 3 -b 512 -J 0 -N 1024 -f >/dev/null
BG_POKE="$(ct_helper bg_poke)"
zgowner() { "$ZG_POKE" "$IMG" "$1" | sed -n 's/^owner_node_id=\([0-9]*\) .*/\1/p'; }
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ME="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
ct_umount "$MNT"
[ "$(zgowner 0)" = "$ME" ] && [ "$(zgowner 1)" = 65535 ] && [ "$(zgowner 2)" = 65535 ] ||
    fail "setup: owners are $(zgowner 0)/$(zgowner 1)/$(zgowner 2), not this node/none/none"
for bg in $(ct_bgs_of_zg "$DEV" 0); do "$BG_POKE" "$DEV" "$bg" 0 fill-bitmap >/dev/null; done
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 aa # registered: the mount gate fences it and lets the mount through
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
"$ZG_POKE" "$IMG" 1 1 >/dev/null
"$NPOKE" "$IMG" 1 --badsum >/dev/null
[ "$(zgowner 1)" = 1 ] || fail "setup: ZG 1 is not node 1's: $(zgowner 1)"

MARK="$(dmesg_mark)"
dd if=/dev/urandom of="$MNT/f" bs=64k count=1 conv=fsync status=none 2>"$IMG.err" && OK=1 || OK=0
ct_track file "$IMG.err"
dmesg_since "$MARK" | grep -q 'node row 1 failed its checksum' && pass "setup: the claim read node 1's row and found it broken" ||
    fail "setup: node 1's row was never read as broken: $(dmesg_since "$MARK" | grep -iE 'claim|row' | head -3 | tr '\n' ' ')"
O1="$(zgowner 1)"; O2="$(zgowner 2)"
[ "$OK" = 1 ] && [ "$O2" = "$ME" ] &&
    pass "1: the claim passed over ZG 1's unreadable owner, took ZG 2, and the write landed" ||
    fail "1: write ok=$OK ($(cat "$IMG.err")), owners now $(zgowner 0)/$O1/$O2, this node $ME"
[ "$O1" = 1 ] && pass "2: ZG 1 is still node 1's" || fail "2: ZG 1 went to node $O1"
ct_umount "$MNT"
ct_exit
