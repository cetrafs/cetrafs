#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Block Group may not be larger than its blocks can be indexed
#
# A BG's blocks are tracked in core by the kernel's bitmap API, whose
# indices and lengths are `unsigned int`. The scrub's reference set
# marks referenced blocks with bitmap_set(ref, lo - data_start, hi - lo)
# and cast both down. mkfs allowed up to 1 PiB per group -- 2^38 blocks,
# 64 times past the point where the index stops meaning anything -- and
# past it the scrub marks the WRONG blocks as referenced, which is the
# one mistake that makes it free live ones.
#
# Capped where the arithmetic stops working rather than where it stops
# being plausible, and enforced twice: mkfs refuses the geometry, and
# the kernel refuses the image. Both are needed, because the superblock
# lives on a shared device and nothing stops something else writing it.
#
# Discrimination: remove the cap and the mkfs assertion stops refusing
# -- verified. The mount-side half cannot be discriminated on an image
# a test can afford; see the note on it below.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SB_POKE="$(ct_helper sb_poke)"

# The cap, read from the header rather than written out -- the number is
# a property of the kernel's bitmap API, not of this test.
MAXBLK="$(sed -n 's/^#define CETRAFS_MAX_BG_SIZE_BLOCKS  *//p' "$ROOT/include/cetrafs.h" | head -1 |
    awk '{gsub(/ULL/,""); print strtonum($1)}')"
[ "${MAXBLK:-0}" -gt 0 ] || fail "could not read CETRAFS_MAX_BG_SIZE_BLOCKS"
MAXMIB=$((MAXBLK / 256))   # blocks * 4096 / 1048576
log "cap: $MAXBLK blocks per Block Group ($MAXMIB MiB)"

IMG="$(ct_image 560 bgsize)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgsize)"

# 1. mkfs refuses a geometry whose groups cannot be indexed.
OUT="$("$ROOT/userspace/mkfs.cetra" "$DEV" -b $((MAXMIB + 1)) -f 2>&1 || true)"
echo "$OUT" | grep -qi "too large" &&
    pass "mkfs refuses a Block Group larger than can be indexed" ||
    fail "mkfs accepted -b $((MAXMIB + 1)) MiB: $(echo "$OUT" | head -2)"

# 2. The kernel refuses an image that claims one anyway -- mkfs is not
# the only thing that can write a superblock on a shared device.
#
# NOTE ON WHAT THIS PROVES. On an image this size the assertion holds
# with the new check REMOVED, because an enormous bg_size also fails
# the older "the data area is too small for N groups" test, which
# catches it first. The two only separate on a volume whose data area
# is genuinely larger than 2^32 blocks -- over 16 TiB -- where a group
# can be unindexable and still fit. So this is a bound, not a
# discriminating assertion, and the mount-side guard is verified by
# reading rather than by running. Reproducing it needs a >16 TiB
# volume, which is on the list with the other things no machine here
# can do.
ct_mkfs_small "$DEV" >/dev/null
"$SB_POKE" "$DEV" bg_size_blocks $((MAXBLK + 1)) >/dev/null 2>&1 ||
    skip "sb_poke cannot set bg_size_blocks; the mount half is unverified"

if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "the kernel mounted a volume whose Block Groups cannot be indexed"
else
    pass "the kernel refuses an image claiming an unindexable Block Group size (bound, not a discriminator -- see above)"
fi

# 3. A legal geometry still works -- the cap must not have swallowed the
# ordinary case.
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo ok > "$MNT/f"
sync
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults on an ordinary geometry"
pass "an ordinary geometry still mounts and checks clean"

ct_exit
