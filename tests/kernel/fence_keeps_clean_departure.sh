#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reclaim's fence records DEAD only for a node that did not say it left
#
# The reclaim fence stamps departure = DEAD with the revoked lease, so
# the next observer reads the verdict in one block instead of watching
# the row for a window. It stamped it over a CLEAN departure too: a
# node that unmounted cleanly and still owned a Zone Group had that
# group taken, and its row then read DEAD -- its next mount watched a
# stale window first, and the row was no longer recyclable as a clean
# one (N-57). CLEAN already says everything DEAD would: the node is
# gone, and it left nothing to sweep.
#
# One-group volume; ZG 0 planted as node 1's, node 1's row REGISTERED
# with departure CLEAN:
#   1. the mount takes ZG 0 (node 1's lease is revoked);
#   2. node 1's departure still reads CLEAN.
# Round B: the same with departure NONE (a crash): it reads DEAD after.
#
# DISCRIMINATION: with the fence stamping DEAD unconditionally, check 2
# reads DEAD.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ZG_POKE="$(ct_helper zg_poke)"
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt fkcd)"
ct_track mnt "$MNT"

# <tag> <departure before> -> RES
round() {
    local img dev me
    img="$(ct_image 560 "fkcd$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    ct_umount "$MNT"
    set_stale_window "$TEST_STALE_SECS"
    poke_dead_peer "$dev" 1 aa
    "$NPOKE" "$dev" 1 --depart "$2" >/dev/null
    "$ZG_POKE" "$dev" 0 1 >/dev/null
    blockdev --flushbufs "$dev"
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    me="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info")"
    ct_umount "$MNT"
    local row
    row="$("$NPOKE" "$img" 1)"
    RES="owner=$("$ZG_POKE" "$img" 0 | sed -n 's/^owner_node_id=\([0-9]*\) .*/\1/p') me=$me"
    RES="$RES departure=$(sed -n 's/.*departure=\([0-9]*\).*/\1/p' <<<"$row") epoch=$(sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p' <<<"$row")"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round a 1
log "A (left CLEAN): $RES"
[ "$(get owner "$RES")" = "$(get me "$RES")" ] && [ "$(get epoch "$RES")" -ge 1 ] &&
    pass "1: the mount took ZG 0 and revoked node 1's lease" || fail "1: setup: $RES"
[ "$(get departure "$RES")" = 1 ] && pass "2: node 1's departure still reads CLEAN" ||
    fail "2: node 1's departure reads $(get departure "$RES") after the fence, not CLEAN (1)"
round b 0
log "B (crashed): $RES"
[ "$(get owner "$RES")" = "$(get me "$RES")" ] && [ "$(get departure "$RES")" = 2 ] &&
    pass "B: a node that never said it left is recorded DEAD" || fail "B: $RES"
ct_exit
