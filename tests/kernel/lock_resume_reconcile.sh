#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# taking a suspended lock back reconciles the cache BEFORE writers resume
#
# flock(LOCK_UN) on a default mount hands the file to a peer; every local
# write path is refused (ETXTBSY) until flock(LOCK_EX) takes it back. A
# peer may have rewritten the file meanwhile, so the resume re-reads the
# record, applies a peer's size and drops the cached tree. It cleared the
# suspended flag first and did that afterwards, under a mutex no write
# path takes: a local writer retrying its ETXTBSY got through in between,
# found the lock held locally, and wrote through the pre-handoff i_size
# and tree. An append then landed at this node's old end of file, over
# the peer's extension, and this node's next publish put the old size
# back.
#
# Staged with one node: the peer's extension is a record rewritten on
# the device (size 8 KiB -> 16 KiB, stamped by another node id) during
# the window. A thread appends, retrying ETXTBSY, while the main thread
# resumes; lock_resume_stall_ms holds the resume just before its
# reconcile. The append must land at the peer's end of file.
#
# DISCRIMINATION: with ci->lock_suspended cleared before the reconcile
# (the old order), the append lands at 8 KiB and the file ends 12 KiB.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/lock_resume_stall_ms ] || { skip "lock_resume_stall_ms is missing"; ct_exit; }

POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 lresume)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lresume)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((${NODE:-0} + 1) % 4))
ct_param_set lock_resume_stall_ms 1500

F="$MNT/f"
GATE="$(ct_tmp lresume-gate)"
rm -f "$GATE" "$GATE.done"
python3 - "$F" "$GATE" <<'PY' &
import os, sys, fcntl, errno, threading, time
path, gate = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.write(fd, b"a" * 8192); os.fsync(fd)
fcntl.flock(fd, fcntl.LOCK_UN)                 # suspend: hand the file over
open(gate, "w").close()
while not os.path.exists(gate + ".done"):      # the peer extends it
    time.sleep(0.05)
res = {}
def writer():
    t0 = time.time()
    while time.time() - t0 < 30:
        try:
            os.write(fd, b"W" * 4096); res["ok"] = True; return
        except OSError as e:
            if e.errno != errno.ETXTBSY:
                res["err"] = e.errno; return
            time.sleep(0.01)
t = threading.Thread(target=writer); t.start()
time.sleep(0.3)
fcntl.flock(fd, fcntl.LOCK_EX)                 # resume
t.join(); os.fsync(fd); os.close(fd)
print("writer", res)
PY
PY_PID=$!
for _ in $(seq 1 100); do [ -e "$GATE" ] && break; sleep 0.1; done
INO="$(stat -c %i "$F")"
"$POKE" "$IMG" setsize "$INO" 16384 2>/dev/null
"$POKE" "$IMG" peerseq "$INO" "$PEER" 2>/dev/null
touch "$GATE.done"
wait "$PY_PID" || fail "the writer process failed"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
SZ="$(stat -c %s "$F")"
TAIL="$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d[16384:16388])' "$F")"
[ "$SZ" = 20480 ] && [ "$TAIL" = "b'WWWW'" ] &&
    pass "the append landed at the peer's end of file (size $SZ)" ||
    fail "the append did not land at the peer's end of file: size $SZ, bytes at 16 KiB $TAIL -- the writer used the pre-handoff size"

ct_umount "$MNT"
ct_exit
