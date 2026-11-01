#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a writeback stat publish never moves the in-core i_size back under a concurrent extending write
#
# The file-sector publish (cetrafs_write_vfs_inode) merges size, blocks
# and times three ways against the device and used to write the merged
# value back into the in-core inode from inside the CAS -- a value it
# had read from i_size a moment earlier, with no lock the write path
# holds. An extending write that set i_size in between was undone in
# core: the file's size went back, the next publish carried the
# regressed size to the device, and the extent past it became a tail no
# size reaches. fsck calls that legal; a content oracle does not
# (churn_oracle, "SIZE MISMATCH ... should be 1572864").
#
# fd_merge_stall_ms widens the read-to-merge gap so a writer can land in
# it on demand: each round writes A (extending), lets a sync(2) publish
# read that size and stall, writes B (extending again) inside the
# stall, waits it out and looks at the size.
#
# DISCRIMINATION (measured on the unfixed code): 15 of 30 rounds saw
# the size go back to A's after B had returned.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
N=30

DEV="$(ct_dev 560 statrace)"
MNT="$(ct_mnt statrace)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set fd_merge_stall_ms 40

out="$(python3 - "$MNT/f" "$N" <<'PY'
import os, sys, time, threading
path, n = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
stop = False
syncs = 0
def syncer():
    global syncs
    while not stop:
        os.sync(); syncs += 1
t = threading.Thread(target=syncer); t.start()
bad = []
for i in range(n):
    # A extends and dirties the inode; the syncer's publish reads that
    # size and stalls; B extends again INSIDE the stall; then wait out
    # the stall and look.
    os.pwrite(fd, b'x' * 4096, (2 * i) * 4096)
    time.sleep(0.01)
    os.pwrite(fd, b'x' * 4096, (2 * i + 1) * 4096)
    time.sleep(0.25)
    sz = os.fstat(fd).st_size
    if sz != (2 * i + 2) * 4096:
        bad.append((i, sz))
stop = True
t.join()
os.fsync(fd)
os.close(fd)
print(syncs, len(bad), bad[:3])
PY
)"
ct_param_set fd_merge_stall_ms 0
read -r syncs nbad rest <<<"$out"
[ "$syncs" -ge 10 ] && pass "setup: $syncs writeback publishes raced $((2 * N)) appends" ||
    { fail "setup: only $syncs syncs ran"; ct_exit; }
[ "$nbad" = 0 ] && pass "i_size never went back under a concurrent publish" ||
    fail "$nbad of $N appends saw i_size move back after the write returned: $rest"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
sz="$(stat -c %s "$MNT/f")"
[ "$sz" = $((2 * N * 4096)) ] && pass "the size survives a remount ($sz)" ||
    fail "after remount the size is $sz, not $((2 * N * 4096)) -- the regressed size was published"
ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
