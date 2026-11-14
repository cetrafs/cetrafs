#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a read-open that judged a holder stale reads past THAT claim, not any claim of its row
#
# A read-open that finds a foreign exclusive lock judges its holder
# stale and reads past it, and its presence swap is told which holder
# it may read past (lock_owner_ok). The swap compared the ROW only: a
# holder re-attached and taking the lock again between the judgement and
# the swap is a live holder, but was read past all the same (audit
# 2026-11-14 L-F3). The swap now also compares the incarnation judged.
#
# Setup: registry row 1 departed at incarnation 111, holding file a's
# lock. The read-open is held in its presence stall (open_presence_stall_ms);
# during the stall row 1 re-attaches at incarnation 444 and takes the
# lock again.
#   1. fixed: the read-open is refused (ETXTBSY) -- the lock is live;
#   2. control (lock_owner_ok_row_only): the swap reads past the row and
#      the read-open succeeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in open_presence_stall_ms lock_owner_ok_row_only; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt roj)"
ct_track mnt "$MNT"
ct_param_set open_presence_stall_ms 0
ct_param_set lock_owner_ok_row_only 0
ROPEN="$(ct_tmp roj-open.py)"
cat >"$ROPEN" <<'PY'
import errno, os, sys
try:
    os.close(os.open(sys.argv[1], os.O_RDONLY))
    print("ok")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY

# <row_only 0|1> -> "<open result> <lock line after>"
probe() {
    local img dev ino
    img="$(ct_image 560 "roj$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" -M 4 >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/zero of="$MNT/a" bs=4096 count=2 conv=fsync status=none
    ino="$(stat -c %i "$MNT/a")"
    ct_umount "$MNT"
    # Row 1: departed, incarnation 111, holding a's lock.
    "$NPOKE" "$img" 1 1 bb 0 >/dev/null
    "$NPOKE" "$img" 1 --inc 111 >/dev/null
    INODE_LOCK_POKE_INC=111 "$LPOKE" "$img" "$ino" 1 1 >/dev/null
    grep -q "lock_inc=111 " <<<"$("$LPOKE" "$img" "$ino" --incs)" || fail "setup: the lock of incarnation 111 is not on the device"
    ct_mount "$dev" "$MNT"
    echo "$1" >$P/lock_owner_ok_row_only
    ct_param_set open_presence_stall_ms 2000
    ( sleep 0.8
      "$NPOKE" "$img" 1 --beat >/dev/null 2>&1
      "$NPOKE" "$img" 1 --inc 444 >/dev/null 2>&1
      INODE_LOCK_POKE_INC=444 "$LPOKE" "$img" "$ino" 1 1 >/dev/null 2>&1 ) &
    local bg=$! r L
    r="$(python3 "$ROPEN" "$MNT/a")"
    wait "$bg" || true
    ct_param_set open_presence_stall_ms 0
    echo 0 >$P/lock_owner_ok_row_only
    L="$("$LPOKE" "$img" "$ino" --incs)"
    ct_umount "$MNT"
    echo "$r $(grep -q 'lock_inc=444 ' <<<"$L" && echo retaken || echo not-retaken)"
}

read -r R RETAKEN <<<"$(probe 0)"
log "fixed: read-open -> $R (lock $RETAKEN during the stall)"
[ "$RETAKEN" = retaken ] || fail "setup: the holder did not re-take the lock during the stall ($RETAKEN)"
[ "$R" = ETXTBSY ] && pass "1: a read-open refuses a lock its row re-took after the judgement" ||
    fail "1: the read-open gave '$R' -- it read past a live incarnation"

read -r C CRETAKEN <<<"$(probe 1)"
log "control (row-only): read-open -> $C (lock $CRETAKEN)"
[ "$CRETAKEN" = retaken ] || fail "control: setup did not re-take the lock ($CRETAKEN)"
[ "$C" = ok ] && pass "control: a row-only swap reads past the re-taken lock -- the suite discriminates" ||
    fail "control: the row-only swap refused too ($C) -- the suite cannot tell"
ct_exit
