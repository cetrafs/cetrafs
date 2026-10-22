#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a truncate that fails must not have already freed the leaf it references
#
# When a shrink (or a punch) empties a file's external extent leaf, the
# leaf block itself is freed and the record reverts to depth 0. That free
# used to happen the moment the trim emptied the leaf -- BEFORE the
# record that names it was written. A failure in that write then left a
# record still pointing at a block the allocator had taken back, which it
# can hand to another file; this file's extent tree then reads that
# file's data.
#
# P15's rule in a second place: an operation that can fail must not free
# anything before it knows it will succeed. Reaching the failure needs
# the fail_extent_record_write param, because nothing a test can supply
# makes that write fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# This suite needs FRAGMENTED files: an external leaf, a depth-1 tree, an
# auto-defrag trigger. Speculative run allocation makes a sequential write
# land contiguously and merge into one extent, so the fragmentation its
# setup relies on never happens and the suite would test nothing (several
# assertions below check exactly that precondition, which is how this was
# caught). Turn runs off so allocation goes back one block at a time.
ct_param_set alloc_run_blocks 0
POKE="$(ct_helper inode_block_poke)"
FAIL_PARAM=/sys/module/cetrafs/parameters/fail_extent_record_write

IMG="$(ct_image 560 trunwind)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt trunwind)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# A file that really has an external extent leaf: its blocks must
# fragment, so grow a second file alongside it (see dirent_helpers.sh --
# grown alone it stays in one extent and never spills).
build_spilled() { # <name>
    python3 - "$MNT" "$1" <<'PY'
import os, sys
mnt, name = sys.argv[1], sys.argv[2]
a = os.open(mnt + "/" + name, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
b = os.open(mnt + "/noise_" + name, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
for i in range(40):
    os.pwrite(a, b"A" * 4096, i * 4096)
    os.pwrite(b, b"B" * 4096, i * 4096)
os.fsync(a)
os.close(a)
os.close(b)
print(os.stat(mnt + "/" + name).st_ino)
PY
}

INO="$(build_spilled victim)"
sync
SHAPE="$("$POKE" "$IMG" extents "$INO")"
case "$SHAPE" in
depth=1*) pass "the victim file really has an external extent leaf ($SHAPE)" ;;
*) fail "the file did not spill, so this suite is not testing the leaf: $SHAPE" ;;
esac
LEAF="$("$POKE" "$IMG" leaf "$INO" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
[ -n "$LEAF" ] && pass "its leaf lives at block $LEAF" || fail "could not find the leaf block"

log "a failed truncate leaves the leaf referenced, not freed"
[ -w "$FAIL_PARAM" ] || { skip "fail_extent_record_write is missing"; ct_exit; }
echo 1 >"$FAIL_PARAM"
truncate -s 0 "$MNT/victim" 2>/dev/null && fail "the injected failure did not fail the truncate" ||
    pass "the truncate failed as instructed"
echo 0 >"$FAIL_PARAM"

# The record must still name the leaf, and the leaf's block must still be
# marked in use -- i.e. the allocator must not be able to hand it out.
SHAPE2="$("$POKE" "$IMG" extents "$INO")"
case "$SHAPE2" in
depth=1*) pass "the record still references its external leaf after the failure" ;;
*) fail "the record reverted to '$SHAPE2' even though the truncate failed" ;;
esac
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if echo "$FSCK_OUT" | grep -qi "referenced by an inode but marked FREE"; then
    fail "the failed truncate freed a block the inode still references -- the allocator can hand it out again"
else
    pass "fsck finds no block that is referenced and free at once"
fi
echo "$FSCK_OUT" | grep -qi "ERR" &&
    fail "fsck reports a fault after the failed truncate: $(echo "$FSCK_OUT" | grep -i err | head -2)" ||
    pass "fsck is clean after the failed truncate"

log "what a failed truncate does leave behind, stated plainly"
# The in-core size was already set to 0 before the extent work (the
# pages must be gone before their blocks are -- ext2 does the same), and
# ordinary writeback carries that 0 into the record. So the durable
# residue is a file of size 0 whose extents are intact: space stuck
# inside a live file until it is deleted. Conventional for a truncate
# that failed halfway, and strictly better than the alternative this
# suite exists to prevent -- blocks handed to another file while this
# one still references them. Asserted so the residue is a known
# quantity rather than a surprise.
ct_mount "$DEV" "$MNT"
[ "$(stat -c '%s' "$MNT/victim")" = "0" ] &&
    pass "the failed truncate leaves the file at size 0 with its blocks still its own" ||
    fail "the file's size is $(stat -c '%s' "$MNT/victim")"
rm -f "$MNT/victim" "$MNT/noise_victim"
sync

log "control: an uninjected truncate really does free the leaf"
INO2="$(build_spilled victim2)"
sync
case "$("$POKE" "$IMG" extents "$INO2")" in
depth=1*) pass "control: the second file also spilled" ;;
*) fail "control: the second file did not spill" ;;
esac
truncate -s 0 "$MNT/victim2" || fail "control: the truncate failed with no injection"
sync
case "$("$POKE" "$IMG" extents "$INO2")" in
depth=0*) pass "control: a successful truncate reverts the record to depth 0 and returns the leaf" ;;
*) fail "control: after a successful truncate the record is '$("$POKE" "$IMG" extents "$INO2")'" ;;
esac
rm -f "$MNT/victim2" "$MNT/noise_victim2"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "control: fsck clean once everything is removed" ||
    fail "control: fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

ct_exit
