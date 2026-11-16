#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a namespace-lock wait's deadline does not outlive its system call
#
# A namespace operation waiting on a peer's lock restarts its system
# call between tries, and a per-task deadline carries its budget across
# the restarts. A restarted call that failed before it got back to the
# lock -- here, the caller lost search permission on a directory above --
# left the deadline behind, and the task's next contended operation, a
# different call, found it spent: EBUSY at once, with no wait (audit
# 2026-11-15 M-18). The deadline now belongs to the call it was started
# for.
#
# Row 1, beating, holds the namespace locks of d1 and d2. An unprivileged
# task creates in d1 and waits; past most of its budget the parent of d1
# is made unsearchable, so the restarted create fails EACCES. Past the
# budget, the same task creates in d2:
#   fixed:   it waits its own budget, then EBUSY;
#   control: nswait_any_call=1 -- EBUSY at once.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v setpriv >/dev/null || { skip "setpriv not installed"; ct_exit; }
LPOKE="$(ct_helper inode_lock_poke)"
IMG="$(ct_image 560 nsorph)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nsorph)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set nswait_any_call 0
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

ct_mkfs "$DEV" -z 1 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
chmod 755 "$MNT"
mkdir -p "$MNT/t1/d1" "$MNT/t2/d2"
chmod 755 "$MNT/t1" "$MNT/t2"
chmod 1777 "$MNT/t1/d1" "$MNT/t2/d2"
sync
poke_dead_peer "$DEV" 1 aa
"$LPOKE" "$DEV" "$(stat -c %i "$MNT/t1/d1")" --ns 1 >/dev/null
"$LPOKE" "$DEV" "$(stat -c %i "$MNT/t2/d2")" --ns 1 >/dev/null
ct_beat_row "$DEV" 1
sleep 2

# <any_call 0|1> -> RES: the first create's errno, the second's errno and seconds
round() {
    local out pid
    echo "$1" >/sys/module/cetrafs/parameters/nswait_any_call
    out="$(ct_tmp nsorph-out)"
    chmod 755 "$MNT/t1"
    setpriv --reuid=65534 --regid=65534 --clear-groups python3 -c 'import os, sys, time, errno
def create(p):
    t = time.time()
    try:
        os.close(os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)); e = "0"
    except OSError as x:
        e = errno.errorcode.get(x.errno, str(x.errno))
    return e, time.time() - t
e1, s1 = create(sys.argv[1])
time.sleep(4)          # past the first wait'"'"'s deadline
e2, s2 = create(sys.argv[2])
print("first=%s firstsecs=%d second=%s secs=%d" % (e1, s1, e2, s2), flush=True)' \
        "$MNT/t1/d1/f$1" "$MNT/t2/d2/g$1" >"$out" 2>&1 &
    pid=$!
    sleep 9 # most of the first wait's budget
    chmod 700 "$MNT/t1"
    wait "$pid" || true
    RES="$(cat "$out")"
    chmod 755 "$MNT/t1"
    echo 0 >/sys/module/cetrafs/parameters/nswait_any_call
}

round 0
F="$RES"
log "fixed: $F"
round 1
C="$RES"
log "control (deadline is the task's): $C"
ct_unbeat

[ "$(field first "$F")" = EACCES ] && [ "$(field first "$C")" = EACCES ] ||
    { fail "setup: the first create did not end EACCES mid-wait: $F / $C"; ct_exit; }
[ "$(field second "$F")" = EBUSY ] && [ "$(field secs "$F")" -ge 8 ] &&
    pass "fixed: the second call waited its own budget ($F)" || fail "fixed: $F"
[ "$(field second "$C")" = EBUSY ] && [ "$(field secs "$C")" -le 2 ] &&
    pass "control: as before, the second call inherited the spent deadline ($C)" ||
    fail "control: no immediate EBUSY -- the suite does not reach the orphan: $C"
ct_umount "$MNT"
ct_exit
