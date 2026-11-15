#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a close of the image does not unpublish a run a writer installed meanwhile
#
# Every release gives back the inode's speculative run -- a read-only
# open of the image included, with no lock the writer holds. The drop
# took the run, freed what was left of it, and then unpublished the
# span unconditionally. A writer that found the run gone in between
# installed and published a new one, and the drop removed THAT: a run
# of set bits no extent references and no span covers, which is the
# scrub's definition of a leak. The scrub freed it while the writer went
# on handing its blocks out (audit 2026-11-15 B-9). The span is now
# unpublished only when no install came after the drop took the run.
#
# Staged with resv_drop_stall_ms, a one-shot stall in the drop between
# taking the run and freeing it:
#   setup: the writer's first write installs a run (free space drops by
#          more than the block written); the reader's close reaches the
#          drop's stall; the writer's next write installs a new run in it;
#   1. two whole scrub cycles after that reclaim nothing, with the
#      writer's fd still open;
#   2. the writer fills the new run, a second file is written, and every
#      block of both reads back; fsck clean.
#
# DISCRIMINATION: resv_drop_unpublish_always=1 (the old drop): 1 fails,
# the scrub reclaims the new run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/resv_drop_stall_ms ] || { skip "resv_drop_stall_ms is missing"; ct_exit; }
MNT="$(ct_mnt rdvi)"
ct_track mnt "$MNT"
ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
ct_param_set alloc_run_blocks 64
ct_param_set alloc_run_max_blocks 64

# <old 0|1> -> "installed=<n> stalled=<0|1> reclaimed=<n> data=<ok|bad> fsck=<clean|ERR>"
round() {
    local dev mnt proc t f0 f1 r0 r1 c0 data out st
    dev="$(ct_loop "$(ct_image 560 "rdvi$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")/info"
    t="$(ct_tmp "rdvi-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    echo "$1" >/sys/module/cetrafs/parameters/resv_drop_unpublish_always
    f0="$(sed -n 's/^free_data_blocks: //p' "$proc")"
    # the writer: one fd for the whole round; blocks 0, then 1 on go1,
    # then 2..199 on go2; each block holds its own index
    python3 - "$MNT/img" "$t" <<'PY' &
import os, sys, time
path, t = sys.argv[1], sys.argv[2]
def blk(i): return (b"%08d" % i) * 512
def wait(n):
    while not os.path.exists(os.path.join(t, n)):
        time.sleep(0.05)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(fd, blk(0), 0); os.fsync(fd)
open(os.path.join(t, "w0"), "w").close()
wait("go1")
os.pwrite(fd, blk(1), 4096); os.fsync(fd)
open(os.path.join(t, "w1"), "w").close()
wait("go2")
for i in range(2, 200):
    os.pwrite(fd, blk(i), i * 4096)
os.fsync(fd)
open(os.path.join(t, "w2"), "w").close()
wait("close")
os.close(fd)
PY
    local wpid=$!
    while [ ! -e "$t/w0" ]; do sleep 0.05; done
    f1="$(sed -n 's/^free_data_blocks: //p' "$proc")"
    # the reader's close stalls in the drop; the writer installs a new run in the stall
    echo 3000 >/sys/module/cetrafs/parameters/resv_drop_stall_ms
    cat "$MNT/img" >/dev/null &
    local rpid=$!
    sleep 0.5
    st="$(cat /sys/module/cetrafs/parameters/resv_drop_stall_ms)"
    touch "$t/go1"
    while [ ! -e "$t/w1" ]; do sleep 0.05; done
    wait "$rpid"
    r0="$(sed -n 's/^scrub_reclaimed: //p' "$proc")"
    c0="$(sed -n 's/^scrub_cycles: //p' "$proc")"
    local dl=$((SECONDS + 90))
    while [ "$(sed -n 's/^scrub_cycles: //p' "$proc")" -lt $((c0 + 2)) ] && [ "$SECONDS" -lt "$dl" ]; do sleep 1; done
    r1="$(sed -n 's/^scrub_reclaimed: //p' "$proc")"
    touch "$t/go2"
    while [ ! -e "$t/w2" ]; do sleep 0.05; done
    python3 -c "
import os
fd = os.open('$MNT/other', os.O_WRONLY | os.O_CREAT, 0o644)
os.write(fd, b'O' * 4096 * 256); os.fsync(fd); os.close(fd)"
    touch "$t/close"
    wait "$wpid" || true
    echo 0 >/sys/module/cetrafs/parameters/resv_drop_unpublish_always
    umount "$MNT"
    ct_mount "$dev" "$MNT"
    data="$(python3 - "$MNT" <<'PY'
import sys
m = sys.argv[1]
a = open(m + "/img", "rb").read()
ok = len(a) == 200 * 4096 and all(a[i*4096:(i+1)*4096] == (b"%08d" % i) * 512 for i in range(200))
ok = ok and open(m + "/other", "rb").read() == b"O" * 4096 * 256
print("ok" if ok else "bad")
PY
)"
    umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    grep -qE '^ERR' <<<"$out" && { log "fsck ($1): $(grep -m3 '^ERR' <<<"$out" | tr '\n' ' ')" >&2; out=ERR; } || out=clean
    echo "installed=$((f0 - f1)) stalled=$([ "$st" = 0 ] && echo 1 || echo 0) reclaimed=$((r1 - r0)) data=$data fsck=$out"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (old drop): $C"
for x in "$R" "$C"; do
    [ "$(get installed "$x")" -gt 8 ] && [ "$(get stalled "$x")" = 1 ] ||
        { fail "setup: no run installed, or the close never reached the drop's stall ($x)"; ct_exit; }
done
pass "setup: a run was installed, and the close stalled in the drop"
[ "$(get reclaimed "$R")" = 0 ] && pass "1: two scrub cycles reclaimed nothing of the writer's new run" ||
    fail "1: the scrub reclaimed $(get reclaimed "$R") block(s) while the writer held its run"
[ "$(get data "$R")" = ok ] && [ "$(get fsck "$R")" = clean ] && pass "2: both files read back; fsck clean" ||
    fail "2: data=$(get data "$R") fsck=$(get fsck "$R")"
[ "$(get reclaimed "$C")" -gt 0 ] && pass "control: the old drop let the scrub reclaim $(get reclaimed "$C") block(s) of a live run" ||
    fail "control: the old drop lost nothing -- the suite does not reach the race"
ct_exit
