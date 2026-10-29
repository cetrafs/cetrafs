#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's write-back cannot revert a record this node just wrote
#
# Confirmed on live two-node hardware as permanent data loss: one node's
# write-back of an unrelated inode that happened to share a 4 KiB block
# reverted another node's fully written, successfully closed file back to
# zero bytes. Records are now one per block, and record writes are blind
# full-block writes.
#
# Two corrections were needed before this test could fail on the broken
# build at all, both structural: it must stay inside ONE continuous open
# of the probed file (a second path lookup triggers d_revalidate's own
# fresh read and masks the bug), and the probe write must be fsync'd
# before the poke (a forced-fresh read deliberately never overrides a
# still-dirty buffer).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking cross-node packed-inode-block staleness"

# Regression test for a real data-loss bug found on live two-node
# hardware: cetrafs_inode_t (180 bytes here) is far smaller than one
# block, so ~22 inodes are packed per inode-table block. A stale cached
# read-modify-write of one inode's record used to be able to silently
# revert a block-mate inode's bytes to whatever this node last cached
# for it -- exactly what happened to a real file on the real hardware.
#
# tests/inode_block_poke.c pokes the loop device's *backing file*
# directly (not the loop device node) specifically so the poke is
# invisible to the mounted filesystem's own buffer cache -- see that
# file's own header comment for why a buffered or O_DIRECT write to the
# loop device node itself wouldn't actually reproduce this.
STALE_POKE="$(ct_helper inode_block_poke)"

STALE_IMG="$(mktemp /tmp/cetrafs-stale-XXXXXX.img)"
truncate -s 560M "$STALE_IMG"
STALE_LOOPDEV="$(losetup --find --show "$STALE_IMG")"
STALE_MNT="$(mktemp -d /tmp/cetrafs-stale-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$STALE_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

mount -t cetrafs "$STALE_LOOPDEV" "$STALE_MNT"
require_cetrafs_mount "$STALE_MNT"
touch "$STALE_MNT/f1"
touch "$STALE_MNT/f2"
F1_INO="$(stat -c '%i' "$STALE_MNT/f1")"
F2_INO="$(stat -c '%i' "$STALE_MNT/f2")"

if [ "$((F2_INO - F1_INO))" != "1" ]; then
    fail "stale-inode-block: expected f1/f2 to land in adjacent inode slots (got $F1_INO, $F2_INO)"
else
    # v0x0007: adjacent inodes live in SEPARATE whole blocks now --
    # this test keeps guarding the same end-to-end property (an
    # externally-poked neighbor record must survive this node's write to
    # f1), which one-record-per-block now makes structurally guaranteed
    # rather than dependent on the write path's read-freshness.
    pass "stale-inode-block: f1 (ino $F1_INO) and f2 (ino $F2_INO) allocated adjacently"

    # Everything below runs inside ONE continuous open() of f1, on
    # purpose: two separate opens (e.g. plain `chmod`/a second `dd`)
    # would each go through dir.c's cetrafs_d_revalidate() or lock.c's
    # own open-claim path, both of which *already* force a fresh,
    # invalidated re-read of this inode's block as an unrelated,
    # previously-shipped correctness fix -- which would refresh (and so
    # incidentally preserve) f2's poked bytes regardless of whether
    # *this* bug is fixed, making the test pass for the wrong reason.
    # Staying inside one open (one lock claim, no further path lookups)
    # isolates the exact mechanism this test exists to check: cetrafs_
    # write_raw_inode()'s own internal read-modify-write of the block.
    #
    # Write a full first block and fsync it -- this both clears the
    # per-block write's dirty bit (cetrafs_bread_uncached() deliberately
    # never forces a fresh read over a *dirty* buffer, since a dirty
    # buffer normally just holds this node's own not-yet-flushed write;
    # see ioutil.c) and gets f1's own content correctly persisted before
    # the poke, so what follows tests only the one thing it should.
    python3 -c "
import os, subprocess, sys
path, poke, img, f2_ino = sys.argv[1:5]
fd = os.open(path, os.O_WRONLY)
os.write(fd, b'A' * 4096)
os.fsync(fd)
# f1's inode-table block is now clean, uptodate, and correct. Poke f2's
# record directly on the backing file, bypassing the mount entirely --
# simulating 'a different node just changed this, and our cache
# doesn't know,' same as a real peer's write to the real shared device.
subprocess.run([poke, img, 'poke', f2_ino, '0xcc'], check=True)
# A second write crossing into a new block forces another cetrafs_
# write_raw_inode() call for f1, read-modify-writing the same shared
# block again. Pre-fix, this reuses the (clean, now-stale) cached copy
# and reverts f2's just-poked bytes on write-back. Post-fix, it forces
# a fresh read first, so the poke survives.
os.write(fd, b'B')
os.fsync(fd)
os.close(fd)
" "$STALE_MNT/f1" "$STALE_POKE" "$STALE_IMG" "$F2_INO"

    F2_BYTES="$("$STALE_POKE" "$STALE_IMG" dump "$F2_INO")"
    if echo "$F2_BYTES" | grep -qE '^(cc)+$'; then
        pass "stale-inode-block: f2's poked bytes survived f1's write-back (fix holds)"
    else
        fail "stale-inode-block: f2's poked bytes were reverted by f1's write-back (bug reproduced): $F2_BYTES"
    fi
fi

umount "$STALE_MNT"
rmdir "$STALE_MNT"
losetup -d "$STALE_LOOPDEV"
rm -f "$STALE_IMG" "$STALE_POKE"


ct_exit
