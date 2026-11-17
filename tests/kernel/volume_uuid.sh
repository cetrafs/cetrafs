#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# one volume has one identity on every node: s_uuid and f_fsid come from the volume uuid, not the device number
#
# mkfs writes a random uuid into the superblock and nothing published it:
# s_uuid stayed empty and statfs built f_fsid from the local device
# number, so one volume reported a different identity on every node, and
# neither procfs nor fsck showed the uuid (audit F-56).
#
# One host stands in for two nodes: two loop devices over one image have
# different device numbers and the same volume.
#   1. f_fsid is the same through both devices;
#   2. FS_IOC_GETFSUUID, procfs info and fsck all give the uuid mkfs wrote
#      (the superblock's bytes, read off the image);
#   3. a second volume reports a different f_fsid.
#
# DISCRIMINATION: with statfs's f_fsid from the device number (the code
# before F-56), 1 fails -- the two loop devices differ (run by hand,
# 2026-11-17); with no super_set_uuid() at mount, 2's ioctl fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IMG="$(ct_image 560 vuuid)"
IMG2="$(ct_image 560 vuuid2)"
DEV1="$(ct_loop "$IMG")"
DEV2="$(ct_loop "$IMG")"
DEV3="$(ct_loop "$IMG2")"
MNT="$(ct_mnt vuuid)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV1" >/dev/null
ct_mkfs_small "$DEV3" >/dev/null
[ "$(stat -c %t:%T "$DEV1")" != "$(stat -c %t:%T "$DEV2")" ] || { fail "setup: the two loop devices share a number"; ct_exit; }

# The uuid mkfs wrote: the superblock bytes, read off the image.
SBPOKE="$(ct_helper sb_poke)"
RAW="$("$SBPOKE" "$IMG" | sed -n 's/^uuid=//p')" # the 16 bytes in on-disk order
UUID="$(python3 -c 'import sys, uuid; print(uuid.UUID(hex=sys.argv[1]))' "$RAW")"
[ "$UUID" != 00000000-0000-0000-0000-000000000000 ] || { fail "setup: mkfs wrote no uuid"; ct_exit; }
FSCK="$(ct_fsck "$DEV1" 2>/dev/null | sed -n 's/^  volume uuid: //p')"
[ "$FSCK" = "$UUID" ] && pass "2: fsck prints the volume uuid ($UUID)" || fail "2: fsck prints '$FSCK', the superblock holds $UUID"

# <dev> -> "fsid=<hex> uuid=<ioctl uuid or ERR> proc=<procfs uuid>"
look() {
    ct_mount "$1" "$MNT"
    local fsid ioc proc
    fsid="$(stat -f -c %i "$MNT")"
    ioc="$(python3 - "$MNT" <<'PY'
import fcntl, os, sys, uuid
fd = os.open(sys.argv[1], os.O_RDONLY)
buf = bytearray(17)
try:
    fcntl.ioctl(fd, 0x80111500, buf)  # FS_IOC_GETFSUUID: struct fsuuid2 {u8 len; u8 uuid[16]}
    print(str(uuid.UUID(bytes=bytes(buf[1:1 + buf[0]]))) if buf[0] == 16 else "ERR-len%d" % buf[0])
except OSError as e:
    print("ERR-%d" % e.errno)
PY
)"
    proc="$(sed -n 's/^volume_uuid: //p' "$(ct_procdir "$1")/info")"
    ct_umount "$MNT"
    echo "fsid=$fsid uuid=$ioc proc=$proc"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

A="$(look "$DEV1")"
B="$(look "$DEV2")"
C="$(look "$DEV3")"
log "superblock: $UUID"
log "loop A: $A"
log "loop B: $B"
log "other volume: $C"

[ "$(get fsid "$A")" = "$(get fsid "$B")" ] && [ "$(get fsid "$A")" != 0 ] &&
    pass "1: one volume through two devices reports one f_fsid ($(get fsid "$A"))" ||
    fail "1: one volume reports f_fsid $(get fsid "$A") and $(get fsid "$B")"
[ "$(get uuid "$A")" = "$UUID" ] && [ "$(get uuid "$B")" = "$UUID" ] &&
    pass "2: FS_IOC_GETFSUUID gives the superblock's uuid" ||
    fail "2: FS_IOC_GETFSUUID gives $(get uuid "$A") / $(get uuid "$B"), the superblock holds $UUID"
[ "$(get proc "$A")" = "$UUID" ] && pass "2: procfs info shows it" || fail "2: procfs volume_uuid is '$(get proc "$A")', the superblock holds $UUID"
[ "$(get fsid "$C")" != "$(get fsid "$A")" ] && [ "$(get uuid "$C")" != "$UUID" ] &&
    pass "3: another volume has another identity" || fail "3: another volume reports the same identity ($C)"
ct_exit
