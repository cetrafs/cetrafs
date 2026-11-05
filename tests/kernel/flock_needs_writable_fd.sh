#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# flock on cetrafs needs a writable fd or CAP_SYS_ADMIN
#
# flock(2) here is not advisory: under nofilelock LOCK_EX takes the
# cluster-wide exclusive lock (every peer open refused), and on the
# default mount LOCK_UN suspends this node's lock under the file's real
# writer, whose every write then fails ETXTBSY. Any fd could do either --
# a user who could only READ a VM image could lock the whole cluster out
# of it, or stall the running VM (audit 2026-11-05, section 4). Both now
# need FMODE_WRITE or CAP_SYS_ADMIN; anything else is EBADF.
#
# As nobody on a world-writable file: a read-only fd is refused both ways
# and leaves the lock on the device as it was; a read-write fd still works
# (the handoff an orchestrator does). As root, a read-only fd still works.
#
# DISCRIMINATION: proven 2026-11-05 with the check removed: nobody's
# read-only LOCK_EX takes the lock under nofilelock, and its LOCK_UN on
# the default mount suspends the writer's lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v setpriv >/dev/null || { skip "needs setpriv (util-linux)"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 flkwr)"
MNT="$(ct_mnt flkwr)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
as_nobody() { setpriv --reuid=65534 --regid=65534 --clear-groups --inh-caps=-all -- "$@"; }
lockmode() { "$LOCK_POKE" "$DEV" "$INO" | sed -n 's/.* mode=\([0-9]*\) .*/\1/p'; }

# try <path> <r|rw> <ops...>: one process, prints one result per op;
# "hold" keeps the fd open 3 s after printing, for a probe from outside
try() {
    python3 - "$@" <<'PY'
import errno, fcntl, os, sys, time
p, how, ops = sys.argv[1], sys.argv[2], sys.argv[3:]
fd = os.open(p, os.O_RDONLY if how == "r" else os.O_RDWR)
for op in ops:
    if op == "hold":
        print("held", flush=True); time.sleep(3); continue
    try:
        fcntl.flock(fd, {"ex": fcntl.LOCK_EX | fcntl.LOCK_NB, "un": fcntl.LOCK_UN}[op]); print(op + ":ok")
    except OSError as e:
        print(op + ":" + errno.errorcode.get(e.errno, str(e.errno)))
PY
}

# ---------------------------------------------------------------- nofilelock
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
chmod 0755 "$MNT"
echo image >"$MNT/vm.img"
chmod 0666 "$MNT/vm.img"
sync
INO="$(stat -c %i "$MNT/vm.img")"
[ "$(lockmode)" = 0 ] || { fail "setup: the fresh file is already locked ($(lockmode))"; ct_exit; }

HOLD="$(ct_tmp flkwr-hold)"
as_nobody bash -c "$(declare -f try); try '$MNT/vm.img' r ex hold" >"$HOLD" &
HPID=$!
for _ in $(seq 1 30); do grep -q held "$HOLD" && break; sleep 0.1; done
M="$(lockmode)"
wait "$HPID" || true
R="$(grep -v held "$HOLD" | tr '\n' ' ')"
[ "$R" = "ex:EBADF " ] && pass "nofilelock: LOCK_EX through a read-only fd is refused (EBADF)" ||
    fail "nofilelock: nobody's read-only LOCK_EX returned: $R"
[ "$M" = 0 ] && pass "nofilelock: and the file is not locked on the device while that fd is open" ||
    fail "nofilelock: a read-only fd took the cluster-wide lock (lock_mode $M)"
R="$(as_nobody bash -c "$(declare -f try); try '$MNT/vm.img' rw ex un" | tr '\n' ' ')"
[ "$R" = "ex:ok un:ok " ] && pass "nofilelock: the same user with a read-write fd locks and unlocks" ||
    fail "nofilelock: nobody's read-write LOCK_EX/LOCK_UN returned: $R"
R="$(try "$MNT/vm.img" r ex un | tr '\n' ' ')"
[ "$R" = "ex:ok un:ok " ] && pass "nofilelock: root (CAP_SYS_ADMIN) may use a read-only fd" ||
    fail "nofilelock: root's read-only LOCK_EX/LOCK_UN returned: $R"
[ "$(lockmode)" = 0 ] || fail "nofilelock: the file is left locked ($(lockmode))"
umount "$MNT"

# ---------------------------------------------------------------- default mount
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
OUT="$(ct_tmp flkwr-out)"
python3 - "$MNT/vm.img" "$OUT" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)       # the VM's writer: holds the automatic lock
open(sys.argv[2], "w").write("open\n")
time.sleep(4)
try:
    os.pwrite(fd, b"x", 0); print("write:ok")
except OSError as e:
    print("write:errno%d" % e.errno)
os.close(fd)
PY
WPID=$!
for _ in $(seq 1 30); do [ -s "$OUT" ] && break; sleep 0.1; done
[ "$(lockmode)" = 1 ] || { fail "setup: the writer does not hold the automatic lock ($(lockmode))"; wait; ct_exit; }
R="$(as_nobody bash -c "$(declare -f try); try '$MNT/vm.img' r un" | tr '\n' ' ')"
M="$(lockmode)"
[ "$R" = "un:EBADF " ] && pass "default mount: LOCK_UN through a read-only fd is refused (EBADF)" ||
    fail "default mount: nobody's read-only LOCK_UN returned: $R"
[ "$M" = 1 ] && pass "default mount: and the writer's lock is still held on the device" ||
    fail "default mount: a read-only fd suspended the writer's lock (lock_mode $M)"
wait "$WPID" || true
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
