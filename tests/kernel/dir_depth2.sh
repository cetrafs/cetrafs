#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory grows past one extent leaf, to depth 2 (M-41)
#
# A directory used to stop at depth 1: its tree held the four inline
# extents plus one leaf of 254, and a create past that failed ENOSPC on a
# volume with free space -- ~3,800 entries when its blocks interleave
# with another directory's, so that each block is its own extent (a
# backup directory of 200 images x 14 days x 3 files is 8,400). Now it
# grows like a file's tree, its blocks journaled as it grows.
#
# Two directories grow interleaved, 4,200 entries each, so each block of
# either is an extent of its own. Then:
#   1. every create succeeded (the old ceiling refused one near 3,800);
#   2. setup: the directory's tree really is depth 2;
#   3. fsck finds the volume clean -- it reads a depth-2 directory too;
#   4. after a remount (every tree block off the device): readdir lists
#      every name, a lookup finds the first and the last, a rename, an
#      unlink and a re-add work, and the late blocks are reachable;
#   5. emptied and removed, both directories give back every block --
#      fsck clean, and the free count back where it started;
#   6. a directory at its tree's limit (TEST ONLY caps: one interior of
#      two leaves) refuses a create ENOSPC and keeps no block for it --
#      it used to take the block first and keep it on the failed append,
#      one per create (audit p3-extent-ceiling R-6).
#
# DISCRIMINATION: on a module where directories stop at depth 1, step 1
# fails at the create that needs the 259th extent (measured: a/f3809).
# With the room check before the allocation removed, step 6 loses a
# block per refused create.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"
G="$(ct_helper getdents_probe)"

N=4200
IMG="$(ct_image 1200 dirdeep)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dirdeep)"
ct_mkfs "$DEV" -z 1 -b 512 -J 16 -M 4 -N 16384 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
avail() { df --output=avail "$MNT" | tail -1; }
FREE0="$(avail)"

log "two directories grow interleaved, $N entries each"
mkdir "$MNT/a" "$MNT/b"
OUT="$(python3 -I - "$MNT" "$N" <<'PY'
import errno, os, sys
mnt, n = sys.argv[1], int(sys.argv[2])
for i in range(1, n + 1):
    for d in ("a", "b"):
        try:
            os.close(os.open("%s/%s/f%d" % (mnt, d, i), os.O_CREAT | os.O_WRONLY, 0o644))
        except OSError as e:
            print("create %s/f%d failed: %s" % (d, i, errno.errorcode.get(e.errno, str(e.errno))))
            sys.exit(0)
print("OK")
sys.stdout.flush()
PY
)" || true
[ "$OUT" = OK ] && pass "1: all $((2 * N)) creates succeeded" || fail "1: $OUT"
A_INO="$(stat -c %i "$MNT/a")"
ct_umount "$MNT"

SHAPE="$("$POKE" "$IMG" extents "$A_INO" 2>/dev/null | head -1)"
case "$SHAPE" in
depth=2*) pass "2 setup: the directory's tree is depth 2 ($SHAPE)" ;;
*)
    fail "2 setup: the directory did not reach depth 2 -- this suite is not testing it: $SHAPE"
    ct_exit
    ;;
esac
ct_fsck "$DEV" >/dev/null 2>&1 && pass "3: fsck reads the depth-2 directory and finds the volume clean" ||
    fail "3: fsck: $(ct_fsck "$DEV" 2>&1 | grep -v '^INFO' | head -3 | tr '\n' ';')"

log "a depth-2 directory read back cold"
ct_mount "$DEV" "$MNT"
COUNT="$("$G" list "$MNT/a" 256 | sort -u | wc -l)"
[ "$COUNT" = "$((N + 2))" ] && pass "4: readdir lists all $((N + 2)) entries" ||
    fail "4: readdir listed $COUNT unique entries, expected $((N + 2))"
[ -e "$MNT/a/f1" ] && [ -e "$MNT/a/f$N" ] && pass "4: lookup finds the first and the last name" ||
    fail "4: lookup cannot find f1 or f$N"
mv "$MNT/a/f$N" "$MNT/a/renamed"
rm "$MNT/a/f2"
: >"$MNT/a/readded"
[ -e "$MNT/a/renamed" ] && [ ! -e "$MNT/a/f$N" ] && [ ! -e "$MNT/a/f2" ] && [ -e "$MNT/a/readded" ] &&
    pass "4: rename, unlink and re-add work" || fail "4: rename/unlink/re-add misbehaved"
COUNT="$("$G" list "$MNT/a" 256 | sort -u | wc -l)"
[ "$COUNT" = "$((N + 2))" ] && pass "4: readdir after the edits still lists $((N + 2))" ||
    fail "4: readdir after the edits listed $COUNT, expected $((N + 2))"

log "removing both returns every block"
find "$MNT/a" "$MNT/b" -mindepth 1 -delete
rmdir "$MNT/a" "$MNT/b"
sync
FREE1="$(avail)"
[ "$FREE1" = "$FREE0" ] && pass "5: the free count is back where it started ($FREE1)" ||
    fail "5: free was $FREE0 before, $FREE1 after -- blocks not given back"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "5: fsck clean after the removal (nothing leaked)" ||
    fail "5: fsck: $(ct_fsck "$DEV" 2>&1 | grep -v '^INFO' | head -3 | tr '\n' ';')"

log "a directory at its tree's limit refuses a create and keeps nothing for it"
ct_mount "$DEV" "$MNT"
ct_param_set tree_root_cap 1
ct_param_set tree_idx_cap 2
mkdir "$MNT/c" "$MNT/d"
OUT="$(python3 -I - "$MNT" <<'PY'
import errno, os, sys
mnt = sys.argv[1]
for i in range(1, 20000):
    for d in ("c", "d"):
        try:
            os.close(os.open("%s/%s/f%d" % (mnt, d, i), os.O_CREAT | os.O_WRONLY, 0o644))
        except OSError as e:
            print("%s %d %s" % (d, i, errno.errorcode.get(e.errno, str(e.errno))))
            sys.exit(0)
print("NOLIMIT")
PY
)" || true
case "$OUT" in
"c "*" ENOSPC") ;;
*)
    fail "6 setup: the capped directory did not reach its limit with ENOSPC: $OUT"
    ct_exit
    ;;
esac
sync
F0="$(avail)"
REFUSED="$(python3 -I - "$MNT/c" <<'PY'
import errno, os, sys
n = 0
for i in range(20):
    try:
        os.close(os.open("%s/over%d" % (sys.argv[1], i), os.O_CREAT | os.O_WRONLY, 0o644))
    except OSError as e:
        n += e.errno == errno.ENOSPC
print(n)
PY
)"
sync
F1="$(avail)"
[ "$REFUSED" = 20 ] && [ "$F1" = "$F0" ] &&
    pass "6: at the limit ($OUT), 20 creates refused ENOSPC and the free count did not move ($F0)" ||
    fail "6: $REFUSED of 20 creates refused; free $F0 before, $F1 after"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "6: fsck clean with a directory at its tree's limit" ||
    fail "6: fsck: $(ct_fsck "$DEV" 2>&1 | grep -v '^INFO' | head -3 | tr '\n' ';')"

ct_exit
