#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a convert landing between a publish's held-set check and its shadow take keeps the root back
#
# B-23's guard judged the inode's held-back tree set first and took the
# shadow later, under fd_pub_mutex, which a convert does not take. A
# convert in between -- its shrunk leaf held back, its new leaf written,
# the root re-pointed in the shadow -- had its root published by a
# publisher that had already seen the set empty: the device then named
# the written block from the old leaf and the new one (review F-10). The
# set is now judged after the take: a tree edit holds its blocks back
# before it stages the root, and fd_lock orders the stage before the take.
#
# The B-23 file (a full leaf over a preallocated extent); a held fd
# dirties the record, a syncfs's publish of it is stalled before the take
# (publish_take_stall_ms), and the fd's write to block 253 converts there.
# tree_flush_skip_all keeps the set held; the backing file is copied after
# the syncfs -- the device a crash leaves -- and fsck'd.
#   setup: the convert landed while the publish was stalled;
#   1. the copy names no block twice: fsck reports no ERR.
#
# DISCRIMINATION: publish_pending_early=1 (judged before the take): the
# copy names block 253's block from two leaves, fsck ERR.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in publish_pending_early publish_take_stall_ms publish_take_stall_ino tree_flush_skip_all; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt prcr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set publish_pending_early 0
ct_param_set publish_take_stall_ms 0
ct_param_set publish_take_stall_ino 0
ct_param_set tree_flush_skip_all 0
export CETRAFS_PEER_PROBE_SECS=1 # the copy's row looks live: watched two beats, not the window
P=/sys/module/cetrafs/parameters

# <early 0|1> -> "raced=<0|1> fsck=<clean|ERR> why=<first ERR>"
round() {
    local img dev t copy out ino spid raced=0
    img="$(ct_image 560 "prcr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    fallocate -l $((1024 * 4096)) "$MNT/f"
    python3 -I - "$MNT/f" <<'PY'
import os, sys, mmap
m = mmap.mmap(-1, 4096)
for b in range(1, 252, 2):
    m.seek(0); m.write(((b'blk%08d' % b) * 512)[:4096])
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT); os.pwrite(fd, m, b * 4096); os.close(fd)
PY
    ino="$(stat -c %i "$MNT/f")"
    sync -f "$MNT"
    t="$(ct_tmp "prcr-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    echo "$1" >$P/publish_pending_early
    echo 1 >$P/tree_flush_skip_all
    python3 -I - "$MNT/f" "$t" <<'PY' &
import os, sys, mmap, time
d = sys.argv[2]
def wait(n):
    while not os.path.exists(os.path.join(d, n)):
        time.sleep(0.02)
def mark(n):
    open(os.path.join(d, n), "w").close()
m = mmap.mmap(-1, 4096)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
time.sleep(1.1)  # a new mtime: the record is dirty for the syncfs
m.write(((b'blk%08d' % 1) * 512)[:4096])
os.pwrite(fd, m, 1 * 4096)
mark("d")
wait("go")
m.seek(0); m.write(((b'blk%08d' % 253) * 512)[:4096])
os.pwrite(fd, m, 253 * 4096)  # the convert, inside the publish's stall
mark("w")
wait("close")
os.close(fd)
PY
    local wpid=$!
    while [ ! -e "$t/d" ]; do sleep 0.05; done
    echo "$ino" >$P/publish_take_stall_ino
    echo 3000 >$P/publish_take_stall_ms
    sync -f "$MNT" 2>/dev/null &
    spid=$!
    sleep 1
    touch "$t/go"
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    kill -0 "$spid" 2>/dev/null && raced=1
    wait "$spid" || true
    echo 0 >$P/publish_take_stall_ms
    copy="$(ct_tmp "prcr-copy$1")"
    cp --sparse=always "$img" "$copy"
    echo 0 >$P/tree_flush_skip_all
    echo 0 >$P/publish_pending_early
    touch "$t/close"
    wait "$wpid" || true
    ct_umount "$MNT"
    local cdev
    cdev="$(ct_loop "$copy")"
    out="$(ct_fsck "$cdev" 2>&1 || true)"
    losetup -d "$cdev" 2>/dev/null || true
    local why
    why="$(grep -m1 '^ERR' <<<"$out" | tr ' ' '_' | cut -c1-120)"
    grep -qE '^ERR' <<<"$out" && out=ERR || out=clean
    echo "raced=$raced fsck=$out why=${why:-none}"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (judged before the take): $C"
[ "$(get raced "$R")" = 1 ] && [ "$(get raced "$C")" = 1 ] ||
    { fail "setup: the convert did not land inside the publish's stall ($R | $C)"; ct_exit; }
pass "setup: the convert landed while the publish was stalled before its take"
[ "$(get fsck "$R")" = clean ] && pass "1: the copy taken after the publish names no block twice; fsck clean" ||
    fail "1: the copy is damaged: $(get why "$R")"
[ "$(get fsck "$C")" = ERR ] && pass "control: judged before the take, the root went ahead of its leaf ($(get why "$C"))" ||
    fail "control: the early judgement left a clean copy -- the suite does not reach the race"
ct_exit
