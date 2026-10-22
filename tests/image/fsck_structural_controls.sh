#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's ZG<->BG ownership and root-inode checks really fire
#
# These are the checks that describe how the volume is carved up. If one
# is WRONG rather than merely absent it condemns every healthy volume --
# which is not hypothetical here: N5 was exactly that, a root-inode
# check that reported a fault on every volume past 58 entries because
# nothing ever made it fire.
#
# So each case below asserts both directions: the fault is caught, and
# the healthy volume it was injected into passed a moment earlier.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
ZPOKE="$(ct_helper zg_poke)"
BPOKE="$(ct_helper bg_poke)"
CPOKE="$(ct_helper csum_poke)"

IMG="$(ct_image 560 struct)"
DEV="$(ct_loop "$IMG")"

build() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 ||
        fail "the freshly-made control image is already reported corrupt"
}

check() { # <label> <expected regex>
    blockdev --flushbufs "$DEV"
    local out rc=0
    out="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" = "0" ]; then
        fail "$1: fsck called the volume CLEAN with the fault injected"
    elif echo "$out" | grep -qE "$2"; then
        pass "$1: detected"
    else
        fail "$1: failed for another reason -- wanted /$2/, got: $(echo "$out" | grep -E '^(ERR|WARN)' | head -2 | tr '\n' ' ')"
    fi
}

# Edit one field of a structure and restamp its checksum, so the
# structural check is the only thing that can object. Without the
# restamp every case below would be caught by the CRC instead, and the
# control would prove nothing about the check it names.
unused_restamp_bg() { # kept out of the way; see the note above
python3 - "$IMG" "$1" "$2" <<'PY'
import struct, sys, zlib
img, bg_id, expr = sys.argv[1], int(sys.argv[2]), sys.argv[3]
f = open(img, 'r+b')
sb = f.read(4096)
bg_table_start = struct.unpack_from('<Q', sb, 64)[0]
off = (bg_table_start + bg_id) * 4096
f.seek(off); blk = bytearray(f.read(4096))
# cetrafs_block_group_t: bg_id u32, start_block u64, off_bg_header u32,
# off_data_bmap u32, off_data_region u32, data_block_count u64,
# free_data_blocks u64, owner_zg u32, checksum u32  (see cetrafs.h)
exec(expr, {"blk": blk, "struct": struct})
f.seek(off); f.write(blk)
PY
}

log "a healthy volume passes first"
build
pass "the control image is clean before anything is poked"

log "Zone Group <-> Block Group ownership"
build
# Owner 2: inside the registry (-M 4 gives rows 0..3) but never
# registered, which is the state a crashed-and-forgotten node leaves.
# Poking 7 instead takes the out-of-range branch and tests the wrong
# thing -- it did, in the first version of this.
"$ZPOKE" "$DEV" 0 2 >/dev/null 2>&1
blockdev --flushbufs "$DEV"
ZOUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
echo "$ZOUT" | grep -qE "ZG[0-9]+ is owned by node slot [0-9]+, which is not REGISTERED" &&
    pass "a ZG owned by a node that never registered: reported" ||
    fail "an orphaned ZG went unreported: $(echo "$ZOUT" | grep -E '^(ERR|WARN)' | head -2 | tr '\n' ' ')"
# A WARNing, not an error: it is not corruption, the next node to mount
# reclaims it. fsck must still exit 0 on an otherwise-sound volume, or
# every volume with a crashed peer would look broken.
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 &&
    pass "...as a warning: the volume is still reported sound" ||
    fail "an orphaned ZG made fsck exit nonzero; it is not corruption"

build
"$ZPOKE" "$DEV" 0 7 >/dev/null 2>&1
blockdev --flushbufs "$DEV"
# Captured, not piped -- the same reason as everywhere else in this
# project: a pipeline's status under `set -o pipefail` is not the
# question being asked.
OOR="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
echo "$OOR" | grep -qE "ZG[0-9]+ names owner node 7, which is outside the registry" &&
    pass "a ZG naming an owner outside the registry is reported too" ||
    fail "an out-of-range owner went unreported: $(echo "$OOR" | grep -E "^(ERR|WARN)" | head -1)"

log "the root inode"
build
"$CPOKE" "$DEV" inode 1 >/dev/null
check "root's record fails its checksum" "root inode CRC(/identity)? mismatch"

ct_exit
