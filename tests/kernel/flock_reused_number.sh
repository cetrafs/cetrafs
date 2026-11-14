#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# flock(LOCK_EX) refuses a record whose number was reused for another file
#
# A file's record can be replaced under an open fd by a file the number was
# reused for. The open path decides first that the record is still this
# inode (its generation), because a claim keyed on the record's generation
# lands on the wrong file. The explicit flock(LOCK_EX) claim read the
# record and claimed on ITS generation without that decision, so it took
# the lock of a different file (audit 2026-11-14 item 1). It now checks the
# incarnation before the claim.
#
# Setup: nofilelock mount, file a open, its record's generation changed
# underneath it (bumpgen, as a peer's reuse of the number would), then
# flock(LOCK_EX|LOCK_NB) on the open fd.
#   1. fixed: flock fails (ESTALE) and the record's lock is not ours;
#   2. control (lock_raw_gen_unchecked): flock succeeds and the record
#      shows this node's exclusive lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/lock_raw_gen_unchecked ] || { skip "lock_raw_gen_unchecked is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
POKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
MNT="$(ct_mnt frn)"
ct_track mnt "$MNT"
ct_param_set lock_raw_gen_unchecked 0
FL="$(ct_tmp frn-flock.py)"
cat >"$FL" <<'PY'
import errno, fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
sys.stdout.write("open\n"); sys.stdout.flush()
sys.stdin.readline()
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("ok", flush=True)
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)), flush=True)
os.close(fd)
PY

# <unchecked 0|1> -> "<flock result> <owner after>"
probe() {
    local img dev ino
    img="$(ct_image 560 "frn$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    ct_track mnt "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/zero of="$MNT/a" bs=4096 count=2 conv=fsync status=none
    ino="$(stat -c %i "$MNT/a")"
    ct_umount "$MNT"
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    echo "$1" >$P/lock_raw_gen_unchecked
    coproc FLK { python3 "$FL" "$MNT/a"; }
    read -r _ <&"${FLK[0]}"
    "$POKE" "$img" bumpgen "$ino" 999 >/dev/null 2>&1 || fail "could not change the record's generation"
    echo >&"${FLK[1]}"
    local r
    read -r r <&"${FLK[0]}" || true
    wait "$FLK_PID" 2>/dev/null || true
    local L
    L="$("$LPOKE" "$img" "$ino")"
    echo 0 >$P/lock_raw_gen_unchecked
    ct_umount "$MNT" 2>/dev/null || ct_umount "$MNT" || true
    if grep -q "owner=0 mode=1" <<<"$L"; then echo "$r held"; else echo "$r free"; fi
}

read -r R HELD <<<"$(probe 0)"
log "fixed: flock -> $R, record lock $HELD"
[ "$R" = ok ] && fail "1: flock took the lock of a record whose number was reused" ||
    { [ "$HELD" = free ] && pass "1: flock refuses a record that is not this inode, and claims nothing" ||
      fail "1: the record shows a lock after the refused flock"; }
read -r C CHELD <<<"$(probe 1)"
log "control (unchecked): flock -> $C, record lock $CHELD"
[ "$C" = ok ] && [ "$CHELD" = held ] && pass "control: unchecked, flock claims the reused number's record -- the suite discriminates" ||
    fail "control: the unchecked flock did not claim the record ($C, $CHELD) -- the suite cannot tell"
ct_exit
