#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag a growing file cancels is not restarted at once
#
# A move re-checks the file's size at every step and cancels when it
# grew. The worker then queued the file again immediately -- and the
# append trigger, which only a decline quiets, queued it as well -- so a
# fragmented file still being appended to (a backup archive, a qcow2)
# drove pass after pass: a full-size run allocated, a step copied, the
# run freed, again (audit 2026-11-14 M2). A growth cancel now quiets the
# append trigger and leaves the hand-back to the writer's last close.
#
# A fragmented file is held open and appended to, one block every 20 ms
# for 8 s, with steps slowed so each pass outlives an append:
#   1. some pass was cancelled by the growth (setup);
#   2. no more than 4 passes ran in those 8 s, counted by the writer
#      itself before its last close (whose hand-back queues more): the
#      filler's one decline (the counter is the mount's, not the
#      file's), the pass the growth cancelled, at most one re-armed by
#      an append while that pass ran, and then nothing -- the cancel
#      quieted the trigger;
#   3. after the writer closes, the file is defragmented (the hand-back
#      still happens).
#
# DISCRIMINATION: defrag_growth_requeue requeues at once and keeps the
# trigger armed, as before; the passes then run many times over.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "the defragmenter, which nofilelock disables (nofilelock_no_defrag.sh)"
for k in defrag_growth_requeue defrag_step_delay_ms defrag_extent_cap; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_growth_requeue 0
ct_param_set defrag_step_delay_ms 0
ct_param_set auto_defrag_quiet_secs 10
# The file reaches ~700 extents in its 8 s, the filler starts at 1,200.
ct_param_set defrag_extent_cap 1000
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt dgb)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
WRITER="$(ct_tmp dgb-writer.py)"
cat >"$WRITER" <<'PY'
import os, sys, time
path = sys.argv[1]
a = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
b = os.open(path + ".fill", os.O_CREAT | os.O_WRONLY, 0o644)
blk = b"g" * 4096
n = 0
# The filler takes four extents per block of the file, so it is past the
# mover's extent cap (lowered below) from the start and stays past it:
# the janitor declines it once (that decline is one of the passes counted).
def fill(n):
    for k in range(4):
        os.pwrite(b, blk, (8 * n + 2 * k) * 4096)
for _ in range(300):               # interleaved: one extent per block
    os.pwrite(a, blk, n * 4096); fill(n); n += 1
os.fsync(a); os.fsync(b)
open(sys.argv[2], "w").write("1")  # auto_defrag on: the next append queues it
t = time.time() + 8
while time.time() < t:
    os.pwrite(a, blk, n * 4096); fill(n); n += 1
    os.fsync(a); os.fsync(b)
    time.sleep(0.02)
# The passes so far, read BEFORE the closes below hand both files back.
passes = [l.split()[1] for l in open(sys.argv[3]) if l.startswith("defrag_passes:")][0]
print(passes, flush=True)
sys.stdout.flush()
os.close(a)
PY

# <requeue 0|1> -> "<passes> <growth cancels> <extents after the close>"
probe() {
    local img dev pd p0 g0 p1 g1 ino ext
    img="$(ct_image 560 "dgb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    pd="$(ct_procdir "$dev")"
    echo "$1" >$P/defrag_growth_requeue
    echo 100 >$P/defrag_step_delay_ms
    p0="$(sed -n 's/^defrag_passes: //p' "$pd/info")"
    g0="$(sed -n 's/^defrag_growth_cancels: //p' "$pd/info")"
    p1="$(python3 "$WRITER" "$MNT/f" $P/auto_defrag "$pd/info")"
    g1="$(sed -n 's/^defrag_growth_cancels: //p' "$pd/info")"
    echo 0 >$P/defrag_step_delay_ms
    # The writer's last close hands the file back: wait for the move.
    ino="$(stat -c %i "$MNT/f")"
    for _ in $(seq 1 60); do
        sync
        ext="$("$IPOKE" "$img" extents "$ino" | sed -n 's/^depth=0 entries=\([0-9]*\).*/\1/p')"
        [ "${ext:-99}" -le 2 ] && break
        sleep 1
    done
    echo 0 >$P/auto_defrag
    echo 0 >$P/defrag_growth_requeue
    ct_umount "$MNT"
    echo "$((p1 - p0)) $((g1 - g0)) ${ext:-?}"
}

read -r PS GC EXT <<<"$(probe 0)"
log "fixed: $PS pass(es) during the growth, $GC growth cancel(s), $EXT extent entr(ies) after the close"
[ "$GC" -ge 1 ] || fail "setup: no pass was cancelled by the growth -- nothing raced"
[ "$PS" -le 4 ] && pass "2: a growing file ran $PS pass(es) in 8 s, not one per append" ||
    fail "2: $PS passes in 8 s -- the cancelled move is restarted at once"
[ "${EXT:-99}" -le 2 ] && pass "3: the writer's last close still hands the file to the janitor ($EXT)" ||
    fail "3: the file was never defragmented after its writer closed ($EXT entries)"
read -r PS0 GC0 _ <<<"$(probe 1)"
log "control: $PS0 pass(es), $GC0 growth cancel(s)"
[ "$PS0" -gt $((PS * 2)) ] && [ "$PS0" -gt 6 ] &&
    pass "control: requeueing at once runs $PS0 passes -- the suite discriminates" ||
    fail "control: requeueing at once ran $PS0 passes against $PS -- the suite cannot tell"
ct_exit
