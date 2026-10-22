#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag of a continuously-open, actively-written file
#
# The real target is a VM disk image open for months, which an
# "inode_lock across the whole move" design would never reach. The move
# is incremental and whole-extent-aligned, and the tree is consistent at
# every step boundary.
#
# The page-cache coherency half is what this test caught when it failed
# hard: file data lives in the inode's address space, not the block
# device's, so the per-step copy must flush the range, read the source
# FORCED-FRESH, and invalidate the moved range afterwards.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking online defrag of a CONTINUOUSLY-OPEN, actively-written file"

# The whole point of the incremental mover: a file held open for write
# and written throughout must still defragment, with its writes
# interleaving. A python helper holds one fd open, fragments the file
# (interleaved filler steals the contiguity hint), then keeps
# overwriting random blocks WHILE defrag.cetra runs against the same
# path in a second fd -- and the content must stay correct throughout.
CO_IMG="$(mktemp /tmp/cetrafs-co-XXXXXX.img)"
truncate -s 560M "$CO_IMG"
CO_LOOPDEV="$(losetup --find --show "$CO_IMG")"
CO_MNT="$(mktemp -d /tmp/cetrafs-co-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$CO_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$CO_LOOPDEV" "$CO_MNT"
ct_param_set auto_defrag 0  # manual control for this test

CO_OK=$(python3 - "$CO_MNT/openfile" "$ROOT/userspace/defrag.cetra" << 'PYEOF2'
import os, sys, subprocess, threading, random, time

path, defrag = sys.argv[1], sys.argv[2]
NB = 40
# authoritative shadow of file content, protected by a lock
shadow = [bytes([i & 0xff]) * 4096 for i in range(NB)]
lock = threading.Lock()

# create fragmented: interleave filler files so each block is a separate extent
fillers = []
with open(path, "wb") as f:
    for i in range(NB):
        f.seek(i * 4096); f.write(shadow[i]); f.flush(); os.fsync(f.fileno())
        fp = path + f".fill{i}"
        with open(fp, "wb") as g:
            g.write(b"x")
        fillers.append(fp)

stop = threading.Event()
errors = []

# writer thread: hold the file open, keep overwriting random blocks
def writer():
    try:
        fd = os.open(path, os.O_RDWR)
        while not stop.is_set():
            i = random.randrange(NB)
            data = bytes([random.randrange(256)]) * 4096
            with lock:
                os.pwrite(fd, data, i * 4096)
                os.fsync(fd)
                shadow[i] = data
            time.sleep(0.002)
        os.close(fd)
    except Exception as e:
        errors.append("writer: %r" % e)

t = threading.Thread(target=writer); t.start()
time.sleep(0.1)

# run defrag a few times while the writer hammers it
moved_any = False
for _ in range(4):
    out = subprocess.run([defrag, path], capture_output=True, text=True)
    if out.returncode != 0:
        errors.append("defrag rc=%d %s" % (out.returncode, out.stderr.strip()))
    if "blocks moved" in out.stdout and "-> 1 " in out.stdout:
        moved_any = True
    time.sleep(0.15)

stop.set(); t.join()

# final consistency: every block must match the shadow
with lock:
    with open(path, "rb") as f:
        for i in range(NB):
            f.seek(i * 4096)
            if f.read(4096) != shadow[i]:
                errors.append("block %d mismatch" % i)

for fp in fillers:
    try: os.unlink(fp)
    except OSError: pass

if errors:
    print("FAIL:" + "; ".join(errors[:5]))
else:
    print("OK:defragged-while-written" + (":reached-1-extent" if moved_any else ":no-full-collapse"))
PYEOF2
)
echo "  $CO_OK"
case "$CO_OK" in
    OK:*) pass "online defrag: content stayed correct across concurrent writes + defrag passes" ;;
    *)    fail "online defrag: $CO_OK" ;;
esac

umount "$CO_MNT"
"$ROOT/userspace/fsck.cetra" "$CO_LOOPDEV" >/dev/null &&
    pass "online defrag: fsck clean after concurrent-write defrag" ||
    fail "online defrag: fsck errors after concurrent-write defrag"
ct_param_set auto_defrag 0
rmdir "$CO_MNT"
losetup -d "$CO_LOOPDEV"
rm -f "$CO_IMG"


ct_exit
