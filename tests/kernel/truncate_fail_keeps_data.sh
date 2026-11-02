#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a truncate whose record write fails leaves the file's size and data as they were
#
# The shrink zeroed the tail of the block at the new end and dropped the
# page cache past it -- dirty pages included -- and set the in-core size,
# all BEFORE the record write that makes the truncate real. When that
# write failed nothing was put back: the dirty data was gone, the zeroed
# tail went out with ordinary writeback, and so did the smaller size,
# over extents that still held every block. A truncate that reported an
# error had quietly truncated, and lost data it was never asked to touch.
#
# The failure needs fail_extent_record_write: nothing a test can supply
# makes that write fail.
#
# DISCRIMINATION (measured on the old order): the size reads 5000 after
# the failed truncate and after a remount, and the data past it is gone.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FAIL_PARAM=/sys/module/cetrafs/parameters/fail_extent_record_write
[ -w "$FAIL_PARAM" ] || { skip "fail_extent_record_write is missing"; ct_exit; }

DEV="$(ct_dev 560 tfk)"
MNT="$(ct_mnt tfk)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Three blocks: the first two durable, then the tail of the second and
# the whole third rewritten and left DIRTY in the page cache -- the data
# the old order dropped without writing.
python3 -I - "$MNT/f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
os.pwrite(fd, b"A" * 8192, 0)
os.fsync(fd)
os.pwrite(fd, b"B" * 7288, 4904)
os.close(fd)
PY
WANT="$(sha256sum <"$MNT/f" | cut -d' ' -f1)"
[ "$(stat -c %s "$MNT/f")" = 12192 ] || { fail "setup: the file is $(stat -c %s "$MNT/f") bytes, not 12192"; ct_exit; }
pass "setup: a 12192-byte file with dirty data past the new end"

echo 1 >"$FAIL_PARAM"
if truncate -s 5000 "$MNT/f" 2>/dev/null; then
    echo 0 >"$FAIL_PARAM"
    fail "setup: the injected failure did not fail the truncate"
    ct_exit
fi
echo 0 >"$FAIL_PARAM"
pass "setup: the truncate failed as instructed"

check() { # <when>
    local size sum
    size="$(stat -c %s "$MNT/f")"
    sum="$(sha256sum <"$MNT/f" | cut -d' ' -f1)"
    [ "$size" = 12192 ] && pass "$1: the size is still 12192" ||
        fail "$1: the failed truncate left the size at $size"
    [ "$sum" = "$WANT" ] && pass "$1: the data is intact" ||
        fail "$1: the failed truncate changed the file's contents"
}
check "right after"
sync
echo 3 >/proc/sys/vm/drop_caches
check "after writeback"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
check "after a remount"

log "control: the same truncate with no injection"
truncate -s 5000 "$MNT/f" || fail "control: the truncate failed"
[ "$(stat -c %s "$MNT/f")" = 5000 ] && pass "control: the size is 5000" ||
    fail "control: the size is $(stat -c %s "$MNT/f")"
# The tail of the block at the new end must read as zero once regrown.
truncate -s 8192 "$MNT/f"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
python3 -I - "$MNT/f" <<'PY' && pass "control: the head is kept and the old tail reads zero" || fail "control: wrong contents after regrow"
import sys
d = open(sys.argv[1], "rb").read()
sys.exit(0 if d[:4904] == b"A" * 4904 and d[4904:5000] == b"B" * 96 and d[5000:] == b"\0" * 3192 else 1)
PY
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "control: fsck clean" ||
    fail "control: fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
