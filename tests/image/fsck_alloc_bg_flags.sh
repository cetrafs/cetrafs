#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's allocator respects a Block Group's discard flags
#
# A Block Group marked DISCARD_PENDING has an UNMAP outstanding that may
# still land on its blocks: the kernel refuses to hand such a group out,
# because a block given to data there can lose the data to the discard.
# A group marked DISCARDED is trimmed and empty, and the kernel's claim
# clears the mark before it hands out a block. fsck's allocator, which
# takes the first free block of any group when it has to name /lost+found,
# looked at neither flag: it wrote into a group with an UNMAP outstanding,
# and it left a group holding data marked as discarded (audit 2026-11-14
# U7).
#
# Two volumes, two Block Groups each. The control is a volume with no
# flags: fsck -r must put /lost+found in the first group, which is what
# the rest measures against. Then group 0 is pending: /lost+found must go
# to group 1. Then group 0 is marked discarded: /lost+found may go there,
# and the mark must be gone afterwards.
#
# DISCRIMINATION (measured on the unfixed code): the pending case puts
# /lost+found in group 0, and the discarded case leaves the mark set.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
OPOKE="$(ct_helper orphan_poke)"
IPOKE="$(ct_helper inode_block_poke)"
SBPOKE="$(ct_helper sb_poke)"
BGPOKE="$(ct_helper bgflags_poke)"
DISCARDED=1
PENDING=2

# A fresh two-group volume with one orphan that fsck -r must link into
# /lost+found; prints "<regions_start> <bg_size> <lost+found block>".
# The image is $IMG, the device $DEV; the caller sets the flags first.
run_case() {
    local dump rs bs out lf phys
    ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    dump="$("$SBPOKE" "$DEV")"
    rs="$(sed -n 's/^bg_regions_start=//p' <<<"$dump")"
    bs="$(sed -n 's/^bg_size_blocks=//p' <<<"$dump")"
    [ "$(sed -n 's/^block_group_count=//p' <<<"$dump")" -ge 2 ] || { echo "SETUP"; return; }
    "$OPOKE" "$IMG" 3 1 0 >/dev/null && "$IPOKE" "$IMG" setsize 3 4096 >/dev/null || { echo "SETUP"; return; }
    if [ -n "${PRE_FLAGS:-}" ]; then "$BGPOKE" "$IMG" 0 "$PRE_FLAGS" >/dev/null || { echo "SETUP"; return; }; fi
    blockdev --flushbufs "$DEV"
    out="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
    blockdev --flushbufs "$DEV"
    lf="$(sed -n 's/.*created \/lost+found (inode \([0-9]*\)).*/\1/p' <<<"$out" | head -1)"
    phys="$("$IPOKE" "$IMG" extents "${lf:-0}" 2>/dev/null | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
    echo "$rs $bs ${phys:-none}"
}

# Is block $2 inside Block Group 0's span (regions_start .. + bg_size)?
in_bg0() { [ "$2" -ge "$(cut -d' ' -f1 <<<"$1")" ] && [ "$2" -lt $(($(cut -d' ' -f1 <<<"$1") + $(cut -d' ' -f2 <<<"$1"))) ]; }

IMG="$(ct_image 1200 fsckbgflags)"
DEV="$(ct_loop "$IMG")"

PRE_FLAGS="" ; RES="$(run_case)"
[ "$RES" = SETUP ] && { fail "setup: the control volume does not give /lost+found a block"; ct_exit; }
in_bg0 "$RES" "$(cut -d' ' -f3 <<<"$RES")" && pass "control: with no flags, /lost+found takes a block of group 0" ||
    fail "control: /lost+found is not in group 0 ($RES)"
losetup -d "$DEV"

IMG="$(ct_image 1200 fsckbgflags)"
DEV="$(ct_loop "$IMG")"
PRE_FLAGS="$PENDING" ; RES="$(run_case)"
[ "$RES" = SETUP ] && { fail "setup: the pending-group volume does not give /lost+found a block"; ct_exit; }
P="$(cut -d' ' -f3 <<<"$RES")"
[ "$P" != none ] && ! in_bg0 "$RES" "$P" && pass "a group with an UNMAP outstanding took no block: /lost+found is at $P, outside group 0" ||
    fail "/lost+found was given a block of a group with an UNMAP outstanding ($RES)"
losetup -d "$DEV"

IMG="$(ct_image 1200 fsckbgflags)"
DEV="$(ct_loop "$IMG")"
PRE_FLAGS="$DISCARDED" ; RES="$(run_case)"
[ "$RES" = SETUP ] && { fail "setup: the discarded-group volume does not give /lost+found a block"; ct_exit; }
P="$(cut -d' ' -f3 <<<"$RES")"
in_bg0 "$RES" "$P" && pass "/lost+found took a block of the discarded group (it is empty and trimmed)" ||
    fail "/lost+found did not use group 0 ($RES): the discarded case measured nothing"
FL="$("$BGPOKE" "$IMG" 0)"
[ "$FL" = "flags=0x0000" ] && pass "and the group no longer says it was discarded ($FL)" ||
    fail "group 0 holds data and still says it was discarded ($FL)"
losetup -d "$DEV"
ct_exit
