#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a first open stops this node's defrag pass on the file instead of failing EBUSY behind it
#
# The first local open of a file a peer wrote last refreshes it from the
# record, under the inode's locks, with bounded retries (~0.1-0.2 s). A
# defrag pass holds those locks across each step, so an open landing
# behind a step failed with EBUSY -- seen in a two-node run: a takeover's
# own close handed the file to the janitor, and the very next open, the
# verifier's, was refused. A VM start would be refused the same way. The
# open now asks the pass to stop at its step boundary and waits for it
# (bounded, killable), as a lock suspend already did.
#
# One node: a fragmented file, no opener, an auto-defrag pass whose first
# step stalls 4 s holding the locks (TEST ONLY defrag_copy_stall_ms;
# auto_defrag_begin_delay_ms lets the append's close finish first); the
# record is stamped as a peer's last publish (inode_lock_poke
# --peer-size, size unchanged), so the next open refreshes. cat must
# succeed; the pass yielded (defrag_yields up); fsck clean.
#
# DISCRIMINATION: open_defrag_wait_off=1 -- the open fails EBUSY.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
for k in open_defrag_wait_off defrag_copy_stall_ms auto_defrag_begin_delay_ms auto_defrag; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
LOCK_POKE="$(ct_helper inode_lock_poke)"
ct_param_set auto_defrag 0
ct_param_set open_defrag_wait_off 0
ct_param_set defrag_copy_stall_ms 0
ct_param_set auto_defrag_begin_delay_ms 0
ct_param_set alloc_run_blocks 0
IMG="$(ct_image 560 osd)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt osd)"
ct_track mnt "$MNT"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# <wait_off 0|1> -> RES "pinned=<y|n> open=<ok|EBUSY|...> yields=<n> secs=<n> fsck=<ok|bad>"
round() {
    local ino size y0 p0 i pinned=n err t0
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    python3 - "$MNT/f" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
b = os.open(sys.argv[1] + ".fill", os.O_CREAT | os.O_WRONLY, 0o644)
blk = b"o" * 4096
for n in range(400):           # interleaved: one extent per block
    os.pwrite(a, blk, n * 4096)
    os.pwrite(b, blk, n * 4096)
os.fsync(a); os.fsync(b); os.close(a); os.close(b)
PY
    echo "$1" >$P/open_defrag_wait_off
    echo 4000 >$P/defrag_copy_stall_ms
    # The pass pins a moment after it is queued, so the append's own
    # close is done by then: a pass on a file nobody has open.
    echo 1500 >$P/auto_defrag_begin_delay_ms
    p0="$(info defrag_passes)"
    echo 1 >$P/auto_defrag
    # An append and its close queue the janitor.
    printf 'x' >>"$MNT/f"
    for i in $(seq 1 50); do
        [ "$(info defrag_pinned)" -ge 1 ] && { pinned=y; break; }
        sleep 0.1
    done
    sleep 0.5 # into the first step's stall, its locks held
    ino="$(stat -c %i "$MNT/f")"
    size="$(stat -c %s "$MNT/f")"
    y0="$(info defrag_yields)"
    "$LOCK_POKE" "$IMG" --peer-size "$ino" "$size" 1 >/dev/null # the backing file: the device is mounted
    t0=$SECONDS
    err="$(cat "$MNT/f" 2>&1 >/dev/null)" && RES="open=ok" ||
        { grep -qi "resource busy" <<<"$err" && RES="open=EBUSY" || RES="open=other:${err// /_}"; }
    RES="pinned=$pinned $RES secs=$((SECONDS - t0)) passes=$(($(info defrag_passes) - p0))"
    for i in $(seq 1 100); do [ "$(info defrag_pinned)" = 0 ] && break; sleep 0.1; done
    RES="$RES yields=$(($(info defrag_yields) - y0))"
    echo 0 >$P/auto_defrag
    echo 0 >$P/defrag_copy_stall_ms
    echo 0 >$P/auto_defrag_begin_delay_ms
    echo 0 >$P/open_defrag_wait_off
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 && RES="$RES fsck=ok" || RES="$RES fsck=bad"
}

round 0
F="$RES"
round 1
C="$RES"
log "fixed: $F; control: $C"
[ "$(field pinned "$F")" = y ] && [ "$(field pinned "$C")" = y ] ||
    { fail "setup: no defrag pass was pinned on the file ($F / $C)"; ct_exit; }
[ "$(field open "$F")" = ok ] && [ "$(field yields "$F")" -ge 1 ] && [ "$(field fsck "$F")" = ok ] &&
    pass "the open stopped the pass ($(field secs "$F") s) and read the file; fsck clean" || fail "fixed: $F"
[ "$(field open "$C")" = EBUSY ] &&
    pass "control: without the stop, the open failed EBUSY behind the pass's step" ||
    fail "control: the open did not fail -- the suite does not reach the contended refresh: $C"
ct_exit
