#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a post-commit page-drop failure must never free committed defrag blocks
#
# THE BUG THIS PINS DOWN (found by a two-writer fill with auto-defrag,
# fsck reporting a cross-file overlap): each defrag step commits the
# extent tree to cover [0, step_end) of the new destination run, but the
# cursor that the abort path trusts ('moved') was only advanced at the
# END of the step. The one failure possible between those two points --
# invalidate_inode_pages2_range() hitting a transient page reference --
# took the abort path, which freed dst[moved, nblocks) on the stated
# premise that [0, moved) is the file's real data. After a commit that
# premise is FALSE: dst[moved, step_end) is committed, referenced, live
# data, and freeing it hands the file's blocks to the next allocation.
# One 8 MiB file lost its last 251 blocks to the root directory and a
# neighbouring file exactly this way.
#
# The fix is twofold: 'moved' advances the moment the commit returns,
# and the page drop is made unfailable (clean, flushed, content-equal
# pages are forced out rather than aborting -- a stale page left behind
# still maps the OLD blocks through its buffers, so aborting was not
# safe either).
#
# defrag_fail_invalidate is the test-only injection that makes the page
# drop "fail" deterministically; without it this window is a racing
# reader's page reference, ~1-in-15 two-writer fills. With the fix
# reverted this suite fails its fsck assertion (proven during review).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

if [ ! -w /sys/module/cetrafs/parameters/defrag_fail_invalidate ]; then
    skip "defrag_fail_invalidate unavailable -- cannot produce the failure deterministically"
    ct_exit
fi

DEV="$(ct_dev 900 dct)"
MNT="$(ct_mnt dct)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# Fourth detector: the in-core shadow bitmap mirrors every data-block
# allocate/free this node performs and screams SHADOW DOUBLE-ALLOC /
# FREE-OF-UNTRACKED in dmesg if the allocator ever hands a block out
# twice or frees one it does not hold. It is what pinned the original
# bug's family down; keep it armed where the bug lived. (Must be set
# BEFORE the mount: the bitmap is sized and allocated at mount time.)
ct_param_set alloc_shadow 1

ct_param_set auto_defrag 0

# A fragmented file long enough for several defrag steps (the step cap is
# 128 blocks; 160 single-block extents means the last step commits with
# moved > 0, the exact shape of the field failure).
log "building a 160-extent file"
SRC="$(ct_tmp dct-src)"
BLK="$(ct_tmp dct-blk)"
: >"$SRC"
for i in $(seq 0 159); do
    dd if=/dev/urandom of="$BLK" bs=4096 count=1 status=none
    cat "$BLK" >>"$SRC"
    dd if="$BLK" of="$MNT/fragfile" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 159 ] && printf x >"$MNT/filler$i"
done
sync
SUM_BEFORE="$(sha256sum "$SRC" | cut -d' ' -f1)"

log "defragmenting with the page drop failing on every step"
dmesg -c >/dev/null
ct_param_set defrag_fail_invalidate 1
OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/fragfile" 2>&1)" &&
    pass "defrag completes despite the failing page drop" ||
    fail "defrag aborted on the injected page-drop failure: $OUT"
ct_param_set defrag_fail_invalidate 0

EXT_BEFORE="$(echo "$OUT" | grep -oP 'extents \K[0-9]+' || echo 0)"
# The reservation machinery keeps most of the interleaved writes
# contiguous; what matters is >= 2 extents spread over > 128 blocks, so
# the move takes >= 2 steps and the LAST step commits with moved > 0 --
# the exact shape of the field failure.
[ "$EXT_BEFORE" -ge 3 ] && pass "the input was genuinely fragmented ($EXT_BEFORE extents over 160 blocks)" ||
    fail "input had only $EXT_BEFORE extents -- the setup no longer fragments"
echo "$OUT" | grep -qE 'extents [0-9]+ -> 1 ' && pass "file collapsed to one extent" ||
    fail "unexpected defrag result: $OUT"

# The injection must actually have exercised the forced-drop path --
# otherwise everything below passes against nothing.
dmesg | grep -q 'forced page drop' && pass "the forced page drop demonstrably ran" ||
    fail "the injection never reached the forced-drop path -- this suite tested nothing"

# Content must survive the move AND a cache drop (the re-read goes
# through the new mapping only).
SUM_AFTER="$(sha256sum "$MNT/fragfile" | cut -d' ' -f1)"
[ "$SUM_BEFORE" = "$SUM_AFTER" ] && pass "content intact after the move" ||
    fail "content CHANGED across defrag"
echo 3 >/proc/sys/vm/drop_caches
SUM_COLD="$(sha256sum "$MNT/fragfile" | cut -d' ' -f1)"
[ "$SUM_BEFORE" = "$SUM_COLD" ] && pass "content intact from disk through the new mapping" ||
    fail "content WRONG when re-read from disk -- the tree points at blocks defrag gave away"

# The lethal half of the old bug: the freed-but-referenced blocks get
# handed to the NEXT allocation. Force that reuse, then let fsck rule.
log "forcing reuse of anything defrag wrongly freed"
n=0
while dd if=/dev/urandom of="$MNT/reuse_$n" bs=1M count=4 status=none 2>/dev/null; do
    n=$((n + 1)); [ "$n" -gt 40 ] && break
done
sync
SUM_FULL="$(sha256sum "$MNT/fragfile" | cut -d' ' -f1)"
[ "$SUM_BEFORE" = "$SUM_FULL" ] && pass "content still intact after the volume filled over the freed space" ||
    fail "a later allocation overwrote the defragmented file's blocks"

ct_umount "$MNT"
if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "fsck: no overlap, no leak"
else
    fail "fsck found damage: $(ct_fsck "$DEV" 2>&1 | grep -m2 -E 'ERR|WARN')"
fi

dmesg | grep -qE "SHADOW DOUBLE-ALLOC|FREE-OF-UNTRACKED" &&
    fail "the allocator shadow caught a double allocation or bad free" ||
    pass "allocator shadow: every block allocated once, every free backed"

ct_exit
