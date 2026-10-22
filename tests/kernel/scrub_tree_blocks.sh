#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub must never reclaim a live extent tree's own blocks
#
# A file past 4 extents spills into an EXTERNAL leaf block, and past ~343
# into depth 2 with interior index blocks as well. Those blocks are
# ordinary allocated data-region blocks, and the only thing referencing
# them is the owning inode.
#
# cetrafs_raw_inode_for_each_extent() -- the walk that builds the
# scrub's reference set -- emitted only the data extents INSIDE those
# blocks, never the blocks themselves. To the scrub they therefore had a
# bitmap bit set and nothing pointing at them: its exact definition of a
# leaked block. It freed them, the allocator handed them out, the next
# file wrote data over them, and the owning inode's tree then read as
# "extent index block N failed its tail checksum -- corrupted",
# permanently -- taking the file AND the ability to free the data it
# described ("could not read extent tree to free it -- data blocks
# leaked"). Found on real hardware, on the first depth-2 file a running
# scrub ever met.
#
# Nothing in the suite caught it because every other test file is depth
# 0 (<= 4 extents, inline in the record), where there is no external
# block to lose. So this builds a genuinely depth-2 file on a volume with
# NO leaks and lets the scrub run: it must reclaim NOTHING. Reverting the
# cb(ctx, lba, 1) calls in file.c fails the reclaimed-count assertion and
# the fsck one.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 scrubtree)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubtree)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_track mnt "$MNT"

# scrub_reclaimed is a MODULE-GLOBAL counter (cetrafs_scrub_reclaimed_
# count() takes no super_block), so it carries over from any earlier
# suite in the same module load -- kernel/scrub.sh legitimately reclaims
# 40 leaked blocks right before this one. Every assertion below is
# therefore a DELTA across this suite's own scrub, never an absolute.
reclaimed() { sed -n 's/^scrub_reclaimed: //p' "/proc/fs/cetrafs/$PROC_DEV/info"; }

# Build the volume with the scrub OFF, and only start it once everything
# is written and synced. The compressed cycle this test needs (2 s, with
# a 1 s two-pass gap, against a 30 min default) is far tighter than the
# gap the scrub is designed around -- so a scrub running DURING the
# 400-extent build can legitimately catch a block between its bitmap bit
# and its extent commit and count it leaked. That is a property of the
# compression, not of the walk under test, and letting the two overlap
# made this suite fail under full-suite load while passing standalone.
# Settle first, then scrub: the bug being tested makes tree blocks look
# leaked PERMANENTLY, so it needs no race to show itself.
# The INTERVAL must be set before mounting: cetrafs_scrub_start() latches
# it to queue the first cycle, so setting it afterwards leaves that first
# cycle 30 minutes out and the scrub never runs at all (a test that
# cannot fail -- this suite was briefly in exactly that state). The
# ENABLE flag is re-read per cycle by cetrafs_scrub_work(), so it is the
# right lever for "cycles tick, but do nothing yet".
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_param_set scrub 0

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

N=400
log "building a $N-extent (depth-2) file: external leaf AND interior index blocks"
python3 - "$MNT/frag" "$N" <<'PY'
import os, sys
p, n = sys.argv[1], int(sys.argv[2])
fd = os.open(p, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o644)
for i in range(n):
    os.pwrite(fd, bytes([i & 0xff]) * 4096, i * 2 * 4096)
os.fsync(fd)
os.close(fd)
PY
sync
# The xattr block is the SAME bug with a far wider blast radius: it needs
# no depth, no fragmentation, just an xattr -- i.e. every file on an
# SELinux-enforcing host, which is a supported deployment. It is owned by
# the inode directly rather than through the extent tree, so a walk that
# only followed extents never reported it either.
echo small >"$MNT/withxattr"
# python, not setfattr: attr(1) is not installed everywhere and python3
# is already a dependency of this suite.
python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.scrubtest", b"x"*200)' "$MNT/withxattr" &&
    pass "setup: a file with an xattr (so it owns an xattr block)" ||
    fail "setup: could not set an xattr"
sync
SUM_BEFORE="$(md5sum <"$MNT/frag")"
RECLAIMED_BEFORE="$(reclaimed)"
pass "baseline captured before the scrub runs (scrub_reclaimed=$RECLAIMED_BEFORE, module-global)"

log "letting the scrub run several full cycles over a settled volume with no leaks"
MARK="$(dmesg_mark)"
ct_param_set scrub 1   # cycles have been ticking at 2 s; now they do work
sleep 12   # >= 3 cycles of interval(2s) + gap(1s)

# THE assertion: this volume has no leaked blocks, so a correct scrub
# reclaims zero. Without the fix it reclaims the tree's own blocks.
GOT=$(( $(reclaimed) - RECLAIMED_BEFORE ))
[ "$GOT" = 0 ] && pass "the scrub reclaimed nothing from a clean volume (delta=0)" ||
    fail "the scrub reclaimed $GOT block(s) from a volume with NO leaks -- it freed the live extent tree's own blocks"

[ "$(md5sum <"$MNT/frag")" = "$SUM_BEFORE" ] && pass "the depth-2 file still reads back identically" ||
    fail "the depth-2 file's contents changed after the scrub"
python3 -c 'import os,sys; sys.exit(0 if os.getxattr(sys.argv[1], "user.scrubtest") == b"x"*200 else 1)' \
    "$MNT/withxattr" 2>/dev/null &&
    pass "the xattr survived the scrub" ||
    fail "the xattr is gone or wrong after the scrub -- its block was reclaimed as leaked"

dmesg_since "$MARK" | grep -qE "failed its tail checksum" &&
    fail "a tree block failed its tail checksum after the scrub: $(dmesg_since "$MARK" | grep 'tail checksum' | tail -1)" ||
    pass "no tree block was corrupted"

ct_umount "$MNT"
# The decisive offline check: fsck marks leaf and interior blocks as
# referenced (it always did), so a tree block the scrub freed shows up
# here as referenced-but-FREE -- a block the allocator will hand to a
# second file.
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "referenced by an inode but marked FREE" &&
    fail "fsck: the scrub freed blocks the tree still references:
$(echo "$FSCK_OUT" | grep 'marked FREE' | head -3)" ||
    pass "fsck: every block the tree references is still marked in use"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(echo "$FSCK_OUT" | grep -iE '^ERR' | head -3)"
ct_exit
