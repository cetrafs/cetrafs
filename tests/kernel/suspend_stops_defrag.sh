#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lock suspend stops this node's defrag pass instead of failing EBUSY
#
# flock(LOCK_UN) on a default mount hands the file's lock to a peer: a
# live migration's switchover. A defrag pass pins that lock for its
# whole move, and the suspend used to refuse a pinned file with EBUSY --
# a transient state reported as a final answer (class 43), so a
# migration landing during a background defrag of the image failed. The
# suspend now asks the mover to stop at its next step boundary, waits
# for the pin to go (bounded, killable), and goes on.
#
# The move is slowed with defrag_step_delay_ms so the suspend lands in
# the middle of it.
#
# DISCRIMINATION: with defrag_ignore_yield the mover does not stop and
# the suspend is refused after its wait (EBUSY), as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "a lock suspend against a defrag pass; nofilelock has neither"
for p in defrag_step_delay_ms defrag_ignore_yield; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
DEFRAG="$ROOT/userspace/defrag.cetra"
[ -x "$DEFRAG" ] || { skip "defrag.cetra is not built"; ct_exit; }
IMG="$(ct_image 560 susdf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt susdf)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }

# frag <name>: 2048 blocks, each its own extent (interleaved with a spacer).
frag() {
    python3 -I - "$MNT/$1" "$MNT/spacer-$1" <<'PY'
import os, sys
v = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
s = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(2048):
    os.pwrite(v, (b"%08d" % i) * 512, i * 4096); os.fsync(v)
    os.pwrite(s, b"s" * 4096, i * 4096); os.fsync(s)
os.close(s); os.close(v)
PY
}

# suspend_during_defrag <file>: a writer holds the file, defrag.cetra
# moves it, the writer suspends mid-move. Prints "flock=<ok|errno> secs=<t>".
suspend_during_defrag() {
    python3 -I - "$MNT/$1" "$DEFRAG" "$PROC/info" <<'PY'
import os, sys, fcntl, subprocess, time
fd = os.open(sys.argv[1], os.O_RDWR)
p = subprocess.Popen([sys.argv[2], sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
def pinned():
    for l in open(sys.argv[3]):
        if l.startswith("defrag_pinned:"):
            return int(l.split()[1])
    return -1
t = time.time()
while pinned() != 1 and time.time() - t < 20:
    time.sleep(0.05)
if pinned() != 1:
    print("flock=nopin secs=0"); p.kill(); sys.exit(0)
time.sleep(1)                                  # well inside the move
t = time.time()
try:
    fcntl.flock(fd, fcntl.LOCK_UN)
    r = "ok"
except OSError as e:
    r = os.strerror(e.errno).replace(" ", "_")
el = time.time() - t
p.communicate()
print("flock=%s secs=%.1f" % (r, el))
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
except OSError:
    pass
os.close(fd)
PY
}

check_content() {
    python3 -I - "$MNT/$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
bad = [i for i in range(2048) if d[i*4096:(i+1)*4096] != (b"%08d" % i) * 512]
print(len(bad))
PY
}

ct_param_set defrag_step_delay_ms 1000

log "1: the suspend lands mid-move"
frag victim
Y0="$(info defrag_yields)"
OUT="$(suspend_during_defrag victim)"
log "  $OUT"
[ "${OUT#flock=nopin}" = "$OUT" ] || { fail "setup: the defrag never pinned the file"; ct_exit; }
pass "setup: the defrag pass was moving the file"
grep -q '^flock=ok ' <<<"$OUT" && pass "1: the suspend succeeds ($OUT)" ||
    fail "1: the suspend was refused while a defrag pass ran: $OUT"
[ "$(info defrag_yields)" -gt "$Y0" ] && pass "1: the pass stopped for it" ||
    fail "1: no defrag pass stopped -- the suspend did not go through the mover"
[ "$(info defrag_pinned)" = 0 ] && pass "1: nothing is left pinned" || fail "1: a pin is left: $(info defrag_pinned)"
[ "$(check_content victim)" = 0 ] && pass "1: the file reads back whole" ||
    fail "1: $(check_content victim) block(s) of the file changed"

log "2: NEGATIVE CONTROL -- a mover that ignores the request"
frag control
ct_param_set defrag_ignore_yield 1
OUT="$(suspend_during_defrag control)"
ct_param_set defrag_ignore_yield 0
log "  $OUT"
grep -q '^flock=Device_or_resource_busy ' <<<"$OUT" &&
    pass "2: the suspend is refused once its wait runs out ($OUT)" ||
    fail "2: the suspend did not fail without the mover stopping ($OUT) -- case 1 proves nothing"
[ "$(check_content control)" = 0 ] && pass "2: the file reads back whole" ||
    fail "2: $(check_content control) block(s) of the file changed"

ct_param_set defrag_step_delay_ms 0
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
