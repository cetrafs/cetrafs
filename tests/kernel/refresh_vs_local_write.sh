#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lookup-time refresh never stamps the device's size over a concurrent local write
#
# cetrafs_apply_raw_to_vfs_inode() refuses to refresh a DIRTY inode --
# local changes are newer than the device -- and then stores the
# device's size, blocks and times. The check and the stores were not
# atomic against the writers: an extending write landing between them
# (i_size set, the inode not yet dirtied, or dirtied after the check)
# had its size replaced by the device's older one.
#
# The refresh runs for a file this node has open only when a peer has
# it open too (nofilelock: a VM mid-migration -- exactly when both sides
# write). force_foreign_opener stands in for the peer, as in
# nofilelock_coherency.sh; apply_refresh_stall_ms widens the window.
# Each round: write A and fsync (the inode is clean, the device says A),
# stat the path from a second thread (the refresh judges "clean" and
# stalls), write B inside the stall, wait it out, look at the size.
#
# DISCRIMINATION (measured on the unfixed code): 20 of 20 rounds saw
# the size go back to A's after B had returned.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
N=20

DEV="$(ct_dev 560 refrace)"
MNT="$(ct_mnt refrace)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set force_foreign_opener 1
ct_param_set apply_refresh_stall_ms 60

out="$(python3 - "$MNT/f" "$N" <<'PY'
import os, sys, time, threading
path, n = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
bad = []
stalled = 0
for i in range(n):
    os.pwrite(fd, b'x' * 4096, (2 * i) * 4096)
    os.fsync(fd)
    t0 = time.monotonic()
    th = threading.Thread(target=lambda: os.stat(path))
    th.start()
    time.sleep(0.02)
    os.pwrite(fd, b'x' * 4096, (2 * i + 1) * 4096)
    th.join()
    if time.monotonic() - t0 >= 0.05:
        stalled += 1  # the refresh really ran (and stalled) this round
    time.sleep(0.02)
    sz = os.fstat(fd).st_size
    if sz != (2 * i + 2) * 4096:
        bad.append((i, sz))
os.fsync(fd)
os.close(fd)
print(stalled, len(bad), bad[:3])
PY
)"
ct_param_set apply_refresh_stall_ms 0
ct_param_set force_foreign_opener 0
read -r stalled nbad rest <<<"$out"
[ "$stalled" -ge $((N / 2)) ] && pass "setup: the refresh ran inside $stalled of $N rounds" ||
    { fail "setup: the refresh stalled in only $stalled of $N rounds -- the race was not arranged"; ct_exit; }
[ "$nbad" = 0 ] && pass "no refresh moved i_size back over a local write" ||
    fail "$nbad of $N rounds saw i_size go back to the device's after the write returned: $rest"

ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
