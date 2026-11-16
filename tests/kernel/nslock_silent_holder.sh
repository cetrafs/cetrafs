#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a SILENT namespace-lock holder is waited out, not answered with EBUSY
#
# A namespace operation waiting on a peer's lock gave up after its
# budget (~12 s) with EBUSY -- an errno creat, unlink and rename do not
# define -- whether the holder was alive or had died with the lock: a
# dead holder is reclaimed only once its row is stale, so HA restarting a
# VM into a directory the dead node was creating in failed for the whole
# stale window (audit 2026-11-15 M-17). Now, at the end of the budget, a
# holder whose row has not moved since the wait began gets another one,
# restarting, until it goes stale and the acquire takes the lock.
#
#   B. row 1 holds a's lock and beats: EBUSY after the budget, as before;
#   S. row 3 holds c's lock and is silent: the create waits and succeeds.
#
# DISCRIMINATION: nslock_silent_extend_off=1, row 2 silent on b: EBUSY.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IMG="$(ct_image 560 nssil)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nssil)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set nslock_silent_extend_off 0
field() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
# <path> -> "err=<errno|0> secs=<elapsed>"
create() {
    python3 -c 'import os, sys, time, errno
t = time.time()
try:
    os.close(os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)); e = "0"
except OSError as x:
    e = errno.errorcode.get(x.errno, str(x.errno))
print("err=%s secs=%d" % (e, time.time() - t), flush=True)' "$1"
}

ct_mkfs "$DEV" -z 1 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="$(ct_procdir "$DEV")/controls"
mkdir "$MNT/a" "$MNT/b" "$MNT/c"
sync
# This mount's timing: a short beat so the watch samples the planted
# rows soon, and a window long enough that the control's budget ends
# well before its row goes stale.
echo hb_interval_secs=10 >"$CTL"
for r in 1 2 3; do
    poke_dead_peer "$DEV" "$r" "a$r"
    "$NPOKE" "$DEV" "$r" --stale 60 >/dev/null
done
"$LPOKE" "$DEV" "$(stat -c %i "$MNT/a")" --ns 1 >/dev/null
"$LPOKE" "$DEV" "$(stat -c %i "$MNT/b")" --ns 2 >/dev/null
"$LPOKE" "$DEV" "$(stat -c %i "$MNT/c")" --ns 3 >/dev/null
ct_beat_row "$DEV" 1
sleep 12 # a tick has sampled every row

log "control: row 2 silent, extension off"
echo 1 >/sys/module/cetrafs/parameters/nslock_silent_extend_off
C="$(create "$MNT/b/g")"
echo 0 >/sys/module/cetrafs/parameters/nslock_silent_extend_off
log "control: $C"
log "B: row 1 beating"
B="$(create "$MNT/a/f")"
log "B: $B"
E0="$(info nslock_silent_extends)"
log "S: row 3 silent"
S="$(create "$MNT/c/h")"
SX=$(($(info nslock_silent_extends) - E0))
log "S: $S extends=$SX"
ct_unbeat

[ "$(field err "$C")" = EBUSY ] &&
    pass "control: as before, a silent holder's budget ends in EBUSY ($C)" ||
    fail "control: not EBUSY -- the suite does not reach the budget's end: $C"
[ "$(field err "$B")" = EBUSY ] && [ "$(field secs "$B")" -lt 40 ] &&
    pass "B: a beating holder still ends the wait in EBUSY ($B)" || fail "B: $B"
[ "$(field err "$S")" = 0 ] && pass "S: the create waited the silent holder out and succeeded ($S)" ||
    fail "S: $S"
[ "$SX" -ge 1 ] && [ "$(field secs "$S")" -ge 12 ] &&
    pass "S: past the budget, extended $SX time(s)" || fail "S: no extension seen ($S, extends=$SX)"
ct_umount "$MNT"
ct_exit
