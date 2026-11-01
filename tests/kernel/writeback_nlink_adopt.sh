#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# writeback never puts back a link count that a concurrent local unlink just dropped
#
# cetrafs_write_vfs_inode() adopts the namespace-domain fields (nlink,
# mode, uid, gid) from the record it read fresh at its start -- and did
# so after more I/O, with no lock the namespace operations hold. An
# unlink landing in between dropped nlink to 0 on the device and in
# core, and writeback then stamped its earlier read -- nlink 1 -- back
# into core: stat on the open fd reported a link the file no longer
# has. Evict gates the free on the in-core count, so a close inside
# that state frees nothing (the inode leaks until fsck or the scrub's
# orphan reclaim); in this suite a later writeback re-adopted 0 before
# the close, and fsck stays clean either way -- the in-core count is
# the observable.
#
# write_inode_read_stall_ms holds the read-to-adopt window open: a
# sync(2) starts the publish of a dirty, open file and stalls; the file
# is unlinked inside the stall; then the open fd's link count is read.
#
# DISCRIMINATION (measured on the unfixed code): 5 of 5 unlinked files
# read nlink 1 on their open fd.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 wbnlink)"
MNT="$(ct_mnt wbnlink)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_param_set scrub 0 # the orphan reclaim would hide the leak from fsck
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set write_inode_read_stall_ms 300

out="$(python3 - "$MNT" <<'PY'
import os, sys, time, threading
mnt = sys.argv[1]
res = []
for i in range(5):
    p = "%s/f%d" % (mnt, i)
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
    os.pwrite(fd, b'y' * 65536, 0)
    os.fsync(fd)
    os.pwrite(fd, b'z' * 4096, 65536)  # dirty again: the next sync publishes
    t0 = time.monotonic()
    th = threading.Thread(target=os.sync)
    th.start()
    time.sleep(0.1)  # inside the stall
    os.unlink(p)
    th.join()
    took = time.monotonic() - t0
    res.append((os.fstat(fd).st_nlink, int(took * 1000)))
    os.close(fd)
print(" ".join("%d:%d" % r for r in res))
PY
)"
ct_param_set write_inode_read_stall_ms 0
log "per round (nlink after unlink : sync ms): $out"
stalled=0
bad=0
for r in $out; do
    [ "${r#*:}" -ge 250 ] && stalled=$((stalled + 1))
    [ "${r%%:*}" = 0 ] || bad=$((bad + 1))
done
[ "$stalled" -ge 3 ] && pass "setup: the publish stalled across the unlink in $stalled of 5 rounds" ||
    { fail "setup: the publish stalled in only $stalled rounds -- the race was not arranged"; ct_exit; }
[ "$bad" = 0 ] && pass "an unlinked open file reads nlink 0 after a racing writeback" ||
    fail "$bad of 5 unlinked files read nlink != 0 after writeback adopted its earlier read"

ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" ||
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
