#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate(ALLOCATE) must be killable, and must respect RLIMIT_FSIZE
#
# cetrafs_do_allocate() walks one block per iteration up to the format's
# ceiling, under inode_lock. A 16 TiB request is billions of passes and
# it had neither cond_resched() nor a fatal-signal check, so it was an
# uninterruptible occupation of a CPU and of the inode -- the same shape
# as the fiemap spin, reached by an ordinary fallocate(2).
#
# It also never called inode_newsize_ok(), so without KEEP_SIZE -- where
# the call grows i_size and is therefore a size change -- RLIMIT_FSIZE
# did not apply. A process limited to a 1 MiB file could preallocate
# whatever the device could back.
#
# Stopping early leaves the range partially preallocated. That is
# allowed, and it is what the other filesystems do: the blocks added are
# real, recorded and freeable, which is better than losing them.
#
# Discrimination: drop the fatal_signal_pending() check and the kill
# below does not land -- the process stays in D/R state and the suite's
# timeout fires instead. Drop inode_newsize_ok() and the rlimit
# assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 1400 falloclimit)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt falloclimit)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# 1. RLIMIT_FSIZE. Without KEEP_SIZE the call grows i_size, so the limit
# applies -- and the kernel is expected to refuse rather than allocate.
RC=0
python3 - "$MNT/rl" <<'PY' || RC=$?
import ctypes, os, resource, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
resource.setrlimit(resource.RLIMIT_FSIZE, (1 << 20, 1 << 20))
# SIGXFSZ would kill us where the limit is enforced by the write path;
# here the refusal must come back as an error instead.
import signal
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
r = libc.fallocate(f, 0, ctypes.c_long(0), ctypes.c_long(64 << 20))
e = ctypes.get_errno()
sz = os.fstat(f).st_size
os.close(f)
print("rc=%d errno=%d size=%d" % (r, e, sz))
sys.stdout.flush()
os._exit(0 if (r != 0 and sz <= (1 << 20)) else 1)
PY
[ "$RC" = 0 ] &&
    pass "fallocate past RLIMIT_FSIZE is refused and the file does not grow" ||
    fail "a 64 MiB preallocation succeeded under a 1 MiB RLIMIT_FSIZE -- inode_newsize_ok() is not being asked"

# 2. Killable.
#
# A huge range is not enough to test this: the loop ends at ENOSPC, and
# on any image a test can afford that arrives in well under a second --
# the first version of this assertion passed against the unfixed kernel
# for exactly that reason. fallocate_block_delay_us makes the loop long
# without making the device big, so a SIGKILL has something to land in.
# At 200us a block the walk needs over a minute to reach ENOSPC, far
# past the patience below.
ct_param_set fallocate_block_delay_us 200
python3 - "$MNT/big" <<'PY' &
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
# 1 GiB: inside the format's per-file ceiling (a larger ask is
# refused with EFBIG before the loop even starts, which is how the
# first version of this measured nothing), and more blocks than the
# device can back, so the walk runs until ENOSPC.
libc.fallocate(f, 0x01, ctypes.c_long(0), ctypes.c_long((1 << 30) - (1 << 20)))
os.close(f)
PY
PID=$!
sleep 2
kill -9 "$PID" 2>/dev/null || true

GONE=0
for _ in $(seq 1 100); do
    kill -0 "$PID" 2>/dev/null || { GONE=1; break; }
    sleep 0.2
done
wait "$PID" 2>/dev/null || true

ct_param_set fallocate_block_delay_us 0

[ "$GONE" = 1 ] &&
    pass "a long preallocation dies when killed" ||
    fail "the process survived SIGKILL for 20s -- the loop checks no signals, so nothing can stop it"

# 3. And the filesystem is still usable afterwards: a killed allocation
# leaves a partial range, not a wedged inode.
RC3=0
timeout 20 stat "$MNT/big" >/dev/null 2>&1 || RC3=$?
[ "$RC3" != 124 ] &&
    pass "the inode lock came back with it" ||
    fail "stat hangs: the killed allocation left inode_lock held"

timeout 30 rm -f "$MNT/big" "$MNT/rl" &&
    pass "the partially preallocated file can still be removed" ||
    fail "removing the partially preallocated file hangs or fails"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after a killed preallocation"
pass "fsck clean"

ct_exit
