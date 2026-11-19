#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reader trusts its cached tree while this node's own defrag pass has the file pinned
#
# A local defrag pin used to make every reader of the file read its tree
# from the device: each 4 KiB it mapped walked the tree off the disk. On
# a fragmented image that is thousands of device reads per block, and the
# reader's readahead holds invalidate_lock shared across the crawl, which
# is the lock the pass needs for its next step -- so neither finished. A
# two-node run (direct-write, 2026-11-19) had a 1 GiB buffered read stall
# for many minutes behind the janitor on the node that took the file over.
#
# The pin is no reason to distrust the cache: each step edits the tree
# under inode_lock and invalidate_lock, both exclusive, which every
# reader's mapping excludes, and between steps the cache is this node's
# own newest tree.
#
# One node: a fragmented file (one extent per block), a reader holding it
# open, an auto-defrag pass pinned on it and paced between steps (TEST
# ONLY defrag_step_delay_ms, the locks dropped). The held fd reads the
# whole file while the pass is pinned:
#   1. every block reads back its own contents, while steps move them;
#   2. the read takes almost no fresh tree reads (procfs tree_reads_fresh).
#
# DISCRIMINATION: read_trust_defrag_defers=1 -- the same read takes at
# least one fresh tree read per block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in read_trust_defrag_defers defrag_step_delay_ms auto_defrag; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
if ct_nofilelock_run; then
    skip "nofilelock refuses defrag on a file with an opener"
    ct_exit
fi
P=/sys/module/cetrafs/parameters
NBLK=4096
ct_param_set auto_defrag 0
ct_param_set read_trust_defrag_defers 0
ct_param_set defrag_step_delay_ms 0
ct_param_set alloc_run_blocks 0
IMG="$(ct_image 560 rtdp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rtdp)"
ct_track mnt "$MNT"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <defers 0|1> -> RES "pinned=<y|n> during=<y|n> bad=<n> fresh=<n> passes=<n> fsck=<ok|bad>"
round() {
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    python3 - "$MNT/f" "$NBLK" <<'PY'
import os, sys
path, n = sys.argv[1], int(sys.argv[2])
a = os.open(path, os.O_CREAT | os.O_RDWR | os.O_DIRECT, 0o644)
b = os.open(path + ".fill", os.O_CREAT | os.O_WRONLY | os.O_DIRECT, 0o644)
import mmap
buf = mmap.mmap(-1, 4096)
for i in range(n):                  # interleaved: one extent per block
    buf.seek(0); buf.write(b"%-4095d\n" % i)
    os.pwrite(a, buf, i * 4096)
    os.pwrite(b, buf, i * 4096)
os.fsync(a); os.fsync(b); os.close(a); os.close(b)
PY
    echo "$1" >$P/read_trust_defrag_defers
    echo 300 >$P/defrag_step_delay_ms
    local p0
    p0="$(info defrag_passes)"
    RES="$(python3 - "$MNT/f" "$NBLK" "$(ct_procdir "$DEV")/info" "$P/auto_defrag" <<'PY'
import os, sys, time
path, n, info, knob = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
def get(k):
    for l in open(info):
        if l.startswith(k + ": "):
            return int(l.split()[1])
    raise SystemExit("no %s in info" % k)
fd = os.open(path, os.O_RDONLY)           # the reader is in first
open(knob, "w").write("1\n")
with open(path, "ab") as w:               # an append and its close queue the janitor
    w.write(b"x")
pinned = "n"
for _ in range(100):
    if get("defrag_pinned") >= 1:
        pinned = "y"; break
    time.sleep(0.05)
time.sleep(0.4)                            # into the paced steps
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
f0 = get("tree_reads_fresh")
bad = 0
for i in range(n):
    d = os.pread(fd, 4096, i * 4096)
    if d != (b"%-4095d\n" % i):
        bad += 1
f1 = get("tree_reads_fresh")
during = "y" if get("defrag_pinned") >= 1 else "n"
os.close(fd)
print("pinned=%s during=%s bad=%d fresh=%d" % (pinned, during, bad, f1 - f0))
PY
)"
    echo 0 >$P/defrag_step_delay_ms
    local i
    for i in $(seq 1 200); do [ "$(info defrag_pinned)" = 0 ] && break; sleep 0.1; done
    echo 0 >$P/auto_defrag
    echo 0 >$P/read_trust_defrag_defers
    RES="$RES passes=$(($(info defrag_passes) - p0))"
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 && RES="$RES fsck=ok" || RES="$RES fsck=bad"
}

round 0
F="$RES"
round 1
C="$RES"
log "fixed: $F; control: $C"
for r in "$F" "$C"; do
    [ "$(field pinned "$r")" = y ] && [ "$(field during "$r")" = y ] ||
        { fail "setup: the pass was not pinned across the whole read ($r)"; ct_exit; }
done
[ "$(field bad "$F")" = 0 ] && [ "$(field fsck "$F")" = ok ] &&
    pass "1: all $NBLK blocks read back their own contents while the pass moved them; fsck clean" ||
    fail "1: $F"
[ "$(field fresh "$F")" -lt $((NBLK / 16)) ] &&
    pass "2: the read took $(field fresh "$F") fresh tree reads for $NBLK blocks" ||
    fail "2: the read took $(field fresh "$F") fresh tree reads for $NBLK blocks -- the pin still defers"
[ "$(field fresh "$C")" -ge "$NBLK" ] && [ "$(field bad "$C")" = 0 ] &&
    pass "control: with the pin deferring, the same read took $(field fresh "$C") (the counter discriminates)" ||
    fail "control: read_trust_defrag_defers took $(field fresh "$C") fresh tree reads -- the suite does not reach the pinned reader: $C"
ct_exit
