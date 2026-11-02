#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a new xattr block's allocation bit is on the device before the record names it
#
# setxattr on a file with no xattr block allocates one (its bitmap bit set
# with sync=false, like every allocation), writes it, and publishes it in
# the record by a namespace-sector CAS -- which reaches the device at once.
# cetrafs_inode_ns_cas() did not flush the allocation bitmaps first, as
# cetrafs_write_raw_inode() does: the record named a block still FREE on
# the device until some later boundary. A node dying in between left an
# inode referencing a block every node's allocator would hand out again
# (CLAUDE.md rule 8).
#
# The oracle is the device itself at that instant: a copy of the image
# taken while setxattr is held just after the publish
# (xattr_pause_after_publish_ms), checked by fsck -- the state a peer
# would find if this node died there.
#
# DISCRIMINATION (measured without the flush): fsck on the copy reports
# the xattr block referenced but FREE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 xbo)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xbo)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

printf 'data' >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
SNAP="$(mktemp "$(dirname "$IMG")/cetrafs-xbo-snap-XXXXXX.img")"
ct_track file "$SNAP"
# Held right after the record names the new block: the copy is the
# device as a peer would find it if this node died there. (Later in the
# same setxattr the bitmap does reach the device, so a copy taken after
# it returns shows nothing.)
ct_param_set xattr_pause_after_publish_ms 3000
python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", b"v")' "$MNT/f" &
XPID=$!
sleep 1
cp --sparse=always "$IMG" "$SNAP"
wait "$XPID"
umount "$MNT"

# fsck needs a block device: on a plain file it stops at BLKGETSIZE64,
# and a check that never ran reports nothing.
SNAPDEV="$(ct_loop "$SNAP")"
OUT="$("$ROOT/userspace/fsck.cetra" "$SNAPDEV" 2>&1 || true)"
echo "$OUT" | grep -q '^cetrafs fsck:' ||
    { echo "$OUT" | tail -3; fail "setup: fsck did not complete on the copy -- nothing below is measured"; ct_exit; }
if echo "$OUT" | grep -q 'referenced by an inode but marked FREE'; then
    fail "the record named its xattr block while the block's bit was still FREE on the device"
    echo "$OUT" | grep -iE 'xattr|FREE' | head -5
else
    pass "the xattr block's bit was on the device when the record named it"
fi
# The check above must be able to see the fault at all: fsck has to have
# looked at an xattr block on that copy.
"$(ct_helper blk_tail_poke)" "$SNAP" xattr "$INO" check >/dev/null 2>&1 &&
    pass "setup: the copy's record names an xattr block" ||
    fail "setup: the copy has no xattr block -- the setxattr never reached the record"

ct_exit
