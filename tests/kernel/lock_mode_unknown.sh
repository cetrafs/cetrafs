#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a record whose lock_mode is not a lock state is refused, not read as free
#
# lock_mode is an enum (NONE, EXCLUSIVE, RELOCATING, YIELD). A record with
# any other value and a valid checksum read as "free" to the open path
# (cetrafs_lock_mode_held() is false for it) but as "held" to the CAS
# mutators, so the two halves of the lock disagreed about the same
# record (audit 2026-11-14 L-F8). The record reader now refuses it with
# EUCLEAN for every caller, and marks the inode.
#
# Setup: a file, unmounted, its record poked to lock_mode 7 and restamped
# (so only the range check can see it).
#   1. fixed: opening it for write fails with EUCLEAN, and dmesg says the
#      lock_mode is not a lock state;
#   2. control (lock_mode_check_off): the same open succeeds -- the record
#      passes everything else, so the refusal above is the range check.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/lock_mode_check_off ] || { skip "lock_mode_check_off is missing"; ct_exit; }
P=/sys/module/cetrafs/parameters
POKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt lmu)"
ct_track mnt "$MNT"
ct_param_set lock_mode_check_off 0
OPEN="$(ct_tmp lmu-open.py)"
cat >"$OPEN" <<'PY'
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY)
    os.close(fd)
    print("ok")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY

# <check_off 0|1> -> "<open result>"
probe() {
    local img dev ino
    img="$(ct_image 560 "lmu$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    echo hi >"$MNT/f"
    sync
    ino="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    "$POKE" "$img" lockmode "$ino" 7 >/dev/null 2>&1 || fail "could not poke lock_mode"
    ct_mount "$dev" "$MNT"
    echo "$1" >$P/lock_mode_check_off
    dmesg | tail -1 >/dev/null
    local r
    r="$(python3 "$OPEN" "$MNT/f")"
    echo 0 >$P/lock_mode_check_off
    ct_umount "$MNT"
    echo "$r"
}

R="$(probe 0)"
log "fixed: open for write -> $R"
dmesg | tail -40 | grep -q "is not a lock state" && SEEN=1 || SEEN=0
[ "$R" = EUCLEAN ] && [ "$SEEN" = 1 ] &&
    pass "1: a record with an unknown lock_mode is refused (EUCLEAN), and the message says why" ||
    fail "1: open gave '$R' (message seen: $SEEN) -- the unknown lock_mode was not refused"

C="$(probe 1)"
log "control (range check off): open for write -> $C"
[ "$C" = ok ] && pass "control: with the range check off the same record opens -- the refusal is the check" ||
    fail "control: the record did not open even without the check ($C) -- the setup is not what the suite claims"
ct_exit
