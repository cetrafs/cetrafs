#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a torn or corrupt dirent block is detected, not mis-parsed
#
# Lookups and readdir take no mutex by design, so a reader can catch a
# peer's in-flight 4 KiB dirent write torn. That is transient by
# construction -- the writer syncs under the namespace lock -- so the
# reader retries fresh a few times and only then fails loudly.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking the dirent-block tail checksum (v0x0007)"

# The retry side (a transient torn read converging on re-read) can't be
# forced deterministically on one kernel; what can be proven end to end
# is the DETECT side: a dirent block whose tail doesn't match must be
# rejected by fsck and refused (-EIO, after retries) by the kernel's
# dirent reads, instead of silently mis-parsing -- and restoring the
# block brings everything back.
G7_IMG="$(mktemp /tmp/cetrafs-g7-XXXXXX.img)"
truncate -s 560M "$G7_IMG"
G7_LOOPDEV="$(losetup --find --show "$G7_IMG")"
G7_MNT="$(mktemp -d /tmp/cetrafs-g7-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$G7_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
"$ROOT/userspace/fsck.cetra" "$G7_LOOPDEV" >/dev/null &&
    pass "dirent tail: fsck accepts mkfs's stamped root dirent block" ||
    fail "dirent tail: fsck rejected a fresh mkfs image"

# Root's dirent block LBA via its inode's extent 0.
G7_EXT_POKE="$(ct_helper pending_poke)"
G7_ROOT_LBA="$("$G7_EXT_POKE" "$G7_IMG" extent 1 | cut -d' ' -f1)"

# Save the tail, then corrupt one byte of it.
G7_TAIL_OFF=$((G7_ROOT_LBA * 4096 + 4088))
G7_SAVED="$(mktemp /tmp/cetrafs-g7tail-XXXXXX)"
dd if="$G7_IMG" of="$G7_SAVED" bs=1 skip="$G7_TAIL_OFF" count=8 status=none
printf '\x00\x00\x00\x00\x00\x00\x00\x00' | dd of="$G7_IMG" bs=1 seek="$G7_TAIL_OFF" conv=notrunc status=none

if "$ROOT/userspace/fsck.cetra" "$G7_LOOPDEV" >/dev/null 2>&1; then
    fail "dirent tail: fsck accepted a corrupted root dirent tail"
else
    pass "dirent tail: fsck detects a corrupted root dirent tail"
fi

mount -t cetrafs "$G7_LOOPDEV" "$G7_MNT"
require_cetrafs_mount "$G7_MNT"
if ls "$G7_MNT" >/dev/null 2>&1; then
    fail "dirent tail: kernel readdir accepted a corrupted dirent block"
else
    pass "dirent tail: kernel readdir refuses a corrupted dirent block (after retries) instead of mis-parsing"
fi
umount "$G7_MNT"

dd if="$G7_SAVED" of="$G7_IMG" bs=1 seek="$G7_TAIL_OFF" conv=notrunc status=none
mount -t cetrafs "$G7_LOOPDEV" "$G7_MNT"
require_cetrafs_mount "$G7_MNT"
ls "$G7_MNT" >/dev/null 2>&1 && pass "dirent tail: restoring the tail restores normal operation" ||
    fail "dirent tail: still broken after restoring the original tail"
umount "$G7_MNT"
rmdir "$G7_MNT"
losetup -d "$G7_LOOPDEV"
rm -f "$G7_IMG" "$G7_EXT_POKE" "$G7_SAVED"

ct_exit
