#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a verdict read before an invalidation is never served after it
#
# Under nofilelock every write asks "does a peer have this file open?",
# and the answer is cached for a second. Invalidations -- an open, a
# suspend, and cetrafs_lock_expire_verdicts() ahead of evict, truncate
# and punch, whose decisions free blocks -- cleared a `valid` bool. A fill
# already in flight then set it again, with a verdict read from the
# device BEFORE the invalidation: the destructive path's own check was
# served a pre-invalidation answer. And with plain stores, arm64 could
# show `valid` ahead of the verdict (audit 2026-11-05, N8).
#
# Staged: a write's verdict fill stalls between its device read and its
# publish (verdict_fill_stall_ms, one fill); an open() of the file
# invalidates meanwhile; once the stalled fill has published, the next
# write must go back to the device (verdict_fills moves), within the
# second the old cache would have trusted.
#
# DISCRIMINATION: proven 2026-11-05 with the old bools restored (stall
# kept): the next write is served the stalled fill's verdict and
# verdict_fills does not move.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/verdict_fill_stall_ms ] || { skip "verdict_fill_stall_ms is missing"; ct_exit; }

DEV="$(ct_dev 560 vfence)"
MNT="$(ct_mnt vfence)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
INFO="$(ct_procdir "$DEV")/info"
grep -q '^verdict_fills:' "$INFO" || { skip "no verdict_fills counter"; ct_exit; }
dd if=/dev/urandom of="$MNT/vm.img" bs=4096 count=16 conv=fsync status=none

OUT="$(ct_tmp vfence-out)"
python3 - "$MNT/vm.img" "$INFO" >"$OUT" 2>&1 <<'PY' || true
import mmap, os, sys, threading, time
path, info = sys.argv[1], sys.argv[2]
def fills():
    for l in open(info):
        if l.startswith("verdict_fills:"):
            return int(l.split()[1])
buf = mmap.mmap(-1, 4096)
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
os.pwrite(fd, buf, 0)
time.sleep(1.3)                                   # the cached verdict is now too old
a = fills(); os.pwrite(fd, buf, 0); b = fills()
print("prime", b - a)                              # setup: a write does ask
time.sleep(1.3)
open("/sys/module/cetrafs/parameters/verdict_fill_stall_ms", "w").write("600")
t0 = time.monotonic()
r = threading.Thread(target=lambda: os.pwrite(fd, buf, 4096))
r.start()
time.sleep(0.2)
os.close(os.open(path, os.O_RDONLY))               # an invalidation while that fill is in flight
r.join()
f1 = fills()
os.pwrite(fd, buf, 8192)                           # must not be served the stalled verdict
f2 = fills()
print("elapsed_ms", int((time.monotonic() - t0) * 1000))
print("after", f2 - f1)
PY
log "$(tr '\n' ' ' <"$OUT")"
P="$(sed -n 's/^prime //p' "$OUT")"
E="$(sed -n 's/^elapsed_ms //p' "$OUT")"
A="$(sed -n 's/^after //p' "$OUT")"
[ "$P" = 1 ] || { fail "setup: a write past the cache's second did not ask the device (fills +${P:-?}): $(tr '\n' ' ' <"$OUT")"; ct_exit; }
[ -n "$E" ] && [ "$E" -lt 950 ] || { fail "setup: the check came ${E:-?} ms after the stalled fill began -- the old cache would have expired it anyway"; ct_exit; }
pass "setup: writes ask the device once the verdict is a second old, and the check landed ${E} ms in"
[ "$A" -ge 1 ] && pass "the write after the invalidation went back to the device (fills +$A)" ||
    fail "the write after the invalidation was served the verdict of a fill that began before it (fills +$A)"
ct_param_set verdict_fill_stall_ms 0
ct_umount "$MNT"
ct_exit
