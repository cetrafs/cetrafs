#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a plain O_CREAT that loses the name to a peer opens the peer's file
#
# The VFS looks a name up before ->create reaches the namespace lock; a
# peer can create that name in between. cetrafs_dir_add_entry() then
# answers -EEXIST, and cetrafs_create() handed it straight to open(2) --
# which may not return EEXIST without O_EXCL: the file exists, so the open
# should open it (audit 2026-11-05, N4). rename learned the same lesson
# and was fixed alone.
#
# Staged: create_prelock_stall_ms holds node A's open(O_CREAT) between its
# negative lookup and the lock; meanwhile "node B" (dir_move_poke, writing
# the device as a peer would) moves an existing file of that name into the
# directory. A's open must then succeed on B's file, not create a second
# one. Control: with O_EXCL the same race answers EEXIST.
#
# DISCRIMINATION: proven 2026-11-05 with the -ESTALE conversion removed
# (knob kept): the plain open fails with EEXIST.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/create_prelock_stall_ms ] || { skip "create_prelock_stall_ms is missing"; ct_exit; }
MOVE_POKE="$(ct_helper dir_move_poke)"

DEV="$(ct_dev 560 crrace)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt crrace)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

race() { # <name> <flags: plain|excl> -> prints OK:<ino> or the errno name
    local name="$1" mode="$2" out pid
    echo "peer's $name" >"$MNT/B/$name"
    sync
    local peer_ino; peer_ino="$(stat -c %i "$MNT/B/$name")"
    stat "$MNT/A/$name" >/dev/null 2>&1 || true # node A's negative dentry
    out="$(ct_tmp crrace-out)"
    ct_param_set create_prelock_stall_ms 1500
    python3 -c '
import errno, os, sys
fl = os.O_RDWR | os.O_CREAT | (os.O_EXCL if sys.argv[2] == "excl" else 0)
try:
    fd = os.open(sys.argv[1], fl, 0o644); print("OK:%d" % os.fstat(fd).st_ino); os.close(fd)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$MNT/A/$name" "$mode" >"$out" &
    pid=$!
    sleep 0.5
    local prc=0
    "$MOVE_POKE" "$BACK" "$B_INO" "$name" "$A_INO" >/dev/null 2>&1 || prc=$? # node B: mv B/name A/
    wait "$pid" || true
    ct_param_set create_prelock_stall_ms 0
    [ "$prc" = 0 ] || { echo "POKEFAIL:$prc $peer_ino"; return; }
    echo "$(cat "$out") $peer_ino"
}

mkdir "$MNT/A" "$MNT/B"
A_INO="$(stat -c %i "$MNT/A")"
B_INO="$(stat -c %i "$MNT/B")"

read -r RES PEER <<<"$(race f plain)"
case "$RES" in POKEFAIL:*) fail "setup: the peer's move did not land ($RES) -- nothing was raced"; ct_exit ;; esac
log "plain O_CREAT racing the peer's name: $RES (peer's ino $PEER)"
case "$RES" in
OK:*) pass "the plain O_CREAT succeeded" ;;
*) fail "the plain O_CREAT returned $RES -- not an outcome open(2) may have without O_EXCL" ;;
esac
[ "$RES" = "OK:$PEER" ] && pass "and opened the peer's file (ino $PEER), not a second one" ||
    fail "the open got ${RES#OK:}, not the peer's ino $PEER"

read -r RES2 PEER2 <<<"$(race g excl)"
case "$RES2" in POKEFAIL:*) fail "setup: the peer's second move did not land ($RES2)"; ct_exit ;; esac
log "O_CREAT|O_EXCL racing the peer's name: $RES2"
[ "$RES2" = EEXIST ] && pass "control: O_EXCL losing the same race answers EEXIST" ||
    fail "control: O_EXCL losing the race returned $RES2, not EEXIST"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
N="$(ls "$MNT/A" | sort | tr '\n' ' ')"
[ "$N" = "f g " ] && pass "directory A holds exactly the two peer names, no duplicates ($N)" ||
    fail "directory A holds: $N"
[ "$(cat "$MNT/A/f")" = "peer's f" ] && pass "A/f is the peer's file, contents intact" ||
    fail "A/f reads: $(cat "$MNT/A/f" 2>&1)"
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
