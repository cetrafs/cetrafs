#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck refuses the counts and lengths the kernel refuses, not just bad checksums
#
# fsck checked a tree block's magic and checksum and then clamped its
# entry count to what fits, in silence; dirent blocks had no length
# check at all; a record's inline count was clamped the same way. The
# kernel refuses every one of those blocks on every read
# (cetrafs_blk_struct_ok(), now one definition shared by both), so fsck
# called a volume clean that the kernel cannot read.
#
#  A. a dirent with name_len 4000, block restamped;
#  B. an extent leaf claiming 9999 entries, block restamped;
#  C. a record claiming 7 inline index entries, record restamped.
#
# DISCRIMINATION (measured on the old fsck): A, B and C are called clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CORRUPT="$(ct_helper corrupt_poke)"
LEAF="$(ct_helper leaf_poke)"
REC="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fsckcnt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckcnt)"

build() {
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    mkdir "$MNT/d"
    : >"$MNT/d/victim"
    # Five extents that cannot merge: past the 4 inline slots, so depth 1.
    python3 -I - "$MNT/big" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
for i in range(6):
    os.pwrite(fd, b"x" * 4096, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
    sync
    DINO="$(stat -c %i "$MNT/d")"
    BINO="$(stat -c %i "$MNT/big")"
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the volume is not clean before the poke"; ct_exit; }
}

check() { # <label> <regex>
    local rc=0 out
    out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then
        fail "$1: fsck called the volume clean"
    elif [ "$rc" -ge 128 ]; then
        fail "$1: fsck died on a signal (rc=$rc)"
    elif grep -qE "$2" <<<"$out"; then
        pass "$1: reported"
    else
        fail "$1: fsck failed, but not for this: $(grep -E '^ERR' <<<"$out" | head -2 | tr '\n' ' ')"
    fi
}

build
"$CORRUPT" "$IMG" namelen "$DINO" victim 4000 >/dev/null || { fail "setup: could not poison the dirent"; ct_exit; }
check "A (name_len 4000)" "impossible name length"

build
"$LEAF" "$IMG" setcount "$BINO" 9999 >/dev/null || { fail "setup: $BINO is not depth 1"; ct_exit; }
check "B (leaf entry count 9999)" "impossible count or length"

build
"$REC" "$IMG" idxcount "$BINO" 7 2>/dev/null
check "C (record inline count 7)" "claims 7 inline extent entries"
ct_exit
