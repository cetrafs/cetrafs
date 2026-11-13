#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ct-timeout: 900
# a Block Group's length is refused past the format's 2^32-block ceiling, on a volume big enough to reach it
#
# bg_size_indexable.sh could only bound this: its mount-side half needed a
# volume over 16 TiB, and a 560 MiB image's Block Groups were refused for
# being larger than their data area, which is the wrong reason to be
# refused. On a nominally 17 TiB device (ct_huge_dev) the largest legal
# Block Group fits, so the ceiling can be the only thing decided.
#
# The kernel checks the superblock's bg_size_blocks against the ceiling
# before it multiplies it by the Block Group count (kmod/fs.c), with its
# own message. The assertion reads that message from dmesg: a refusal for
# any other reason would pass a bare "mount failed" check and prove
# nothing about the ceiling.
#
#  1. control: the largest legal Block Group (mkfs -b 16777215 MiB, just
#     under 2^32 blocks) mounts and works on this device.
#  2. the superblock claims 2^32 blocks for its Block Group: the mount is
#     refused, and dmesg says the group exceeds what can be indexed.
#
# DISCRIMINATION: the refusal in (2) must carry the ceiling's message. With
# the check removed (a build with the cap line taken out), the same
# superblock is refused, if at all, for a different reason, and this
# suite reports that as a failure.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SB_POKE="$(ct_helper sb_poke)"

DEV="$(ct_huge_dev 17 bgmax)"
if [ -z "$DEV" ]; then
    skip "device-mapper is unavailable; a Block Group past 16 TiB cannot be built here"
    ct_exit
fi
MNT="$(ct_mnt bgmax)"
ct_track mnt "$MNT"
CEIL=4294967295 # CETRAFS_MAX_BG_SIZE_BLOCKS: the largest count a u32 index holds

log "mkfs with the largest Block Group the format allows"
ct_mkfs "$DEV" -b 16777215 -z 1 -J 0 -N 1024 -M 4 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo ok >"$MNT/f" && sync && pass "1: control: the largest legal Block Group mounts and takes a write" ||
    fail "1: control: the largest legal Block Group does not work"
ct_umount "$MNT"

log "superblock claims one block past the ceiling for its Block Group"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "1b: the largest legal geometry fscks clean" ||
    fail "1b: the largest legal geometry is not clean"
"$SB_POKE" "$DEV" bg_size_blocks $((CEIL + 1)) >/dev/null 2>&1 ||
    { fail "setup: sb_poke cannot set bg_size_blocks past the ceiling"; ct_exit; }
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"
    fail "2: the kernel mounted a volume whose Block Group is past the ceiling"
else
    if dmesg_since "$MARK" | grep -q "exceeds the largest that can be indexed"; then
        pass "2: the mount is refused for the ceiling itself (the Block Group exceeds what can be indexed)"
    else
        fail "2: the mount was refused, but not by the ceiling check: $(dmesg_since "$MARK" | grep -m1 'cetrafs' || echo 'no message')"
    fi
fi

ct_exit
