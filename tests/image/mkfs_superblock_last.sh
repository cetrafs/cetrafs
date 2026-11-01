#!/usr/bin/env bash
# the superblock is the LAST thing mkfs writes, and the flush is checked
#
# The superblock is what makes a volume mountable. mkfs used to stamp it
# early and then go on writing everything it points at -- the Node
# Registry, the pending-free queues, and above all the per-node JOURNAL
# area, which is zeroed precisely because a device reused from an
# earlier cetrafs still holds that volume's journal slots at those
# offsets.
#
# So an mkfs that stopped in between -- a power cut, an I/O error, a ^C
# -- left a valid superblock over the previous volume's journal. A
# mount then finds those slots dirty and replays them into the new
# filesystem: valid records, correct checksums, aimed at the wrong
# blocks. The kernel's own rule (CLAUDE.md 8) says a reference may not
# become durable before what it refers to; mkfs was breaking it on the
# largest possible scale.
#
# Image-level: no module, nothing mounted. The device is pre-filled with
# a pattern, mkfs is interrupted part way through, and what matters is
# whether block 0 came out mountable while the areas behind it were
# still whatever the previous volume left there.
#
# Discrimination: stamp the superblock where it used to be stamped
# (before the ZG table) and the interrupted run below leaves a block 0
# that fsck accepts, with the pattern still sitting in the journal area.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
CT_NEED_MODULE=0
require_root

DEV="$(ct_big_dev 2200 mkfslast)"

# 1. A complete mkfs still produces a volume fsck accepts. The reorder
# is only safe if the ordinary path is untouched.
ct_mkfs "$DEV" -z 1 -b 512 -J 2 -N 1024 -f >/dev/null 2>&1 &&
    pass "a complete mkfs still produces a volume" ||
    fail "mkfs failed outright"
ct_fsck "$DEV" >/dev/null && pass "and fsck accepts it" || fail "fsck rejected a freshly made volume"

# 2. The interrupted run.
#
# Killed on a PROGRESS signal, not a timer: mkfs finishes a sparse
# loop-backed image in under 50ms, so a fixed sleep either lands before
# it starts or after it ends (the first version of this did the latter
# and had nothing to assert). Waiting for the Zone Group table -- block
# 1, written right after the point the superblock used to be stamped at
# -- puts the kill inside the window every time, with the journal
# zeroing, the node table and the root inode all still ahead.
dd if=/dev/zero of="$DEV" bs=1M count=8 status=none     # block 0 starts blank
"$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 2 -N 1024 -f >/dev/null 2>&1 &
MKPID=$!

ZG_SEEN=0
for _ in $(seq 1 4000); do
    if [ -n "$(dd if="$DEV" bs=4096 skip=1 count=1 2>/dev/null | tr -d '\000')" ]; then
        ZG_SEEN=1
        break
    fi
    kill -0 "$MKPID" 2>/dev/null || break               # it exited already
done
kill -9 "$MKPID" 2>/dev/null || true
wait "$MKPID" 2>/dev/null || true
sync

[ "$ZG_SEEN" = 1 ] ||
    fail "the Zone Group table never appeared -- mkfs did not get that far, so there is nothing to assert"

if ct_fsck "$DEV" >/dev/null 2>&1; then
    fail "the kill did not interrupt mkfs -- it completed, so this proves nothing"
else
    FSCKOUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 | head -3 || true)"
    echo "fsck on the interrupted volume: $FSCKOUT"
fi
if [ -z "${FSCKOUT+x}" ]; then
    :                                                  # already reported above
elif echo "$FSCKOUT" | grep -q "bad magic"; then
    pass "an interrupted mkfs leaves block 0 unstamped, so nothing can mount it"
else
    fail "an interrupted mkfs left a readable superblock behind -- a node can mount a half-made volume"
fi

ct_exit
