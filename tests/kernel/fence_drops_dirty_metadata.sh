#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a self-fenced node never writes back the metadata it had dirty when it was fenced
#
# A peer that declares this node dead bumps its fence epoch and takes its
# Zone Groups, then allocates out of their bitmaps. The fence stopped this
# node's own writes at every entry point and its file data at writepages
# -- but metadata it had ALREADY dirtied (allocation bitmaps set with
# sync=false, tree blocks) sat in the block device's cache, and ordinary
# writeback put those images back on the device over the peer's: every
# block the peer had allocated in such a bitmap block read FREE again, to
# be handed out a second time.
#
# The peer is played on the device: bump this node's fence epoch, wait for
# the heartbeat to self-fence, then set bits in the bitmap block this node
# holds dirty. A sync then makes this node write back whatever it still
# has dirty.
#
# DISCRIMINATION (measured without the drop): the peer's bits are gone.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

NODE_POKE="$(ct_helper node_poke)"
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 560 fdm)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt fdm)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
BMAP_LBA=$(($("$MAP" "$DEV" | awk '$1 == "bg" && $2 == 0 {split($4,a,"="); print a[2]}') + 1))
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

rd8() { python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print(os.pread(fd, 8, int(sys.argv[2]) * 4096 + int(sys.argv[3])).hex())" "$BACK" "$BMAP_LBA" "$1"; }

# Allocations whose bits are only in this node's cache: a write session
# held open, so no close boundary flushes them.
GO="$(mktemp -u /tmp/cetrafs-fdm-go-XXXXXX)"
ct_track file "$GO"
python3 -I - "$MNT/f" "$GO" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x" * (1 << 20))
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
os.close(fd)
PY
WPID=$!
sleep 1
[ "$(rd8 8)" = 0000000000000000 ] ||
    { : >"$GO"; wait "$WPID" || true; fail "setup: this node's allocation bits already reached the device -- nothing is dirty to test"; ct_exit; }
pass "setup: this node's new allocation bits are only in its cache"

log "a peer revokes this node's lease"
MARK="$(dmesg_mark)"
"$NODE_POKE" "$DEV" 0 --bump-fence 1 >/dev/null
wait_for 15 "dmesg_since '$MARK' | grep -q SELF-FENCED" ||
    { : >"$GO"; wait "$WPID" || true; fail "setup: this node never self-fenced"; ct_exit; }
pass "setup: the node self-fenced"

# The peer, which now owns the Zone Group, allocates in the same bitmap
# block -- on the device.
python3 -I -c "
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b'\xff' * 8, int(sys.argv[2]) * 4096 + 512)
os.fsync(fd)" "$BACK" "$BMAP_LBA"

# Whatever this node still holds dirty goes out now.
sync
: >"$GO"
wait "$WPID" || true
umount "$MNT" 2>/dev/null || true

GOT="$(rd8 512)"
if [ "$GOT" = ffffffffffffffff ]; then
    pass "the peer's allocations survived the fenced node's writeback"
else
    fail "the fenced node wrote its stale bitmap over the peer's allocations (now $GOT)"
fi

ct_exit
