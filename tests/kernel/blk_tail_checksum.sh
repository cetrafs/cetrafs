#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a torn or corrupt extent-leaf / xattr block is detected, not mis-parsed
#
# g7 gave dirent blocks a tail checksum because a peer walking a
# directory takes no lock and can catch a 4 KiB write torn -- a silent
# mis-parse, seen in the field. Extent-leaf and xattr blocks have the
# same exposure and had no detection at all (closed by
# v0x000F):
#
#   - a LEAF is read through cetrafs_read_leaf_bh(), which reads FRESH
#     whenever this node does not hold the file's exclusive lock -- and
#     a DIRECTORY never holds one, so every peer walking a spilled
#     directory reads its leaf unsynchronised. A torn leaf is a garbage
#     extent array: blocks belonging to another file, served as this
#     one's.
#   - an XATTR block is written under the namespace mutex and read
#     without it.
#
# A single kernel cannot tear the write (one buffer cache, serialised on
# the buffer lock), so what is injected here is a corrupt tail -- which
# is the same observable the reader must act on. The cross-node tearing
# itself is ctest's job.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper blk_tail_poke)"
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 blktail)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt blktail)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "a spilled file's leaf really is tail-stamped"
MAXLEAVES="$("$IPOKE" "$DEV" maxleaves)"
python3 - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
blk = b'f' * 4096
for i in range(30):
    os.pwrite(fd, blk, i * 2 * 4096)   # strided, so each is its own extent
os.fsync(fd); os.close(fd)
PY
sync
INO="$(stat -c '%i' "$MNT/frag")"
[ "$("$IPOKE" "$IMG" extents "$INO" | grep -o 'depth=[01]')" = "depth=1" ] &&
    pass "the file really spilled into an external leaf (depth=1, max $MAXLEAVES entries)" ||
    fail "the file is $("$IPOKE" "$IMG" extents "$INO") -- not depth 1, so this suite tests nothing"
SUM="$(md5sum <"$MNT/frag")"
"$POKE" "$IMG" leaf "$INO" check >/dev/null &&
    pass "its leaf carries a valid LBLK tail" || fail "the leaf has no valid tail -- a writer did not stamp it"

log "a corrupt leaf tail is reported, not parsed"
# The whole point: without the tail this read returns whatever the
# garbage extents point at. With it, the read fails loudly.
"$POKE" "$IMG" leaf "$INO" corrupt >/dev/null
MARK="$(dmesg_mark)"
if md5sum <"$MNT/frag" >/dev/null 2>&1; then
    fail "a leaf with a broken tail was parsed anyway -- the extents it names could be any file's blocks"
else
    pass "a leaf with a broken tail fails the read instead of serving whatever it names"
fi
dmesg_since "$MARK" | grep -q "extent leaf block .* failed its tail checksum" &&
    pass "...and says so, naming the block" || fail "nothing was logged"

log "and the file is fine again once the tail is valid"
"$POKE" "$IMG" leaf "$INO" restamp >/dev/null
[ "$(md5sum <"$MNT/frag")" = "$SUM" ] &&
    pass "the same file reads correctly with a valid tail (the control: only the tail was wrong)" ||
    fail "the file does not read back -- the poke changed more than the tail"

log "the same for an xattr block"
# python rather than setfattr: attr(1) is not installed everywhere, and
# the other xattr suite already uses os.setxattr for the same reason.
xset() { python3 -c "import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())" "$@"; }
xget() { python3 -c "import os,sys; sys.stdout.write(os.getxattr(sys.argv[1], sys.argv[2]).decode())" "$@"; }
xset "$MNT/frag" user.one first
xset "$MNT/frag" user.two second
sync
[ "$(xget "$MNT/frag" user.one 2>/dev/null)" = "first" ] &&
    pass "the xattrs read back before the poke" || fail "setxattr/getxattr did not round-trip"
"$POKE" "$IMG" xattr "$INO" check >/dev/null &&
    pass "the xattr block carries a valid XBLK tail" || fail "the xattr block has no valid tail"

"$POKE" "$IMG" xattr "$INO" corrupt >/dev/null
MARK="$(dmesg_mark)"
if xget "$MNT/frag" user.one >/dev/null 2>&1; then
    fail "an xattr block with a broken tail was parsed anyway"
else
    pass "an xattr block with a broken tail fails the read"
fi
dmesg_since "$MARK" | grep -q "xattr block .* failed its tail checksum" &&
    pass "...and says so, naming the block" || fail "nothing was logged"

"$POKE" "$IMG" xattr "$INO" restamp >/dev/null
[ "$(xget "$MNT/frag" user.one 2>/dev/null)" = "first" ] &&
    pass "the xattrs read correctly again once the tail is valid" ||
    fail "the xattrs did not come back"

log "fsck sees a broken leaf tail too"
"$POKE" "$IMG" leaf "$INO" corrupt >/dev/null
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "extent leaf .* failed its tail checksum" &&
    pass "fsck reports a leaf whose tail is wrong" ||
    fail "fsck did not report it: $(echo "$OUT" | grep -i err | head -2)"
echo "$OUT" | grep -q "repair is disabled" &&
    pass "...and refuses to repair around it (its blocks would all look leaked)" ||
    pass "...(repair not requested, so no refusal expected)"

log "fsck sees a broken xattr tail too, and a healthy xattr block is not a leak"
# The leaf must be healthy again first: a bad leaf makes fsck skip the
# rest of that inode, so the xattr fault would be shadowed and this
# section would assert nothing about it.
"$POKE" "$IMG" leaf "$INO" restamp >/dev/null
"$POKE" "$IMG" xattr "$INO" corrupt >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$OUT" | grep -q "xattr block .* failed its tail checksum" &&
    pass "fsck reports an xattr block whose tail is wrong" ||
    fail "fsck did not report the xattr tail: $(echo "$OUT" | grep -i err | head -2)"
"$POKE" "$IMG" xattr "$INO" restamp >/dev/null
# The restore control carries the SECOND detection this section exists
# for: fsck used to never walk xattr_block at all, so a file carrying
# xattrs reported its (live) xattr block as a phantom LEAK -- and -r's
# bitmap reconciliation would have freed it. A clean volume with xattrs
# must fsck clean with no leak line.
OUT="$(ct_fsck "$DEV" 2>&1)" &&
    pass "fsck is clean once both tails are valid" ||
    fail "fsck still failing: $(echo "$OUT" | grep -iE 'err|warn' | head -2)"
echo "$OUT" | grep -q "referenced by no inode" &&
    fail "a live xattr block was reported as a leak (the phantom-leak bug is back)" ||
    pass "a live xattr block is counted as referenced, not leaked"

ct_exit
