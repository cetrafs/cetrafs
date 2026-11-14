#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a no-CAW mount's peer watch does not spin on a pending non-fatal signal
#
# On a device with no atomic CAW, a mount that finds a peer row watches it
# for a stale window, sleeping in 500 ms steps. The step was
# msleep_interruptible(): a pending NON-fatal signal makes it return at
# once, and since the signal stays pending until the task returns to user
# space, every pass returned at once -- beating the registry and sending
# I/O on each pass -- for the rest of the window (audit C7; the same trap
# journal.c's claim wait had). The step is now killable, which only a
# fatal signal interrupts.
#
# Staged: a dead-looking peer row and a 20 s stale window. A mount thread
# (a caught SIGUSR1 is delivered to it, which a plain mount(8) cannot
# arrange) watches; one signal is sent to it, and the process's CPU time
# is measured over the next 4 s of the watch.
#
#  1. the mount is in its watch (dmesg), and the signal was delivered;
#  2. it used under 1 s of CPU over those 4 s -- it sleeps, not spins;
#  3. it did not mount, and the process exits (the kill is fatal).
#
# DISCRIMINATION: with msleep_interruptible() the pending signal turns the
# watch into a kernel spin: ~4 s of CPU in the window.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 nocawsig)"
MNT="$(ct_mnt nocawsig)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
ct_param_set stale_secs 20
ct_track mnt "$MNT"

MARK="$(dmesg_mark)"
OUT="$(ct_tmp nocawsig-out)"
python3 -I - "$DEV" "$MNT" >"$OUT" 2>&1 <<'PY' &
import ctypes, os, resource, signal, sys, threading, time
dev, mnt = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
libc.mount.restype = ctypes.c_int
signal.signal(signal.SIGUSR1, lambda *a: None)  # caught: a pending signal, not a kill
rc = {}
native = {}
def worker():
    native['tid'] = threading.get_native_id()
    rc['ret'] = libc.mount(dev.encode(), mnt.encode(), b'cetrafs', 0, None)
t = threading.Thread(target=worker, daemon=True)
t.start()
time.sleep(1.0)  # the mount is in its watch by now (the shell waits for dmesg before starting us)
cpu0 = resource.getrusage(resource.RUSAGE_SELF)
t0 = time.time()
signal.pthread_kill(t.ident, signal.SIGUSR1)
time.sleep(0.5)
# Still pending on the mounting thread: the kernel only drops it on the way
# back to user space, so a watch that sleeps through it leaves it pending.
pend = 0
with open("/proc/self/task/%d/status" % native['tid']) as f:
    for line in f:
        if line.startswith("SigPnd:") or line.startswith("ShdPnd:"):
            pend |= int(line.split()[1], 16)
pending = bool(pend & (1 << (signal.SIGUSR1 - 1)))
time.sleep(3.5)
cpu1 = resource.getrusage(resource.RUSAGE_SELF)
cpu = (cpu1.ru_utime - cpu0.ru_utime) + (cpu1.ru_stime - cpu0.ru_stime)
print("CPU %.2f over %.1f s, pending %d" % (cpu, time.time() - t0, int(pending)), flush=True)
sys.stdout.flush()
os._exit(0)  # the fatal exit ends the watch; nothing here waits on it
PY
PPID_=$!
for _ in $(seq 1 60); do
    dmesg_since "$MARK" | grep -q "to see whether 1 other node" && break
    sleep 0.25
done
dmesg_since "$MARK" | grep -q "to see whether 1 other node" ||
    { fail "setup: the mount never started watching the peer row"; kill -9 "$PPID_" 2>/dev/null || true; ct_exit; }
for _ in $(seq 1 60); do
    grep -q '^CPU ' "$OUT" 2>/dev/null && break
    sleep 0.5
done
kill -9 "$PPID_" 2>/dev/null || true
wait "$PPID_" 2>/dev/null || true
cat "$OUT" >&2
LINE="$(grep '^CPU ' "$OUT" | head -1 || true)"
[ -n "$LINE" ] || { fail "setup: the measurement did not finish: $(head -3 "$OUT")"; ct_exit; }
CPU="$(sed -n 's/^CPU \([0-9.]*\) over.*/\1/p' <<<"$LINE")"
SIG="$(sed -n 's/.*pending \([0-9]*\)$/\1/p' <<<"$LINE")"
[ "$SIG" = 1 ] || { fail "setup: the signal was not pending on the watching mount ($LINE)"; ct_exit; }
pass "the signal is pending on the mount while it watches a peer"
awk -v c="$CPU" 'BEGIN { exit !(c < 1.0) }' &&
    pass "the watch slept through the signal (${CPU}s CPU over 4 s)" ||
    fail "the watch spun on the pending signal (${CPU}s CPU over 4 s)"
if mountpoint -q "$MNT"; then
    fail "the watching mount mounted anyway"
    umount "$MNT"
else
    pass "the watching mount did not mount"
fi
ct_exit
