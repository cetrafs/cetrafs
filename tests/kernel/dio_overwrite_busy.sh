#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a shared-lock O_DIRECT overwrite that meets a page it cannot invalidate is completed, not reported as 0
#
# An aligned O_DIRECT overwrite of written blocks runs under the shared
# inode_lock (dio_overwrite_shared.sh) through generic_file_direct_write(),
# which returns 0 -- nothing written -- when a cached page in the range
# will not invalidate, leaving the buffered fallback to its caller. The
# shared path returned that 0, so write(2) said nothing was written for
# a nonempty request. The exclusive path now takes the write over.
#
# dio_overwrite_busy makes the next shared-path write meet such a page.
#   1. the write returns its full count;
#   2. the bytes read back.
#
# DISCRIMINATION: dio_overwrite_zero_ok returns the 0, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dio_overwrite_busy dio_overwrite_zero_ok; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
DEV="$(ct_dev 560 diobusy)"
MNT="$(ct_mnt diobusy)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set dio_overwrite_busy 0
ct_param_set dio_overwrite_zero_ok 0
P=/sys/module/cetrafs/parameters

# <zero_ok> -> "<consumed> <returned> <readback ok|bad>"
probe() {
    local f="$MNT/f$1"
    dd if=/dev/zero of="$f" bs=64k count=1 status=none
    sync
    echo "$1" >$P/dio_overwrite_zero_ok
    echo 1 >$P/dio_overwrite_busy
    python3 - "$f" <<'PY'
import mmap, os, sys
buf = mmap.mmap(-1, 4096); buf.write(b"\xa5" * 4096)
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
n = os.pwrite(fd, buf, 0); os.close(fd)
print(n); sys.stdout.flush()
PY
}
read_ok() {
    python3 - "$1" <<'PY'
import mmap, os, sys
buf = mmap.mmap(-1, 4096)
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
os.preadv(fd, [buf], 0); os.close(fd)
print("ok" if buf[:] == b"\xa5" * 4096 else "bad"); sys.stdout.flush()
PY
}

n="$(probe 0)"
left="$(cat $P/dio_overwrite_busy)"
echo 0 >$P/dio_overwrite_busy
echo 0 >$P/dio_overwrite_zero_ok
[ "$left" = 0 ] || { fail "setup: the write did not take the shared path (knob left at $left)"; ct_exit; }
[ "$n" = 4096 ] && pass "1: the write met an uninvalidatable page and still returned 4096" ||
    fail "1: the write returned $n"
[ "$(read_ok "$MNT/f0")" = ok ] && pass "2: the bytes read back" || fail "2: the bytes did not land"

n="$(probe 1)"
left="$(cat $P/dio_overwrite_busy)"
echo 0 >$P/dio_overwrite_busy
echo 0 >$P/dio_overwrite_zero_ok
[ "$left" = 0 ] && [ "$n" = 0 ] && pass "control: the old path returns 0 for a 4096-byte write -- the suite discriminates" ||
    fail "control: knob left $left, write returned $n -- the suite cannot tell"
ct_umount "$MNT"
ct_exit
