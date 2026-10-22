#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# creating a file costs the same in a big directory as in a small one
#
# Every dirent block a create scans used to be read forced-fresh, so the
# scan cost one device round trip per block and a create in an N-block
# directory cost O(N) reads -- 1.2 ms to 3.8 ms over 1500 files here,
# and far worse on a LUN where a read is ~5.5 ms rather than free.
#
# The fix is NOT to trust the cache for the write: the decision (is this
# name taken, which slot is free) comes from the dirent_seq cache, and
# the one block actually being modified is then re-read forced-fresh and
# re-verified before anything is written into it. A stale image can
# therefore never be written back -- which is the failure that had the
# cached scan removed from this path in the first place.
#
# The assertion compares a LATE window of creates against an EARLY one,
# so it measures the scaling rather than any absolute number.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 cscale)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt cscale-mnt)"
ct_mkfs "$LOOPDEV" -z 1 -b 512 -N 4096 -M 2 -J 4 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"

BASE="$(basename "$LOOPDEV")"
reads_now() { awk '{print $1}' "/sys/block/$BASE/stat"; }

D="$MNT/big"
mkdir "$D"
WINDOW=100

# A window of creates, reported as device reads per create.
window() { # first-index
  local first="$1" r0 r1 i
  sync; sleep 1
  r0="$(reads_now)"
  for ((i = first; i < first + WINDOW; i++)); do : >"$D/f$i"; done
  sync
  r1="$(reads_now)"
  awk -v a="$r0" -v b="$r1" -v n="$WINDOW" 'BEGIN{printf "%.2f", (b-a)/n}'
}

EARLY="$(window 0)"
# Fill out to ~1400 entries: at 15 dirents per 4096-byte block that is
# ~95 blocks, so a scan that reads every block is unmistakable.
for ((i = WINDOW; i < 1300; i++)); do : >"$D/f$i"; done
LATE="$(window 1300)"
log "device reads per create: early=$EARLY late=$LATE (directory ~95 blocks by then)"

# Scaling, not an absolute: the late window may legitimately cost a
# little more (a deeper extent tree, a fuller block group). O(N) would
# add ~90 reads per create here, so any sane bound discriminates.
RATIO="$(awk -v e="$EARLY" -v l="$LATE" 'BEGIN{printf "%.2f", (e > 0 ? l/e : 999)}')"
if awk -v r="$RATIO" 'BEGIN{exit !(r < 2.0)}'; then
    pass "a create in a ~95-block directory costs ${RATIO}x one in an empty directory"
else
    fail "create cost scales with directory size: early=$EARLY late=$LATE reads/op (${RATIO}x)"
fi

# Correctness: the decision came partly from cached blocks, so the
# duplicate check and the free-slot choice both have to still be right.
COUNT="$(ls "$D" | wc -l)"
[ "$COUNT" = "1400" ] && pass "all 1400 entries present" ||
    fail "expected 1400 entries, found $COUNT"
DUPES="$(ls "$D" | sort | uniq -d | wc -l)"
[ "$DUPES" = "0" ] && pass "no duplicate names" || fail "$DUPES duplicate names"

# Every name must resolve, and to a DISTINCT inode: a stale free-slot
# choice writes a second dirent over a live one, which shows up as two
# names sharing an inode number.
INOS="$(ls "$D" | while read -r n; do stat -c %i "$D/$n"; done | sort -n)"
UNIQ="$(echo "$INOS" | uniq | wc -l)"
[ "$UNIQ" = "1400" ] && pass "every entry has a distinct inode" ||
    fail "1400 entries share only $UNIQ inodes -- a dirent was written over a live one"

# A name added late must be findable, and one removed must stay removed.
rm "$D/f700"
[ -e "$D/f700" ] && fail "removed entry still present" || pass "removal still works"
: >"$D/f700"
[ -e "$D/f700" ] && pass "and the slot is reusable" || fail "re-create failed"

ct_umount "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"
[ "$(ls "$D" | wc -l)" = "1400" ] && pass "survives a remount" ||
    fail "after remount: $(ls "$D" | wc -l) entries"
ct_umount "$MNT"
ct_fsck "$LOOPDEV"
pass "fsck clean"

ct_exit
