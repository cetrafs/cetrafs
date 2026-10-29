#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CETRAFS_IOC_DEFRAG relocates a fragmented file into one extent
#
# What makes online defrag safe here is cetrafs's own locking: the
# write-open already holds the whole-file cross-node lock, inode_lock
# blocks local writers per step, and the page cache is logical so the
# physical move is invisible to readers and mmap.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking per-file online defragmentation"

# Build a deliberately fragmented file (interleaved filler writes steal
# the contiguity hint, same technique as the frag tests later), spill it
# past 4 extents into an external leaf, then defrag: the result must be
# ONE extent, byte-identical content, no net free-space change (old
# freed = new allocated), fsck-clean, and still correct after a remount.
DEFRAG_IMG="$(mktemp /tmp/cetrafs-defrag-XXXXXX.img)"
truncate -s 560M "$DEFRAG_IMG"
DEFRAG_LOOPDEV="$(losetup --find --show "$DEFRAG_IMG")"
DEFRAG_MNT="$(mktemp -d /tmp/cetrafs-defrag-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$DEFRAG_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$DEFRAG_LOOPDEV" "$DEFRAG_MNT"
require_cetrafs_mount "$DEFRAG_MNT"
# This section exercises the MANUAL tool, so keep the background janitor
# out of it -- otherwise it defrags the file on close before the tool runs.
ct_param_set auto_defrag 0

rm -f /tmp/cetrafs-defrag-src
for i in 0 1 2 3 4 5 6; do
    dd if=/dev/urandom of=/tmp/cetrafs-defrag-blk bs=4096 count=1 status=none
    cat /tmp/cetrafs-defrag-blk >>/tmp/cetrafs-defrag-src
    dd if=/tmp/cetrafs-defrag-blk of="$DEFRAG_MNT/fragfile" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 6 ] && printf x >"$DEFRAG_MNT/dfiller$i"
done
rm -f /tmp/cetrafs-defrag-blk
sync "$DEFRAG_MNT/fragfile"

DEFRAG_FREE_BEFORE="$(stat -f -c '%f' "$DEFRAG_MNT")"
DEFRAG_SUM_BEFORE="$(sha256sum "$DEFRAG_MNT/fragfile" | cut -d' ' -f1)"

DEFRAG_OUT="$("$ROOT/userspace/defrag.cetra" "$DEFRAG_MNT/fragfile")"
echo "  $DEFRAG_OUT"

if echo "$DEFRAG_OUT" | grep -qE 'extents [0-9]+ -> 1 \(7 blocks moved\)'; then
    pass "defrag: file relocated to a single extent"
else
    fail "defrag: unexpected result: $DEFRAG_OUT"
fi
EXT_BEFORE="$(echo "$DEFRAG_OUT" | grep -oP 'extents \K[0-9]+')"
[ "$EXT_BEFORE" -ge 5 ] && pass "defrag: the input was genuinely fragmented ($EXT_BEFORE extents, incl. leaf spill)" ||
    fail "defrag: input had only $EXT_BEFORE extents -- test setup no longer fragments"

DEFRAG_SUM_AFTER="$(sha256sum "$DEFRAG_MNT/fragfile" | cut -d' ' -f1)"
[ "$DEFRAG_SUM_BEFORE" = "$DEFRAG_SUM_AFTER" ] && pass "defrag: content byte-identical after the move" ||
    fail "defrag: content CHANGED across defrag"

DEFRAG_FREE_AFTER="$(stat -f -c '%f' "$DEFRAG_MNT")"
# old 7 data blocks freed + old external leaf block freed, new 7 allocated: net +1
[ "$DEFRAG_FREE_AFTER" = "$((DEFRAG_FREE_BEFORE + 1))" ] &&
    pass "defrag: free space netted exactly +1 block (old extents+leaf freed, new run allocated)" ||
    fail "defrag: free blocks $DEFRAG_FREE_BEFORE -> $DEFRAG_FREE_AFTER, expected +1"

# second run is a no-op
DEFRAG_OUT2="$("$ROOT/userspace/defrag.cetra" "$DEFRAG_MNT/fragfile")"
echo "$DEFRAG_OUT2" | grep -q 'extents 1 -> 1 (0 blocks moved)' &&
    pass "defrag: already-contiguous file is a no-op" ||
    fail "defrag: rerun not a no-op: $DEFRAG_OUT2"

umount "$DEFRAG_MNT"
"$ROOT/userspace/fsck.cetra" "$DEFRAG_LOOPDEV" >/dev/null &&
    pass "defrag: fsck clean after the move (bitmaps and ZG/BG counters consistent)" ||
    fail "defrag: fsck reported errors after the move"
mount -t cetrafs "$DEFRAG_LOOPDEV" "$DEFRAG_MNT"
require_cetrafs_mount "$DEFRAG_MNT"
DEFRAG_SUM_REMOUNT="$(sha256sum "$DEFRAG_MNT/fragfile" | cut -d' ' -f1)"
[ "$DEFRAG_SUM_BEFORE" = "$DEFRAG_SUM_REMOUNT" ] && pass "defrag: content persisted across remount" ||
    fail "defrag: content wrong after remount"

umount "$DEFRAG_MNT"
rmdir "$DEFRAG_MNT"
losetup -d "$DEFRAG_LOOPDEV"
rm -f "$DEFRAG_IMG" /tmp/cetrafs-defrag-src
ct_param_set auto_defrag 0


ct_exit
