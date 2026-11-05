#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an open applies the file as it is when its claim lands, not as it was read before
#
# A write-open reads the record, then claims the file lock by a CAS of
# the record's namespace sector, then refreshes the in-core inode from
# what it read. The CAS compares sector 0 only, so the FILE sector it
# refreshed from was the one read BEFORE the claim -- and a peer's whole
# session (claim, write, publish, release) can land in between and leave
# sector 0 exactly as it was. The open then kept a size and tree the
# peer had moved on: its reads stop short of the peer's data, and its
# writes publish the old size over it (audit L28).
#
# Staged: lock_claim_gap_ms holds the open between its read and its
# claim; the peer's finished session is poked onto the device then -- a
# larger size, stamped as a peer's publish, the lock fields untouched.
#
# DISCRIMINATION: without the re-read the open sees the old size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/lock_claim_gap_ms ] || { skip "lock_claim_gap_ms is missing"; ct_exit; }
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 openstale)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt openstale)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 2))
dd if=/dev/zero of="$MNT/f" bs=4096 count=1 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
sync

ct_param_set lock_claim_gap_ms 3000
MARK="$(dmesg_mark)"
RES="$(ct_tmp openstale-res)"
python3 - "$MNT/f" "$RES" <<'PY' &
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
open(sys.argv[2], "w").write("%d\n" % os.fstat(fd).st_size)
os.close(fd)
PY
P=$!
wait_for 5 'dmesg_since "'"$MARK"'" | grep -q "open stalled"' || { fail "setup: the open never stalled"; ct_exit; }
"$POKE" "$IMG" setsize "$INO" 16384 2>/dev/null
"$POKE" "$IMG" peerseq "$INO" "$PEER" 2>/dev/null
wait "$P" || fail "the write-open failed"
ct_param_set lock_claim_gap_ms 0
SZ="$(cat "$RES")"
log "size seen by the open: $SZ (the peer's session left 16384)"
[ "$SZ" = 16384 ] && pass "the open applied the file as it was when its claim landed" ||
    fail "the open kept the size it read before its claim ($SZ), under a peer's newer publish"
ct_umount "$MNT"
ct_exit
