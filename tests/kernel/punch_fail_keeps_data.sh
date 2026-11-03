#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch whose record write fails leaves the file's contents as they were
#
# Punch zeroed the in-hole halves of the boundary blocks through the
# write path and dropped the page cache over the hole -- dirty pages
# included -- before the record write that makes the punch real. When
# that write failed nothing was put back: the dropped blocks stayed
# mapped and read back their older on-disk contents (neither the data
# last written nor zeroes), and writeback made the zeroed boundaries
# durable. Same shape as truncate (truncate_fail_keeps_data.sh).
#
# DISCRIMINATION (measured on the old order): the contents change, both
# right after the failed punch and after a remount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FAIL_PARAM=/sys/module/cetrafs/parameters/fail_extent_record_write
[ -w "$FAIL_PARAM" ] || { skip "fail_extent_record_write is missing"; ct_exit; }

DEV="$(ct_dev 560 pfk)"
MNT="$(ct_mnt pfk)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Four blocks of A on the device, then B over the middle of them left
# DIRTY: the data the old order dropped without writing.
python3 -I - "$MNT/f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
os.pwrite(fd, b"A" * 16384, 0)
os.fsync(fd)
os.pwrite(fd, b"B" * 10000, 3000)
os.close(fd)
PY
WANT="$(sha256sum <"$MNT/f" | cut -d' ' -f1)"
pass "setup: a 16384-byte file with dirty data across the range to punch"

punch() { # <offset> <len>
    python3 -I - "$MNT/f" "$1" "$2" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR)
r = libc.fallocate(fd, 3, ctypes.c_long(int(sys.argv[2])), ctypes.c_long(int(sys.argv[3])))  # PUNCH_HOLE|KEEP_SIZE
os.close(fd)
sys.exit(0 if r == 0 else 1)
PY
}

ct_param_set fail_extent_record_write 1
if punch 1000 12000; then
    ct_param_set fail_extent_record_write 0
    fail "setup: the injected failure did not fail the punch"
    ct_exit
fi
ct_param_set fail_extent_record_write 0
pass "setup: the punch failed as instructed"

check() { # <when>
    [ "$(sha256sum <"$MNT/f" | cut -d' ' -f1)" = "$WANT" ] && pass "$1: the contents are intact" ||
        fail "$1: the failed punch changed the file's contents"
}
check "right after"
sync
echo 3 >/proc/sys/vm/drop_caches
check "after writeback"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
check "after a remount"

log "control: the same punch with no injection"
punch 1000 12000 || fail "control: the punch failed"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
python3 -I - "$MNT/f" <<'PY' && pass "control: zeroes inside the hole, data outside it" || fail "control: wrong contents after the punch"
import sys
d = open(sys.argv[1], "rb").read()
ok = len(d) == 16384 and d[:1000] == b"A" * 1000 and d[1000:13000] == b"\0" * 12000 and d[13000:] == b"A" * 3384
sys.exit(0 if ok else 1)
PY
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "control: fsck clean" ||
    fail "control: fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
