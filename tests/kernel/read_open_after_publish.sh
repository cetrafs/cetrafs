#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a read-open re-reads the record once it is published as an opener
#
# The first local opener's open-boundary refresh applied a record read
# BEFORE this node was published into the file's opener set. A peer that
# wrote and closed in that one-round-trip gap saw no opener, so nothing
# told it to flag this node's view, and the size this fd keeps is the
# pre-write one for its whole life (audit 2026-11-14 L-F4). The record is
# now read again after the publish and applied under the same gate.
#
# Setup: file a of 8 KiB, unmounted. Mounted again, the read-open is held
# in its presence stall (open_presence_stall_ms). During the stall a
# PEER (a poke, with file_seq stamped by node 7) extends the file to
# 16 KiB on the device. The open then publishes, and must see 16 KiB.
#   1. fixed: fstat of the read-open's fd reports 16384;
#   2. control (lock_open_reapply_off): the record read before the publish
#      is kept, and fstat reports 8192.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in open_presence_stall_ms lock_open_reapply_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
POKE="$(ct_helper inode_block_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt rop)"
ct_track mnt "$MNT"
ct_param_set open_presence_stall_ms 0
ct_param_set lock_open_reapply_off 0
SZOPEN="$(ct_tmp rop-open.py)"
cat >"$SZOPEN" <<'PY'
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY)
    print(os.fstat(fd).st_size, flush=True)
    os.close(fd)
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY

# <reapply_off 0|1> -> "<size seen by the read-open>"
probe() {
    local img dev ino
    img="$(ct_image 560 "rop$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/zero of="$MNT/a" bs=4096 count=2 conv=fsync status=none
    ino="$(stat -c %i "$MNT/a")"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    echo "$1" >$P/lock_open_reapply_off
    ct_param_set open_presence_stall_ms 2000
    ( sleep 0.8
      "$POKE" "$img" peerseq "$ino" 7 >/dev/null 2>&1
      "$POKE" "$img" setsize "$ino" 16384 >/dev/null 2>&1 ) &
    local bg=$! got
    got="$(python3 "$SZOPEN" "$MNT/a")"
    wait "$bg" || true
    ct_param_set open_presence_stall_ms 0
    echo 0 >$P/lock_open_reapply_off
    ct_umount "$MNT"
    echo "$got"
}

S="$(probe 0)"
log "fixed: the read-open saw size $S"
[ "$S" = 16384 ] && pass "1: a read-open re-reads the record after publishing and sees the peer's size" ||
    fail "1: the read-open kept size $S, but the device holds 16384"

C="$(probe 1)"
log "control (no re-read): the read-open saw size $C"
[ "$C" = 8192 ] && pass "control: without the re-read the open keeps the pre-publish size -- the suite discriminates" ||
    fail "control: the open saw $C without the re-read -- the suite cannot tell"
ct_exit
