#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the defrag pin's nofilelock path: it excludes peers and gives its lock back
#
# nofilelock disables defrag (docs/internal/BASICS.md, issue 13), but the
# pin's path for that mode is kept, reachable under TEST ONLY
# defrag_nofilelock, as audit 2026-11-14 A-14 built it; this suite keeps
# it honest while it exists. Every open honours a lock present on the record in both modes,
# and a nofilelock write-open publishes its presence by a swap that
# refuses one -- so the pin, the same swap, still excludes peers: one
# present before it is seen, one arriving after it asks it to step
# aside. No writer holds the lock under nofilelock, so the pin claims it
# and always gives it back.
#
# A peer with g open is planted: its presence bit before the mount, its
# live row after it.
#   1. a fragmented file is defragmented: fewer extents, same content;
#   2. its lock is free afterwards -- the pin gave back what it claimed,
#      though defrag.cetra's own fd was a writer;
#   3. a file the peer has open (its presence bit) is refused, unchanged,
#      and its lock is free;
#   4. procfs says defrag is available;
#   5. fsck clean.
#
# DISCRIMINATION: defrag_nofilelock=0 (the release behaviour, the refusal):
# 1 fails. That the release refuses is nofilelock_no_defrag.sh's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_mode_own
[ -w /sys/module/cetrafs/parameters/defrag_nofilelock ] || { skip "defrag_nofilelock is missing"; ct_exit; }
LPOKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
DEV="$(ct_dev 560 dfnl)"
MNT="$(ct_mnt dfnl)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_nofilelock 1
DEFRAG="$ROOT/userspace/defrag.cetra"

frag() { # 12-extent files: each written a block at a time, interleaved
    python3 -I - "$@" <<'PY'
import os, sys
fds = [os.open(p, os.O_CREAT | os.O_WRONLY, 0o644) for p in sys.argv[1:]]
for i in range(12):
    for f in fds:
        os.pwrite(f, os.urandom(4096), i * 4096)
        os.fsync(f)
for f in fds:
    os.close(f)
PY
}
next() { filefrag "$1" | awk '{print $2}'; }
lockmode() { "$LPOKE" "$DEV" "$1" | sed -n 's/.*mode=\([0-9]*\).*/\1/p'; }

mount -t cetrafs -o nofilelock "$DEV" "$MNT"
frag "$MNT/f" "$MNT/g" "$MNT/c" "$MNT/sep"
F="$(stat -c %i "$MNT/f")"; G="$(stat -c %i "$MNT/g")"
SUMF="$(md5sum <"$MNT/f")"; SUMG="$(md5sum <"$MNT/g")"
umount "$MNT"
# a peer with g open; its row made live after the mount (a row nobody has
# watched yet reads alive -- access_rule.sh), in nofilelock mode
"$LPOKE" "$DEV" "$G" --reader 5 >/dev/null
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
"$NODE_POKE" "$DEV" 5 1 ab "$(date +%s)" >/dev/null
"$NODE_POKE" "$DEV" 5 --mode 2 >/dev/null
PROC="$(ct_procdir "$DEV")"

E0="$(next "$MNT/f")"
[ "$E0" -ge 6 ] || { fail "setup: f has only $E0 extents"; ct_exit; }
OUT="$("$DEFRAG" "$MNT/f" 2>&1)" && RC=0 || RC=$?
E1="$(next "$MNT/f")"
log "f: $E0 -> $E1 extents, defrag.cetra rc=$RC: $OUT"
[ "$RC" = 0 ] && [ "$E1" -lt "$E0" ] && [ "$(md5sum <"$MNT/f")" = "$SUMF" ] &&
    pass "1: defragmented under nofilelock: $E0 -> $E1 extents, content unchanged" ||
    fail "1: defrag under nofilelock: rc=$RC, $E0 -> $E1 extents ($OUT)"
M="$(lockmode "$F")"
[ "$M" = 0 ] && pass "2: the pin gave the lock back" || fail "2: the lock is left in mode $M after the pass"

EG0="$(next "$MNT/g")"
OUT="$("$DEFRAG" "$MNT/g" 2>&1)" && RC=0 || RC=$?
log "g (peer present): rc=$RC: $OUT"
[ "$RC" != 0 ] && [ "$(next "$MNT/g")" = "$EG0" ] && [ "$(md5sum <"$MNT/g")" = "$SUMG" ] && [ "$(lockmode "$G")" = 0 ] &&
    pass "3: a file a peer has open is refused, unchanged, its lock free" ||
    fail "3: peer-open file: rc=$RC, extents $EG0 -> $(next "$MNT/g"), lock mode $(lockmode "$G")"
case "$(sed -n 's/^defrag_available: //p' "$PROC/controls")" in
yes*) pass "4: defrag_available says yes" ;;
*) fail "4: defrag_available: $(sed -n 's/^defrag_available: //p' "$PROC/controls")" ;;
esac
echo 0 >/sys/module/cetrafs/parameters/defrag_nofilelock
OUT="$("$DEFRAG" "$MNT/c" 2>&1)" && RC=0 || RC=$?
echo 1 >/sys/module/cetrafs/parameters/defrag_nofilelock
[ "$RC" != 0 ] && pass "control: without the knob the same run is refused" || fail "control: defrag ran under nofilelock without defrag_nofilelock"
umount "$MNT"
"$LPOKE" "$DEV" "$G" --unreader 5 >/dev/null
"$NODE_POKE" "$DEV" 5 0 00 0 >/dev/null # the planted peer leaves: fsck would watch its row
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "5: fsck clean" || fail "5: fsck: $(grep -m3 '^ERR' <<<"$OUT")"
ct_exit
