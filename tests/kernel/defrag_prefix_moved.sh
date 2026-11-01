#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the defragmenter must confirm the prefix it moved is still where it put it
#
# The incremental mover drops inode_lock between steps -- that is what
# makes it incremental, and what lets a local writer in. Its per-step
# re-check caught a different file (generation) and a resized one
# (nblocks), but not this:
#
#   punch the committed prefix, then write it again.
#
# The block count comes back, so that half passed, while those logical
# blocks now live on completely different physical ones. The next commit
# republishes [0, moved) as living at dst_base: the rewritten data lost,
# the blocks around it corrupted, and 16 blocks leaked -- all three
# measured below.
#
# The prefix is one contiguous run by construction, so confirming it is
# a walk: every extent covering it must be exactly dst_base + offset.
#
# WHY THE KNOB: the step's density re-check happens to catch this one
# too, because today's writers APPEND the rewritten extent and the array
# stops being in logical order. It is an accident of ordering, not a
# statement about where the prefix lives, and it made the walk
# untestable -- removing the walk left the suite green. So the suite
# relaxes the density half (defrag_skip_dense_recheck) and makes the
# walk the SOLE guard, which is the only way to learn whether it works.
#
# defrag_step_delay_ms holds the gap open. In production it is as short
# as the mover can make it, which is precisely why a test cannot reach
# it otherwise.
#
# Discrimination (measured, not assumed): with the knob set and the
# prefix walk removed, the first assertion fails, the second reports
# blocks 256.. wrong, and fsck reports 16 leaked blocks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 defragpfx)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt defragpfx)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# A file fragmented enough that the move takes several steps, DENSE
# (the mover refuses holes, so logical gaps are no use), and with
# contiguous room left for the destination. Those three pull against
# each other: fragmenting means filling the volume, and the mover needs
# a free run as large as the file.
#
# So: fill it, punch gaps in the FIRST half only, write the victim into
# those gaps, then free the second half as one contiguous run.
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
    os.write(f, bytes([i & 0xff]) * 4096)
os.fsync(f)
os.close(f)
for i in range(n // 2, n):                # a contiguous run for the destination
    try:
        os.unlink("%s/filler/%d" % (m, i))
    except OSError:
        pass
PY
sync
BEFORE="$(md5sum < "$MNT/frag")"

MARK="$(dmesg_mark)"
ct_param_set defrag_step_delay_ms 900
ct_param_set defrag_skip_dense_recheck 1   # see WHY THE KNOB above

"$ROOT/userspace/defrag.cetra" "$MNT/frag" >/dev/null 2>&1 &
DPID=$!
sleep 1

# Into the gap: punch the start of the file and write it again. Same
# block count, same density, different physical blocks.
python3 - "$MNT/frag" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
libc.fallocate(f, 0x02 | 0x01, ctypes.c_long(0), ctypes.c_long(16 * 4096))
os.pwrite(f, b'R' * (16 * 4096), 0)
os.fsync(f)
os.close(f)
PY

wait "$DPID" 2>/dev/null || true
ct_param_set defrag_step_delay_ms 0
ct_param_set defrag_skip_dense_recheck 0
sync

# THE assertion: the rewritten bytes are the ones that survive. If the
# mover republished its own idea of the prefix, these are gone.
# Under set -e a non-zero python kills the script before the assertion
# can speak -- which is how an earlier version of this reported ABORT
# instead of the failure it had just measured. Capture, never trust $?
# on the next line.
RC=0
python3 - "$MNT/frag" <<'PY' || RC=$?
import os, sys
f = os.open(sys.argv[1], os.O_RDONLY)
os.posix_fadvise(f, 0, 1024 * 4096, os.POSIX_FADV_DONTNEED)
got = os.pread(f, 16 * 4096, 0)
os.close(f)
sys.stdout.flush()
os._exit(0 if got == b'R' * (16 * 4096) else 1)
PY
[ "$RC" = 0 ] &&
    pass "the rewrite survived: the mover did not republish its stale idea of the prefix" ||
    fail "the first 64 KiB are not what was written into the gap -- the move overwrote a rewritten prefix"

# The rest of the file must be intact too, defragmented or not.
RC2=0
python3 - "$MNT/frag" <<'PY' || RC2=$?
import os, sys
f = os.open(sys.argv[1], os.O_RDONLY)
os.posix_fadvise(f, 0, 1024 * 4096, os.POSIX_FADV_DONTNEED)
bad = [i for i in range(16, 1024) if os.pread(f, 4096, i * 4096) != bytes([i & 0xff]) * 4096]
os.close(f)
print("blocks wrong past the rewrite: %s" % (bad[:4] if bad else "none"))
sys.stdout.flush()
os._exit(1 if bad else 0)
PY
[ "$RC2" = 0 ] &&
    pass "and the rest of the file is unchanged" ||
    fail "blocks past the rewritten range changed"

ct_umount "$MNT"
FSCK="$(ct_fsck "$DEV" 2>&1)" || fail "fsck found faults: $(echo "$FSCK" | grep -i err | head -2)"
echo "$FSCK" | grep -q "leaked" &&
    fail "the abandoned move leaked blocks: $(echo "$FSCK" | grep leaked | head -1)" ||
    pass "fsck clean -- nothing referenced twice, nothing leaked"

ct_exit
