#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a CAS region wider than the record's sectors must still publish the file domain
#
# The CAS region is the device's atomic unit. On a 512-byte-logical
# device the record block holds two of them and the inode's two domains
# line up with them: the namespace sector is region 0, the file sector is
# region 1. On a 4Kn device there is exactly ONE region -- the whole 4096
# byte block -- and the file sector stops being a region at all. It is a
# slice at CETRAFS_INODE_FD_OFF inside region 0.
#
# Every path derives its region count from cetrafs_cas_region_size() and
# follows: the data and inode bitmaps, the pending-free queue, the
# namespace CAS (region 0, and its mutator only ever touches the head of
# whatever image it is handed). The one that did not was
# cetrafs_cas_record_fd_seeded(), whose region index was the constant 1 --
# past the end of the block once a region is 4096 bytes, so the bounds
# check refused it and EVERY file-domain publish failed -EINVAL: fsync,
# fdatasync, writeback, close. Reported from a 4Kn iSCSI target, where it
# showed up as qemu's first flush after a write failing while the second,
# with nothing left dirty, appeared to succeed.
#
# Nothing in this project could see it. The test LUN is 512-byte logical
# and a loop device has no CAW at all, so the region is 512 either way and
# region 1 always exists. cas_region_force is what reaches the wide-region
# path from the harness; it is honoured only where there is no CAW, since
# with a real one the width is a property of the device.
#
# Discrimination: with the fix reverted -- cetrafs_cas_record_fd_seeded()
# always using region 1 -- the fsync below returns EINVAL and the first
# assertion fails. Verified that way before this suite was committed, on
# the loop harness here and against a real 4Kn iSCSI LUN.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 caswide)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt caswide)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"

# Before the mount, so every structure this volume builds is built under
# the wide region -- not just the ones touched after a switch.
ct_param_set cas_region_force 4096
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

MARK="$(dmesg_mark)"

# 1. The publish itself. fsync is the shortest path to it.
RC=0
python3 - "$MNT/f" <<'PY' || RC=$?
import os, sys
f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.write(f, b'A' * 4096)
try:
    os.fsync(f)
except OSError as e:
    print("fsync: %s" % e)
    os._exit(1)
os.close(f)
PY
[ "$RC" = 0 ] &&
    pass "fsync publishes the file domain with a region wider than the record's sectors" ||
    fail "fsync failed with a 4096-byte CAS region -- the file-domain publish has no region of its own there"

# 2. Returning 0 is not the same as having published. The size and the
# extents live in the file domain, so a publish that silently did nothing
# leaves them behind on disk -- visible only after the cache is gone.
dd if=/dev/urandom of="$MNT/data" bs=4096 count=256 conv=fsync status=none ||
    fail "writing 1 MiB with fsync failed outright under a wide CAS region"
SUM="$(md5sum < "$MNT/data")"
SIZE="$(stat -c '%s' "$MNT/data")"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c '%s' "$MNT/data")" = "$SIZE" ] ||
    fail "size lost across the remount: $SIZE -> $(stat -c '%s' "$MNT/data") -- the file domain never reached the device"
[ "$(md5sum < "$MNT/data")" = "$SUM" ] &&
    pass "size and extents survive a remount, so the publish really reached the device" ||
    fail "content changed across the remount -- the extents were not published"

# 3. The failure mode was loud in dmesg before it was anything else.
! dmesg_since "$MARK" | grep -qE 'staged file-sector publish failed|failed to persist inode state' &&
    pass "no file-domain publish failure logged" ||
    fail "a file-domain publish failed: $(dmesg_since "$MARK" | grep -E 'publish failed|persist inode state' | tail -2)"

# 4. The namespace half must still work alongside it: with one region the
# two domains share an atomic unit, so a namespace operation and a file
# publish now contend instead of composing.
mkdir "$MNT/d" && touch "$MNT/d/a" "$MNT/d/b" && ln "$MNT/d/a" "$MNT/d/c"
dd if=/dev/zero of="$MNT/d/a" bs=4096 count=16 conv=fsync status=none
[ "$(stat -c '%h' "$MNT/d/a")" = 2 ] &&
    pass "namespace updates still compose with file-domain publishes in one region" ||
    fail "nlink is $(stat -c '%h' "$MNT/d/a"), expected 2 -- a namespace change was lost to a file publish"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after running with a wide CAS region"
pass "fsck clean"

ct_exit
