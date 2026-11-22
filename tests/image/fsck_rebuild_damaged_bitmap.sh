#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a descriptor rebuilt over a damaged data bitmap counts its blocks as in use
#
# fsck -r rebuilds a Block Group descriptor that fails its checksum from
# the group's header, counting what is in use from its data bitmap. It
# counted the bits as they read, sector checksums ignored -- so a
# damaged bitmap reading zeros rebuilt a group holding data as EMPTY:
# into the pool, or (on a device that discards) flagged for a hand-back
# discard that UNMAPs every block of it (audit 2026-11-22 N-172). Every
# other path takes a bit in a failing sector as in use (class 45); the
# rebuild now does too.
#
# Staged on an image (nothing mounted): BG1's bitmap filled (the stand-in
# for a group holding data), then every block of that bitmap zeroed --
# each sector now fails its checksum and reads free -- and BG1's
# descriptor damaged. fsck -r must rebuild it with every block in use
# and no discard pending, and a following fsck must be clean.
#
# DISCRIMINATION: the control, in-suite --
# CETRAFS_FSCK_TEST_REBUILD_TRUST_BAD_SECTOR=1, the old count: BG1
# rebuilt with 0 blocks in use (and discard pending: a loop device takes
# discards).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
POKE="$(ct_helper csum_poke)"
BG_POKE="$(ct_helper bg_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 rbdb)"
DEV="$(ct_loop "$IMG")"

# round <knob 0|1> -> the "rebuilt the descriptor of BG1" line, or "none"
round() {
    local d start bmap cnt nb out
    ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    d="$("$BG_POKE" "$DEV" 1 --dump)"
    start="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d")"
    bmap="$(sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p' <<<"$d")"
    nb=$(($(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d") - bmap))
    "$BG_POKE" "$DEV" 1 0 fill-bitmap >/dev/null
    cnt="$("$BG_POKE" "$DEV" 1 --dump | sed -n 's/^free_data_blocks=\([0-9]*\).*/\1/p')"
    [ "$cnt" = 0 ] || { echo "setup: BG1 not filled (free $cnt)"; return; }
    dd if=/dev/zero of="$DEV" bs=4096 seek=$((start + bmap)) count="$nb" conv=notrunc,fsync status=none
    "$POKE" "$DEV" bg-desc 1 >/dev/null
    blockdev --flushbufs "$DEV"
    if [ "$1" = 1 ]; then
        out="$(CETRAFS_FSCK_TEST_REBUILD_TRUST_BAD_SECTOR=1 "$FSCK" -r "$DEV" 2>&1 || true)"
    else
        out="$("$FSCK" -r "$DEV" 2>&1 || true)"
    fi
    grep -m1 "rebuilt the descriptor of BG1" <<<"$out" || echo none
}

R="$(round 1)"
log "control: $R"
grep -q "owner ZG1, 0 block(s) in use" <<<"$R" &&
    pass "control: trusting the damaged sectors, BG1 was rebuilt as empty ($R)" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $R"

R="$(round 0)"
log "fixed: $R"
if grep -q "owner ZG1, [1-9][0-9]* block(s) in use" <<<"$R" && ! grep -q "discard pending" <<<"$R"; then
    pass "BG1 rebuilt with its damaged bitmap's blocks in use, no discard pending ($R)"
else
    fail "BG1 rebuilt as: $R"
fi
blockdev --flushbufs "$DEV"
"$FSCK" "$DEV" >/dev/null 2>&1 && pass "fsck clean after the repair" || fail "fsck still dirty after the repair"
ct_exit
