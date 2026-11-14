#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a second bitmap flush waits for the one that took its group's mark
#
# The allocation-bitmap flush (cetrafs_alloc_flush_bitmaps()) takes each
# Block Group's dirty mark before it writes that group's bitmap blocks.
# Two flushers were not serialised: the second, arriving while the
# first one's write was out, found the mark clear, skipped the group and
# returned 0 -- and its caller published extents whose allocation bits
# were in a write that had not completed. A node dying there leaves
# blocks referenced and FREE (rule 8; audit 2026-11-14 A1).
#
# Two files get blocks in the same group by O_DIRECT writes, nothing
# synced, so one mark covers both. File a's fsync takes the mark and is
# held (alloc_flush_stall_ms); file b's fsync, started inside the hold,
# must not return before a's flush has written the bits.
#
# DISCRIMINATION: alloc_flush_unserialised lets the second flusher go;
# b's fsync then returns at once, inside the hold.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in alloc_flush_stall_ms alloc_flush_unserialised; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
DEV="$(ct_dev 560 bmflush)"
MNT="$(ct_mnt bmflush)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_flush_stall_ms 0
ct_param_set alloc_flush_unserialised 0

HOLD=2000
# <unserialised 0|1> -> milliseconds b's fsync took, started inside a's hold
race() {
    rm -f "$MNT/a" "$MNT/b"
    sync
    ct_param_set alloc_flush_unserialised "$1"
    python3 - "$MNT" "$HOLD" <<'PY'
import mmap, os, sys, threading, time
mnt, hold = sys.argv[1], int(sys.argv[2])
buf = mmap.mmap(-1, 1 << 16)
buf.write(b"x" * (1 << 16))
fds = {}
for n in ("a", "b"):
    fds[n] = os.open(os.path.join(mnt, n), os.O_CREAT | os.O_WRONLY | os.O_DIRECT, 0o644)
    os.pwrite(fds[n], buf, 0)  # allocates; nothing synced: one mark covers both
open("/sys/module/cetrafs/parameters/alloc_flush_stall_ms", "w").write(str(hold))
t = threading.Thread(target=os.fsync, args=(fds["a"],))
t.start()
time.sleep(0.3)  # a's flush has taken the mark and is held
t0 = time.time()
os.fsync(fds["b"])
print(int((time.time() - t0) * 1000))
t.join()
for fd in fds.values():
    os.close(fd)
PY
    ct_param_set alloc_flush_stall_ms 0
    ct_param_set alloc_flush_unserialised 0
}

MS="$(race 0)"
MS_OFF="$(race 1)"
log "b's fsync inside a's ${HOLD} ms hold: ${MS} ms (unserialised: ${MS_OFF} ms)"
[ "$MS_OFF" -lt 1000 ] && pass "control: unserialised, b's fsync returned inside the hold (${MS_OFF} ms) -- the window is real" ||
    fail "control: unserialised, b's fsync still took ${MS_OFF} ms -- the suite cannot see the race"
[ "$MS" -ge 1200 ] && pass "b's fsync waited for the flush that took its group's mark (${MS} ms)" ||
    fail "b's fsync returned after ${MS} ms, inside a's flush -- its bits may not be on the device"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
