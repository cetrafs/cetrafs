#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch that frees nothing must publish nothing
#
# fallocate(PUNCH_HOLE) rebuilt and republished the whole extent tree on
# every call, even when the dry run said zero blocks would be freed. That
# rebuild writes leaf/index blocks through the journal -- two cache
# flushes and three synchronous waits each.
#
# It is the common case, not an edge case: qemu-img convert through the
# `zeroinit:` driver turns writes-of-zeroes into write_zeroes, which
# arrives as PUNCH_HOLE, and against a freshly created sparse target most
# of those ranges are already holes. Measured on the real LUN as 1739
# such calls at 5.1 ms each.
#
# record_writes counts inode-record publishes, which is exactly what a
# no-op punch must not do.
#
# Discrimination: drop the freed==0 short-circuit and record_writes
# climbs once per punch, failing the first assertion.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 pnoop)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pnoop)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
writes() { sed -n 's/^record_writes: //p' "$PROC"; }

# A 4 MiB file that is ENTIRELY a hole: size set by truncate, nothing
# allocated. Every punch into it frees nothing.
truncate -s 4M "$MNT/sparse"
sync

W0="$(writes)"
for off in 0 262144 524288 786432 1048576 1310720 1572864 1835008 2097152 2359296; do
    fallocate -p -n -o "$off" -l 65536 "$MNT/sparse" 2>/dev/null || fail "punch failed at $off"
done
W1="$(writes)"
NOOP=$((W1 - W0))
log "10 no-op punches cost $NOOP inode-record writes"

[ "$NOOP" -eq 0 ] ||
    fail "a punch that frees nothing published $NOOP record writes -- it is still rebuilding the tree"

# A punch that DOES free blocks must still work, and must still publish.
dd if=/dev/zero of="$MNT/real" bs=1M count=4 conv=fsync status=none
sync
BEFORE="$(stat -f -c %f "$MNT")"
W2="$(writes)"
fallocate -p -n -o 0 -l 1048576 "$MNT/real" || fail "real punch failed"
sync
W3="$(writes)"
AFTER="$(stat -f -c %f "$MNT")"

REAL=$((W3 - W2))
[ "$REAL" -gt 0 ] || fail "a punch that frees blocks published nothing -- it was skipped"
# Bounded ABOVE as well: unbounded, this would pass against code that
# republished the tree a hundred times per punch.
[ "$REAL" -le 8 ] || fail "one real punch published $REAL inode records -- it is rebuilding repeatedly"
[ "$((AFTER - BEFORE))" -ge 256 ] ||
    fail "punching 1 MiB freed $((AFTER - BEFORE)) blocks, expected >= 256"
log "real punch freed $((AFTER - BEFORE)) blocks and published $((W3 - W2)) record writes"

# The punched region must read as zeros, and the rest must survive.
python3 - "$MNT/real" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
assert d[:1048576] == b"\0" * 1048576, "punched region is not zero"
assert len(d) == 4 << 20, "size changed: %d" % len(d)
PY

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after punching"

pass "a no-op punch publishes nothing; a real punch still frees and publishes"

ct_exit
