#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag pin and a lock suspend cannot both win
#
# Defrag pins the file's exclusive lock for its whole move; flock(LOCK_UN)
# on a default mount gives that lock away to a peer. Each refuses the
# other -- the suspend refuses a pinned file, the pin refuses a
# suspended one -- but the pin read the suspended flag BEFORE taking the
# mutex the suspend sets it under. A suspend landing in between went
# unseen: the mover pinned a file just handed to a peer and relocated,
# then freed, blocks the peer was writing.
#
# Staged with defrag_begin_stall_ms holding the pin just before the
# mutex, while the file's writer suspends.
#
# DISCRIMINATION: with the check back before mutex_lock(), the defrag
# runs while the lock is surrendered.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/defrag_begin_stall_ms ] || { skip "defrag_begin_stall_ms is missing"; ct_exit; }
DEFRAG="$ROOT/userspace/defrag.cetra"
[ -x "$DEFRAG" ] || { skip "defrag.cetra is not built"; ct_exit; }

IMG="$(ct_image 560 dfsusp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfsusp)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0

# Fragmented, so a defrag that runs has something to move.
python3 - "$MNT" <<'PY'
import os, sys
v = os.open(sys.argv[1] + "/victim", os.O_WRONLY | os.O_CREAT, 0o644)
s = os.open(sys.argv[1] + "/spacer", os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(8):
    os.pwrite(v, bytes([65 + i]) * 4096, i * 4096); os.fsync(v)
    os.pwrite(s, b"s" * 4096, i * 4096); os.fsync(s)
os.close(s); os.close(v)
PY

# Control first: with nothing suspended the same defrag does run.
cp -p "$MNT/victim" "$MNT/control"
python3 - "$MNT" <<'PY'
import os, sys
v = os.open(sys.argv[1] + "/control", os.O_WRONLY | os.O_APPEND)
s = os.open(sys.argv[1] + "/spacer", os.O_WRONLY | os.O_APPEND)
for i in range(8):
    os.write(v, b"c" * 4096); os.fsync(v); os.write(s, b"s" * 4096); os.fsync(s)
os.close(s); os.close(v)
PY
OUT="$("$DEFRAG" "$MNT/control" 2>&1)" && pass "control: an idle fragmented file is defragmented ($OUT)" ||
    fail "control: defrag did not run on an idle fragmented file ($OUT) -- the check below proves nothing"

ct_param_set defrag_begin_stall_ms 1500
OUT="$(python3 - "$MNT/victim" "$DEFRAG" <<'PY'
import os, sys, fcntl, subprocess, time
fd = os.open(sys.argv[1], os.O_RDWR)              # this node's writer
p = subprocess.Popen([sys.argv[2], sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
time.sleep(0.5)                                   # the pin is stalled before lock_mutex
fcntl.flock(fd, fcntl.LOCK_UN)                    # hand the file over
out = p.communicate()[0].decode().strip()
print("rc=%d %s" % (p.returncode, out))
fcntl.flock(fd, fcntl.LOCK_EX)
os.close(fd)
PY
)"
ct_param_set defrag_begin_stall_ms 0
log "defrag beside the suspend: $OUT"
grep -q '^rc=0 ' <<<"$OUT" &&
    fail "the defrag ran on a file whose lock had just been handed over: $OUT" ||
    pass "the defrag declined the file whose lock was handed over meanwhile"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
