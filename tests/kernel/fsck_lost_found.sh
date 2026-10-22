#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r gives an orphan with a live link count a name again
#
# An inode with nlink > 0 that no directory entry names is a LOST
# DIRENT: the file still claims a link, so its data is still wanted,
# and freeing it would destroy a user's data to recover space. It has
# always been reported and left -- which means the data sat on the
# volume, unreachable, until someone reformatted.
#
# The answer every other filesystem gives is lost+found, and it is the
# one repair here that CREATES a directory entry rather than rewriting
# a field in place. The nlink = 0 orphan is a different fault
# (unambiguous garbage; -r already frees it) and must not end up here.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 lf)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lf-mnt)"
ct_mkfs_small "$LOOPDEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"

# Real records with real extents, built by the kernel.
dd if=/dev/urandom of="$MNT/wanted" bs=4096 count=6 status=none
WANTED="$(stat -c '%i' "$MNT/wanted")"
WSUM="$(md5sum <"$MNT/wanted")"
mkdir "$MNT/wanteddir"
: >"$MNT/wanteddir/inside"
WDIR="$(stat -c '%i' "$MNT/wanteddir")"
dd if=/dev/urandom of="$MNT/doomed" bs=4096 count=2 status=none
DOOMED="$(stat -c '%i' "$MNT/doomed")"
ROOT_INO="$(stat -c '%i' "$MNT")"
ct_umount "$MNT"
blockdev --flushbufs "$LOOPDEV"

IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper corrupt_poke)"

# Three faults: a file and a directory that lost their names but still
# claim links, and one that was unlinked and never freed.
"$CPOKE" "$LOOPDEV" dirent "$ROOT_INO" wanted >/dev/null
"$CPOKE" "$LOOPDEV" dirent "$ROOT_INO" wanteddir >/dev/null
"$IPOKE" "$LOOPDEV" nlink "$DOOMED" 0 >/dev/null
"$CPOKE" "$LOOPDEV" dirent "$ROOT_INO" doomed >/dev/null
blockdev --flushbufs "$LOOPDEV"

OUT="$(ct_fsck "$LOOPDEV" 2>&1 || true)"
for i in $WANTED $WDIR; do
    echo "$OUT" | grep -q "inode $i is allocated" ||
        fail "fsck did not report orphan $i:
$OUT"
done
pass "both live orphans are reported before the repair"

log "repairing"
REP="$(ct_fsck_repair "$LOOPDEV" 2>&1 || true)"
echo "$REP" | grep -qi "lost+found" &&
    pass "fsck -r says it linked them into lost+found" ||
    fail "no mention of lost+found in the repair output:
$REP"

# A second pass to sweep the nlink=0 orphan's blocks (its inode bit is
# cleared in the first pass, after the content pass has run).
ct_fsck_repair "$LOOPDEV" >/dev/null 2>&1 || true
OUT2="$(ct_fsck "$LOOPDEV" 2>&1 || true)"
echo "$OUT2" | grep -q "cetrafs fsck: OK" &&
    pass "the volume is clean afterwards" ||
    fail "still not clean:
$OUT2"

log "and the repaired volume is a working filesystem"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"

[ -d "$MNT/lost+found" ] && pass "lost+found exists and is a directory" ||
    fail "no lost+found: $(ls -a "$MNT")"

# The recovered file must be findable by name and byte-identical: a
# repair that produces a clean checker and unreadable data is worse
# than no repair.
FOUND=""
for n in "$MNT/lost+found"/*; do
    [ -e "$n" ] || continue
    if [ -f "$n" ] && [ "$(md5sum <"$n")" = "$WSUM" ]; then FOUND="$n"; fi
done
[ -n "$FOUND" ] && pass "the orphaned file is in lost+found, byte-identical ($(basename "$FOUND"))" ||
    fail "the orphaned file's content is not in lost+found: $(ls -l "$MNT/lost+found")"

# The orphaned DIRECTORY must come back as a directory, with its own
# child still inside it -- and its '..' must name lost+found now, or
# the tree it is grafted into is inconsistent.
RDIR=""
for n in "$MNT/lost+found"/*; do
    [ -d "$n" ] && RDIR="$n"
done
[ -n "$RDIR" ] && pass "the orphaned directory is in lost+found ($(basename "$RDIR"))" ||
    fail "the orphaned directory is not in lost+found: $(ls -l "$MNT/lost+found")"
[ -e "$RDIR/inside" ] && pass "and its own contents came with it" ||
    fail "the recovered directory is empty: $(ls -a "$RDIR")"

# The unlinked orphan must NOT be here: it was garbage, and putting it
# in lost+found would hand the operator a file the system already
# deleted.
LFCOUNT="$(ls "$MNT/lost+found" | wc -l)"
[ "$LFCOUNT" = "2" ] && pass "only the two live orphans were recovered, not the unlinked one" ||
    fail "expected 2 entries in lost+found, found $LFCOUNT: $(ls "$MNT/lost+found")"

# The filesystem must still work normally afterwards.
: >"$MNT/after" && pass "the volume still accepts new files" || fail "write failed after repair"
rm -f "$FOUND" && pass "and a recovered file can be removed normally" || fail "unlink of a recovered file failed"
ct_umount "$MNT"
ct_fsck "$LOOPDEV" >/dev/null
pass "fsck still clean after using the repaired volume"

ct_exit
