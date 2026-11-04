#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a presence bit this node could not withdraw is retried, not left for ever
#
# read_open_nodes tells every peer "this file is open on that node":
# write-open, unlink, rename-replace, truncate, punch, defrag and the
# orphan scrub all refuse while a live node's bit is set. The last local
# close, and a flock(LOCK_EX) taking a suspended lock back, withdraw it
# with a CAS whose failure was logged and left -- under a comment saying
# the next reclaim of this node's row would clear it, which never
# happens to a node that keeps beating. Now the heartbeat retries it.
#
# Round A: a read-only open's close fails its withdraw. Round B: a
# writer hands its lock over (LOCK_UN publishes presence) and takes it
# back (LOCK_EX withdraws it), the withdraw failing, the writer still
# open. Either way the bit must be gone a few heartbeats later.
#
# Round C: the retry must leave a bit a new local opener needs -- the
# destructive direction, which would let a peer delete the file under it.
#
# DISCRIMINATION: without the deferral (cetrafs_lock_presence_withdraw()
# only logging) both bits are still set 15 s on.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/presence_withdraw_fail_once ] || { skip "presence_withdraw_fail_once is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 presretry)"
MNT="$(ct_mnt presretry)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo a >"$MNT/a"
echo b >"$MNT/b"
sync
dump() { "$LOCK_POKE" "$DEV" "$(stat -c %i "$MNT/$1")"; }
knob_spent() { [ "$(cat /sys/module/cetrafs/parameters/presence_withdraw_fail_once)" = N ]; }

# wait_clear <file> <round>
wait_clear() {
    local ok=0
    for _ in $(seq 1 15); do dump "$1" | grep -q 'readers=0x0$' && { ok=1; break; }; sleep 1; done
    [ "$ok" = 1 ] && pass "$2: the heartbeat withdrew this node's presence ($(dump "$1"))" ||
        fail "$2: this node's presence bit is still set 15 s later: $(dump "$1")"
}

# --- A: a reader's close
python3 - "$MNT/a" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
open("/sys/module/cetrafs/parameters/presence_withdraw_fail_once", "w").write("1")
os.close(fd)
PY
knob_spent || fail "A: setup: the close's withdraw was not the one that failed"
log "A: after the failed withdraw: $(dump a)"
wait_clear a A

# --- B: a writer's resume, writer still open
exec 7<>"$MNT/b"
python3 - "$MNT/b" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_UN)       # hand the lock over: presence published
open("/sys/module/cetrafs/parameters/presence_withdraw_fail_once", "w").write("1")
fcntl.flock(fd, fcntl.LOCK_EX)       # take it back: presence withdrawn -- fails
os.close(fd)
PY
knob_spent || fail "B: setup: the resume's withdraw was not the one that failed"
log "B: after the failed withdraw: $(dump b)"
wait_clear b B
exec 7<&-

# --- C: the retry must not take a bit a NEW local opener needs. Failed
# withdraw, then the file is opened again before the heartbeat runs:
# the bit must stay for as long as that opener does.
echo c >"$MNT/c"; sync
RES="$(python3 - "$MNT/c" "$LOCK_POKE" "$DEV" "$(stat -c %i "$MNT/c")" <<'PY'
import os, subprocess, sys, time
p, poke, dev, ino = sys.argv[1:5]
fd = os.open(p, os.O_RDONLY)
open("/sys/module/cetrafs/parameters/presence_withdraw_fail_once", "w").write("1")
os.close(fd)
fd = os.open(p, os.O_RDONLY)        # a new opener, before the retry
seen = set()
for _ in range(12):                 # 6 s: three heartbeats
    seen.add(subprocess.run([poke, dev, ino], capture_output=True, text=True).stdout.split()[-1])
    time.sleep(0.5)
os.close(fd)
print(" ".join(sorted(seen)))
PY
)"
knob_spent || fail "C: setup: the first close's withdraw was not the one that failed"
[ "$RES" = "readers=0x1" ] && pass "C: the retry left the bit of a file opened again ($RES throughout)" ||
    fail "C: while the file was open again the bit read: $RES -- the retry withdrew presence a local opener needed"
wait_clear c C

ct_umount "$MNT"
ct_exit
