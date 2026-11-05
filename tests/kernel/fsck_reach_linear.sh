#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's reachability pass walks each directory once, not each chain from scratch
#
# Every directory's parent chain was walked to the root from scratch,
# clearing an inodes_count-sized map per directory: quadratic in depth,
# and dirs x inodes in memory traffic (audit L19). Verdicts are now
# memoised along each walk, so the walk is linear in the directories.
#
# A 300-deep chain: walked from scratch that is ~45000 steps, memoised it
# is one per directory. fsck prints the count on its namespace line.
#
# DISCRIMINATION: proven by dropping the memo (res[] never set): 45150
# steps for 300 directories.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"

IMG="$(ct_image 560 frl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt frl)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
D=300
P="$MNT"
for i in $(seq 1 "$D"); do P="$P/d"; mkdir "$P"; done
sync
ct_umount "$MNT"

OUT="$("$FSCK" "$DEV" 2>&1 || true)"
LINE="$(grep "every directory is reachable" <<<"$OUT" || true)"
log "$LINE"
[ -n "$LINE" ] || { fail "setup: fsck did not report the tree reachable: $(grep -m3 ERR <<<"$OUT")"; ct_exit; }
STEPS="$(sed -n 's/.*(\([0-9]*\) walk steps, \([0-9]*\) directories).*/\1/p' <<<"$LINE")"
NDIRS="$(sed -n 's/.*(\([0-9]*\) walk steps, \([0-9]*\) directories).*/\2/p' <<<"$LINE")"
[ "$NDIRS" -ge "$D" ] || { fail "setup: fsck counted $NDIRS directories, expected at least $D"; ct_exit; }
[ "$STEPS" -le $((2 * NDIRS)) ] && pass "the reachability walk took $STEPS steps for $NDIRS directories (linear)" ||
    fail "the reachability walk took $STEPS steps for $NDIRS directories -- every chain walked from scratch"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
