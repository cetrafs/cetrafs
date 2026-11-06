#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag step refuses a preallocated extent that appeared since the last step
#
# The mover is a block-for-block copy that rebuilds the file as plain
# extents, so it refuses a file with a preallocated (uninit) extent: those
# blocks were never written, read as zeros only because of the flag, and
# still hold a previous owner's bytes. It asked once, before the first
# step. Between steps inode_lock is dropped, and a punch of the unmoved
# tail followed by a fallocate over it restores the block count and the
# density -- the two things the per-step re-check compared -- while
# mapping never-written blocks. The next step copied their stale bytes
# and published them (audit 2026-11-06 M8). Every step now refuses
# has_uninit.
#
# Staged as defrag_prefix_moved.sh does: a 4 MiB file fragmented across
# the gaps of a filler that held 'F' bytes, defrag_step_delay_ms holding
# the gap between steps open, and the punch+fallocate landing in it. The
# tail must read zeros afterwards.
#
# DISCRIMINATION: with the per-step check comparing count and density
# only, the tail reads back stale bytes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/defrag_step_delay_ms ] || { skip "defrag_step_delay_ms is missing"; ct_exit; }

IMG="$(ct_image 560 defraguninit)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt defraguninit)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

python3 - "$MNT" <<'PY'
import os, sys
m = sys.argv[1]
CH = 512 * 1024
os.mkdir(m + "/filler")
n = 0
try:
    while True:
        fd = os.open("%s/filler/%d" % (m, n), os.O_WRONLY | os.O_CREAT, 0o644)
        os.write(fd, b'F' * CH)
        os.close(fd)
        n += 1
except OSError:
    pass                                  # full
for i in range(0, n // 2, 2):             # gaps, first half only
    try:
        os.unlink("%s/filler/%d" % (m, i))
    except OSError:
        pass
f = os.open(m + "/frag", os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(1024):                     # 4 MiB across 512 KiB gaps
    os.write(f, bytes([(i & 0x7f) | 0x80]) * 4096)
os.fsync(f)
os.close(f)
for i in range(n // 2, n):                # a contiguous run for the destination
    try:
        os.unlink("%s/filler/%d" % (m, i))
    except OSError:
        pass
PY
sync

MARK="$(dmesg_mark)"
ct_param_set defrag_step_delay_ms 900
"$ROOT/userspace/defrag.cetra" "$MNT/frag" >/dev/null 2>&1 &
DPID=$!
sleep 1
# The unmoved tail: punched, then preallocated again. Count and density
# come back; the tail's blocks are never-written.
python3 - "$MNT/frag" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
off, ln = 960 * 4096, 64 * 4096
if libc.fallocate(f, 0x02 | 0x01, ctypes.c_long(off), ctypes.c_long(ln)) != 0:
    sys.exit("punch failed: %d" % ctypes.get_errno())
if libc.fallocate(f, 0x01, ctypes.c_long(off), ctypes.c_long(ln)) != 0:
    sys.exit("fallocate failed: %d" % ctypes.get_errno())
os.fsync(f)
os.close(f)
PY
wait "$DPID" 2>/dev/null || true
ct_param_set defrag_step_delay_ms 0
dmesg_since "$MARK" | grep -qiE "defrag" || log "note: the defrag logged nothing"
sync

RC=0
python3 - "$MNT/frag" <<'PY' || RC=$?
import os, sys
f = os.open(sys.argv[1], os.O_RDONLY)
os.posix_fadvise(f, 0, 1024 * 4096, os.POSIX_FADV_DONTNEED)
tail = os.pread(f, 64 * 4096, 960 * 4096)
head = os.pread(f, 960 * 4096, 0)
os.close(f)
bad_head = [i for i in range(960) if head[i * 4096:(i + 1) * 4096] != bytes([(i & 0x7f) | 0x80]) * 4096]
print("tail nonzero blocks: %d, head wrong blocks: %d" % (sum(1 for i in range(64) if any(tail[i * 4096:(i + 1) * 4096])), len(bad_head)))
sys.stdout.flush()
os._exit((1 if any(tail) else 0) | (2 if bad_head else 0))
PY
[ $((RC & 1)) = 0 ] && pass "the preallocated tail still reads zeros after the defrag" ||
    fail "the defrag published a preallocated range's stale bytes as data"
[ $((RC & 2)) = 0 ] && pass "the rest of the file is unchanged" || fail "the file's written blocks changed"
ct_umount "$MNT"
FSCK="$(ct_fsck "$DEV" 2>&1)" || fail "fsck found faults: $(echo "$FSCK" | grep -i err | head -2)"
ct_exit
