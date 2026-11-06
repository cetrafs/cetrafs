#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a read-only mount that is the last holder of a file deleted elsewhere frees nothing
#
# Evict is where a file is destroyed: its number and blocks go back to
# the allocator. On a read-only mount that was the last holder of a file
# a peer deleted, evict freed both -- bitmap writes, and appends to the
# owner's pending-free queue -- including on a mount accepted read-only
# because this build must not write the volume (unknown RO_COMPAT; audit
# 2026-11-06 L15). A read-only mount writes nothing; a writer's scrub
# reclaims the file.
#
# Nothing on a read-only mount drops an in-core count to 0 today -- the
# unlink and writeback paths that do never run there -- so the free was
# one new path away. Staged with evict_drop_nlink_ino standing in for
# it: the record on the device is what a peer's unlink leaves (name
# gone, nlink 0), a read-only mount holds f open, and the fd closes with
# the in-core count dropped. The inode bitmap and f's data-bitmap bit
# must not change.
#
# DISCRIMINATION: with evict freeing on a read-only mount, both bits
# clear.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/evict_drop_nlink_ino ] || { skip "evict_drop_nlink_ino is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper corrupt_poke)"
SBPOKE="$(ct_helper sb_poke)"
MAP="$(ct_helper bg_map)"
EPOKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 roevict)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt roevict)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/f" bs=4096 count=4 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
LBA="$("$EPOKE" "$IMG" extent "$INO" | cut -d' ' -f1)"
[ -n "$LBA" ] && [ "$LBA" -gt 0 ] || { fail "setup: no data block for f"; ct_exit; }
IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
# The data-bitmap byte holding f's first block.
DOFF="$(python3 - "$IMG" "$LBA" "$("$MAP" "$DEV")" <<'PY'
import os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY); lba = int(sys.argv[2])
for line in sys.argv[3].splitlines():
    f = line.split()
    if f[0] != "bg": continue
    start = int(f[3].split("=")[1])
    length, off_bmap, off_data = struct.unpack_from("<QII", os.pread(fd, 24, start * 4096), 8)
    if start + off_data <= lba < start + length:
        bit = lba - start - off_data
        print((start + off_bmap) * 4096 + bit // 8); break
PY
)"
[ -n "$DOFF" ] || { fail "setup: f's block is in no Block Group"; ct_exit; }
bits() { { dd if="$IMG" bs=4096 skip="$IBM" count=1 status=none; dd if="$IMG" bs=1 skip="$DOFF" count=1 status=none; } | md5sum; }

mount -t cetrafs -o ro "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
FIFO="$(ct_tmp roevict-fifo)"; rm -f "$FIFO"; mkfifo "$FIFO"
python3 - "$MNT/f" "$FIFO" <<'PY' &
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
open(sys.argv[2]).read()   # hold it until the record says deleted
os.fstat(fd)
os.close(fd)
PY
PID=$!
sleep 1
B0="$(bits)"
ROOT_INO="$(stat -c %i "$MNT")"
"$CPOKE" "$IMG" dirent "$ROOT_INO" f >/dev/null # what a peer's unlink leaves: the name gone...
"$IPOKE" "$IMG" nlink "$INO" 0 >/dev/null      # ...and the count at 0
sync
MARK="$(dmesg_mark)"
ct_param_set evict_drop_nlink_ino "$INO"
echo go >"$FIFO"
wait "$PID" || true
echo 2 >/proc/sys/vm/drop_caches # evict the now-unreferenced inode
sleep 1
B1="$(bits)"
LEFT="$(cat /sys/module/cetrafs/parameters/evict_drop_nlink_ino)"
umount "$MNT"
[ "$LEFT" = 0 ] || { fail "setup: the read-only mount never evicted ino $INO"; ct_exit; }
[ "$B1" = "$B0" ] && pass "the read-only mount's evict left the inode and data bitmaps untouched" ||
    fail "the read-only mount freed bits at evict -- it wrote the volume"
dmesg_since "$MARK" | grep -q "evict_inode: ino=$INO deleted elsewhere: read-only mount, freeing nothing" &&
    pass "evict said it freed nothing because the mount is read-only" ||
    fail "evict did not decide 'read-only: free nothing' itself"
ct_exit
