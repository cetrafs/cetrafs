#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's defrag pin is asked back, not reported as a writer: open, unlink, truncate, flock
#
# A read-open checks the file's lock, then publishes its presence bit
# with a swap that asks the question again. The check already treats a
# peer's RELOCATING/YIELD pin -- a background defrag of an idle file --
# as something to ask back and wait for (cetrafs_lock_wait_yield()). The
# swap did not: a pin landing between the two refused the open with
# ETXTBSY, a final answer for a transient state (class 43), seen by
# ctest grow-unrescanned as "text file busy" on a plain read. The swap now
# reports a mover's refusal and the open asks, waits, and swaps again.
#
# Staged: open_presence_stall_ms holds a read-open between its check and
# its swap; node 1's RELOCATING pin is planted meanwhile and cleared (the
# mover stepping aside) once the open has had time to meet it.
#
#  1. the open succeeds, after the clear rather than before it, and asked
#     for the file back (lock_yield_asks);
#  2. a real writer's lock in the same place is still refused: the retry
#     is for movers only.
#
# The same refusal stood in every operation that asks "does a peer use
# this file?" before destroying or rewriting it (unlink, rename over,
# link, truncate, chmod, fallocate, punch, zero, setxattr) and in flock:
# a pin there was a writer. They now ask through
# cetrafs_lock_foreign_user_settled() / cetrafs_lock_ask_mover():
#  3. unlink and truncate of a pinned file wait for the clear and succeed;
#  4. flock(LOCK_EX|LOCK_NB) on a nofilelock mount, likewise;
#  5. control (lock_yield_wait_ms=0, which turns the asking off): the
#     unlink is refused ETXTBSY at once -- the old answer; 4 has the
#     same control for flock (EWOULDBLOCK).
#
# The pinning peer is node 1, registered live (stale_secs 60): a dead
# holder's pin is the stale-lock path's, not this one.
#
# DISCRIMINATION: without the retry the open in 1 fails with ETXTBSY at
# the swap, before the clear (verified against a build with it removed);
# 5 is the old answer for 3, selected by the knob.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/open_presence_stall_ms ] || { skip "open_presence_stall_ms is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 openmover)"
MNT="$(ct_mnt openmover)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_param_set lock_yield_wait_ms 10000
ct_param_set stale_secs 60
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# The peer registers after the mount (planted before, the mount's gate
# would watch it for a whole window first).
"$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
echo data >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
RES="$(ct_tmp openmover-res)"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <mode>: a read-open held at its swap while node 1's lock in <mode> is
# planted, cleared 3 s later; prints "opened <secs>" or "refused <secs>".
open_with_pin() {
    rm -f "$RES"
    ct_param_set open_presence_stall_ms 2500
    python3 - "$MNT/f" "$RES" <<'PY' &
import os, sys, time
t = time.time()
try:
    fd = os.open(sys.argv[1], os.O_RDONLY)
    r = "opened"
    os.close(fd)
except OSError as e:
    r = "refused:" + os.strerror(e.errno).replace(" ", "_")
open(sys.argv[2], "w").write("%s %.1f\n" % (r, time.time() - t))
PY
    local p=$!
    sleep 1
    "$LOCK_POKE" "$DEV" "$INO" 1 "$1" >/dev/null # pinned while the open stalls
    sleep 3                                      # the swap (at 2.5 s) meets the pin
    "$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null # the mover steps aside
    wait "$p" || true
    ct_param_set open_presence_stall_ms 0
    cat "$RES" 2>/dev/null || echo "none 0"
}

# ------------------------------------------------------------------ 1
log "1: a RELOCATING pin landing before the swap is asked back"
Y0="$(info lock_yield_asks)"
read -r R T <<<"$(open_with_pin 2)"
case "$R" in
opened) awk -v t="$T" 'BEGIN { exit !(t >= 3.5) }' &&
    pass "1: the read-open succeeded once the mover stepped aside (${T}s)" ||
    fail "1: setup: the open succeeded in ${T}s, before the pin was cleared -- it never met the pin" ;;
*) fail "1: the read-open was refused ($R after ${T}s) by a peer's defrag pin" ;;
esac
[ "$(info lock_yield_asks)" -gt "$Y0" ] && pass "1: it asked for the file back" ||
    fail "1: no yield was asked -- the open got past the pin some other way"

# ------------------------------------------------------------------ 2
log "2: a writer's lock in the same place is still refused"
read -r R T <<<"$(open_with_pin 1)"
case "$R" in
refused:Text_file_busy) awk -v t="$T" 'BEGIN { exit !(t < 3.5) }' &&
    pass "2: refused with ETXTBSY at the swap (${T}s)" ||
    fail "2: refused only after ${T}s -- it waited on a writer" ;;
*) fail "2: a read-open beside a peer's exclusive writer: $R after ${T}s" ;;
esac

"$LOCK_POKE" "$DEV" "$INO" --unreader 1 >/dev/null 2>&1 || true

secs() { date +%s.%N; }
took() { awk -v a="$1" -v b="$(secs)" 'BEGIN { printf "%.1f", b - a }'; }
# <ino>: node 1 pins the file now and steps aside 1.5 s later
pin_briefly() {
    "$LOCK_POKE" "$DEV" "$1" 1 2 >/dev/null
    (sleep 1.5; "$LOCK_POKE" "$DEV" "$1" 65535 0 >/dev/null) &
    CLEARER=$!
}
# <tag> <cmd...>: run it on a briefly pinned file; it must wait and succeed
waits_and_succeeds() {
    local tag="$1" t T rc
    shift
    T="$(secs)"
    "$@" 2>"$RES.err" && rc=0 || rc=$?
    t="$(took "$T")"
    wait "$CLEARER" || true
    if [ "$rc" = 0 ] && awk -v t="$t" 'BEGIN { exit !(t >= 1.2) }'; then
        pass "$tag succeeded once the mover stepped aside (${t}s)"
    elif [ "$rc" = 0 ]; then
        fail "$tag: setup: done in ${t}s, before the pin was cleared -- it never met the pin"
    else
        fail "$tag was refused by a peer's defrag pin (rc=$rc after ${t}s: $(cat "$RES.err"))"
    fi
}

# ------------------------------------------------------------------ 3
log "3: unlink and truncate of a pinned file ask the mover back"
for f in u t; do echo data >"$MNT/$f"; done
sync
I="$(stat -c %i "$MNT/u")"; pin_briefly "$I"
waits_and_succeeds "3: unlink" rm -f "$MNT/u"
I="$(stat -c %i "$MNT/t")"; pin_briefly "$I"
waits_and_succeeds "3: truncate" truncate -s 0 "$MNT/t"

# ------------------------------------------------------------------ 5
log "5: control -- with the asking off, the unlink is refused at once"
echo data >"$MNT/c"
sync
I="$(stat -c %i "$MNT/c")"
ct_param_set lock_yield_wait_ms 0
pin_briefly "$I"
T="$(secs)"
out="$(rm -f "$MNT/c" 2>&1)" && rc=0 || rc=$?
t="$(took "$T")"
wait "$CLEARER" || true
ct_param_set lock_yield_wait_ms 10000
[ "$rc" != 0 ] && grep -qi "text file busy" <<<"$out" &&
    pass "5: control: refused ETXTBSY in ${t}s -- the suite tells the two apart" ||
    fail "5: control: rc=$rc after ${t}s ($out) -- the pin did not refuse the unlink even with the asking off"
rm -f "$MNT/c"
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null # gone for the remount: a live row makes the gate watch it

# ------------------------------------------------------------------ 4
log "4: flock(LOCK_EX|LOCK_NB) on a nofilelock mount asks the mover back"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
"$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
echo data >"$MNT/fl"
sync
I="$(stat -c %i "$MNT/fl")"
exec 8<>"$MNT/fl"
pin_briefly "$I"
waits_and_succeeds "4: flock LOCK_NB" python3 -c 'import fcntl,sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)' 8
exec 8>&-
echo data >"$MNT/fc"
sync
I="$(stat -c %i "$MNT/fc")"
exec 9<>"$MNT/fc"
ct_param_set lock_yield_wait_ms 0
pin_briefly "$I"
out="$(python3 -c 'import fcntl,sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)' 9 2>&1)" && rc=0 || rc=$?
wait "$CLEARER" || true
ct_param_set lock_yield_wait_ms 10000
exec 9>&-
[ "$rc" != 0 ] && grep -qi "temporarily unavailable\|would block" <<<"$out" &&
    pass "4: control: with the asking off, LOCK_NB answers EWOULDBLOCK on the pin" ||
    fail "4: control: rc=$rc ($out) -- the pin did not refuse the flock even with the asking off"
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null # the staged peer leaves, or fsck waits on it
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
