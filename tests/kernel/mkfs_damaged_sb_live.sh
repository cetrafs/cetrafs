#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs -f refuses a damaged superblock while a node still beats in the registry it places
#
# mkfs -f formats over a superblock that does not verify -- no node can
# mount one, and refusing left a damaged volume impossible to reformat.
# But a stray write into block 0 breaks the checksum of a LIVE cluster's
# superblock and nothing else; its nodes read it at mount and keep
# running, and mkfs then formatted under them with no live-node check at
# all (audit 2026-11-15 B-16). The registry is still where the damaged
# superblock places it, and every row verifies itself: mkfs now watches
# it there, read-only, and refuses a beating row.
#
#   D: block 0's checksum broken, a node beating in its registry: mkfs -f
#      refuses; block 0 is left as it was.
#   E: the same with nobody beating: mkfs -f formats it, and it mounts.
#
# DISCRIMINATION: CETRAFS_TEST_UNVERIFIED_NO_PROBE=1 (no probe): D formats
# under the beating node.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
export CETRAFS_PEER_PROBE_SECS=4
NPOKE="$(ct_helper node_poke)"
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 mkfsdmg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mkfsdmg)"
ct_track mnt "$MNT"
MKFS() { "$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f; }
b0() { dd if="$IMG" bs=4096 count=1 status=none | sha256sum | cut -d' ' -f1; }
beat() { ( for _ in $(seq 1 90); do NODE_POKE_SB="$IMG.sb" "$NPOKE" "$IMG" "$1" --beat >/dev/null 2>&1 || true; sleep 0.5; done ) & BEATER=$!; }
stop_beat() { kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true; }
ct_track file "$IMG.sb"

# A fresh volume (another -N than MKFS's, so a reformat is visible), its
# good superblock saved for the beater, then block 0's uuid bit-flipped:
# magic and placement intact, checksum broken.
damaged() {
    ct_mkfs_small "$DEV" -N 2048 >/dev/null
    blockdev --flushbufs "$DEV"
    dd if="$IMG" of="$IMG.sb" bs=4096 count=1 status=none
    python3 -I - "$IMG" "$("$SBPOKE" "$IMG" | sed -n 's/^uuid=//p')" <<'PY'
import sys
img, uuid = sys.argv[1], bytes.fromhex(sys.argv[2])
with open(img, "r+b") as f:
    b0 = bytearray(f.read(4096))
    i = b0.find(uuid)
    assert i > 0
    b0[i] ^= 0x01
    f.seek(0); f.write(b0); f.flush()
PY
    blockdev --flushbufs "$DEV"
    OLD="$(b0)"
}
# <tag> <no_probe 0|1> -> RES
dround() {
    local out rc=0
    damaged
    "$NPOKE" "$IMG" 1 1 bb "$(date +%s)" >/dev/null
    beat 1
    out="$(CETRAFS_TEST_UNVERIFIED_NO_PROBE="$2" MKFS 2>&1)" || rc=$?
    stop_beat
    blockdev --flushbufs "$DEV"
    RES="rc=$rc same=$([ "$(b0)" = "$OLD" ] && echo 1 || echo 0) refused=$(grep -c 'still heartbeating' <<<"$out" || true)"
}

dround c 1
C="$RES"
log "D control (no probe): $C"
dround f 0
R="$RES"
log "D: $R"
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
[ "$(get rc "$R")" != 0 ] && [ "$(get refused "$R")" -ge 1 ] && [ "$(get same "$R")" = 1 ] &&
    pass "D: mkfs -f refused the damaged superblock of a volume a node still beats on; block 0 untouched" ||
    fail "D: $R"
[ "$(get rc "$C")" = 0 ] && [ "$(get same "$C")" = 0 ] &&
    pass "control: without the probe mkfs formatted under the beating node" ||
    fail "control: without the probe mkfs did not format ($C) -- the suite cannot see the probe"

# --- E: nobody beating
damaged
OUT="$(MKFS 2>&1)" && RC=0 || RC=$?
[ "$RC" = 0 ] && ct_mount "$DEV" "$MNT" && require_cetrafs_mount "$MNT" && ct_umount "$MNT" &&
    pass "E: with no node beating, mkfs -f formats the damaged volume and it mounts" ||
    fail "E: rc=$RC: $(tail -2 <<<"$OUT")"
ct_exit
