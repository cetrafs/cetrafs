#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a root slot's range is never a bound: not written stale, not trusted by the salvage
#
# Only an INTERIOR index entry's range is maintained. A root slot is
# written "unknown" (0, 0) -- except that cetrafs_tree_build() wrote a
# depth-1 root's real range, and a depth-1 append never widens it. A
# depth-1 file rebuilt by a truncate or a punch and then appended to
# therefore carried a root range that excluded its newest extents.
# Nothing in the kernel filters by a depth-1 root's range, but fsck's
# salvage did: a torn leaf under such a root lost every entry outside
# the stale range, and fsck -r turned the file's newest data into holes.
#
#   K: after a truncate rebuilds a depth-1 tree and the file is appended
#      past it, the root range is unknown or covers every extent;
#   F: with a stale root range planted and the leaf torn, fsck -r keeps
#      the entries the range excludes: they read their data back.
#
# DISCRIMINATION (measured before the fix): K finds the root range ending
# at the truncation point; F reads the appended blocks back as zeros.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LP="$(ct_helper leaf_poke)"
IBP="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 rootrng)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rootrng)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0

# Depth 1: a fallocated run split by writes into every 4th block (about
# 2 * NB extents, one leaf). Then a truncate, which rebuilds the tree,
# and two blocks appended well past the truncation point.
NB=16
CUT=48
APP="100 104"
python3 - "$MNT/a" "$NB" "$CUT" $APP <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
path, nb, cut, app = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), [int(x) for x in sys.argv[4:]]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(nb * 4 * 4096)) == 0
for i in range(nb):
    os.pwrite(fd, (b"A%07d" % (i * 4)) * 512, i * 4 * 4096)
os.fsync(fd)
os.ftruncate(fd, cut * 4096)
os.fsync(fd)
for b in app:
    os.pwrite(fd, (b"A%07d" % b) * 512, b * 4096)
os.fsync(fd)
os.close(fd)
PY
AI="$(stat -c %i "$MNT/a")"
ct_umount "$MNT"

L="$("$LP" "$IMG" leaf "$AI" 2>/dev/null || true)"
[ -n "$L" ] && [ "$L" -gt 0 ] 2>/dev/null || { fail "setup: file a is not a depth-1 tree"; ct_exit; }
SHOW="$("$LP" "$IMG" show "$AI")"
for b in $APP; do
    grep -qE "^ent [0-9]+ block=$b " <<<"$SHOW" ||
        { fail "setup: the leaf has no entry for appended block $b"; ct_exit; }
done
pass "setup: file a is depth 1 (leaf $L, $(grep -c '^ent ' <<<"$SHOW") entries) with blocks $APP appended"

# K: what the kernel left in the root slot.
RR="$("$IBP" "$IMG" rootrange "$AI" 0)"
END="$(sed -n 's/.*end=\([0-9]*\).*/\1/p' <<<"$RR")"
[ "$END" = 0 ] || [ "$END" -gt 104 ] &&
    pass "K: the rebuilt root slot's range is unknown or covers the appends ($RR)" ||
    fail "K: the rebuilt root slot claims to end at $END, short of the blocks appended after it ($RR)"

# F: a stale range planted, whatever the kernel wrote, and the leaf torn
# where no entry lives (one byte in its unused middle: still a leaf,
# its tail no longer verifies).
"$IBP" "$IMG" rootrange "$AI" 0 0 "$CUT" 2>/dev/null
printf '\x5a' | dd of="$IMG" bs=1 seek=$((L * 4096 + 2048)) conv=notrunc status=none
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $AI's extent leaf (block $L) failed its tail checksum" <<<"$OUT" ||
    { fail "setup: fsck did not report the torn leaf: $(grep '^ERR' <<<"$OUT" | head -3)"; ct_exit; }
OUT="$(ct_fsck_repair "$DEV" 2>&1 || true)"
grep -q "salvaged inode $AI's extent leaf (block $L)" <<<"$OUT" ||
    { fail "setup: fsck -r did not salvage the leaf: $(grep -E '^(ERR|NOTE)|refus' <<<"$OUT" | head -4)"; ct_exit; }

ct_mount "$DEV" "$MNT"
RES="$(python3 - "$MNT/a" $APP <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
out = []
for b in [int(x) for x in sys.argv[2:]]:
    d = os.pread(fd, 4096, b * 4096)
    out.append("%d:%s" % (b, "ok" if d == (b"A%07d" % b) * 512 else "zero" if d == b"\0" * 4096 else "other"))
print(" ".join(out))
PY
)"
ct_umount "$MNT"
! grep -qE ':(zero|other)' <<<"$RES" &&
    pass "F: fsck -r kept the entries the stale root range excludes ($RES)" ||
    fail "F: the salvage dropped what the root range excludes: $RES"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" &&
    pass "a second fsck is clean" || fail "a second fsck still finds: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
