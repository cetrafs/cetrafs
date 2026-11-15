#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live registry row whose state reads FREE is damaged, not free
#
# A FREE row carries no checksum (mkfs zero-fills the table), and the
# readers believed `state == FREE` whatever the rest of the row held. So
# one flipped field in a live node's row made it read FREE: the next
# mounter registered onto it -- two machines on one row, one id -- and a
# reclaim's fence found "nothing to revoke" and took the node's claims
# (audit 2026-11-15 BM-36). Every writer that gives a row back writes
# zeros, so FREE is now believed only of a blank row; anything else must
# pass its checksum.
#
# Row 0 is planted as a live peer's (a full, checksummed REGISTERED
# row), then its state alone is set to FREE. This node mounts:
#   1. it does not take row 0 -- the row is byte-identical afterwards;
#   2. the read named the row as damaged.
#
# DISCRIMINATION: node_free_any=1 (FREE believed of any row, as before):
# the mount registers onto row 0 and rewrites it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/node_free_any ] || { skip "node_free_any is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"
SBPOKE="$(ct_helper sb_poke)"
MNT="$(ct_mnt nrf)"
ct_track mnt "$MNT"
ct_param_set node_free_any 0
export CETRAFS_PEER_PROBE_SECS=3
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <free_any 0|1> -> RES
round() {
    local img dev nts before after mark rc
    img="$(ct_image 560 "nrf$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    nts="$("$SBPOKE" "$dev" | sed -n 's/^node_table_start=//p')"
    [ -n "$nts" ] || { fail "setup: no node_table_start"; ct_exit; }
    "$NODE_POKE" "$dev" 0 1 aa "$(date +%s)" >/dev/null
    "$NODE_POKE" "$dev" 0 --flip-free >/dev/null
    before="$(dd if="$dev" bs=4096 skip="$nts" count=1 status=none | sha256sum | cut -d' ' -f1)"
    echo "$2" >/sys/module/cetrafs/parameters/node_free_any
    mark="$(dmesg_mark)"
    rc=0
    ct_mount "$dev" "$MNT" 2>/dev/null || rc=$?
    if mountpoint -q "$MNT"; then ct_umount "$MNT"; fi
    echo 0 >/sys/module/cetrafs/parameters/node_free_any
    after="$(dd if="$dev" bs=4096 skip="$nts" count=1 status=none | sha256sum | cut -d' ' -f1)"
    RES="mount_rc=$rc same=$([ "$before" = "$after" ] && echo 1 || echo 0)"
    RES="$RES named=$(dmesg_since "$mark" | grep -c 'node row 0 failed its checksum' || true)"
}

round c 1
C="$RES"
log "control (FREE believed of any row): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get same "$R")" = 1 ] && pass "1: row 0 was not taken -- byte-identical after the mount" || fail "1: $R"
[ "$(get named "$R")" -ge 1 ] && pass "2: the read named row 0 as damaged" || fail "2: $R"
[ "$(get same "$C")" = 0 ] && pass "control: believing FREE, the mount registered onto the live row" ||
    fail "control: row 0 was not taken without the fix -- the suite does not arrange what it says: $C"
ct_exit
