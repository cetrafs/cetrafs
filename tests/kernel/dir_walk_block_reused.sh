#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless directory walk does not list a block that became another directory's after its record read
#
# readdir and lookup read the directory's record, then its dirent
# blocks, holding no lock a peer's rmdir takes. The rmdir frees the
# directory's blocks and the peer's next mkdir can make one of them its
# own: a valid dirent block, of the right kind, with another directory's
# names -- which the walk listed as this one's (audit 2026-11-15 BL-51).
# A walk that may visit a block loaded after its record read now asks
# the record first whether the directory still lives.
#
# Staged on one node: directories D and E, one entry each, every cached
# block dropped and D held open; a readdir of D paused right after its
# record read (dir_walk_record_stall_ms). In the pause the backing image
# gets the peer's work: D's record dead (nlink 0) and E's dirent block
# copied over D's.
#   setup: both blocks were found and the copy made;
#   1. the readdir lists nothing of E's: it fails ENOENT, which glibc's
#      readdir() reports as the end of an empty directory.
#
# DISCRIMINATION: dir_walk_no_alive=1 -- the readdir lists E's entry
# as D's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dir_walk_record_stall_ms dir_walk_no_alive; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt dwbr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set dir_walk_record_stall_ms 0
ct_param_set dir_walk_no_alive 0

# <no_alive 0|1> -> "found= result=<ENOENT|empty|intruder|victim|other>"
round() {
    local img dev dino out
    img="$(ct_image 560 "dwbr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/D" "$MNT/E"
    : >"$MNT/D/bl51victimname"
    : >"$MNT/E/bl51intrudername"
    dino="$(stat -c %i "$MNT/D")"
    sync
    echo "$1" >/sys/module/cetrafs/parameters/dir_walk_no_alive
    out="$(python3 -I - "$MNT/D" "$img" "$IPOKE" "$dino" <<'PY'
import os, subprocess, sys, time
d, img, ipoke, dino = sys.argv[1:5]
P = "/sys/module/cetrafs/parameters/"
def blk_of(name):
    hits = []
    with open(img, "rb") as f:
        n = 0
        while True:
            b = f.read(4096)
            if not b:
                break
            if name in b:
                hits.append(n)
            n += 1
    return hits
fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
# The journal holds images of the same blocks; the data regions come
# last on the volume, so the block itself is the highest hit.
vb, ib = blk_of(b"bl51victimname"), blk_of(b"bl51intrudername")
if not vb or not ib:
    print("found=0 result=other")
    sys.exit(0)
vb, ib = [max(vb)], [max(ib)]
subprocess.run(["sync"])
with open("/proc/sys/vm/drop_caches", "w") as f:
    f.write("3")
pid = os.fork()
if pid == 0:
    time.sleep(1)   # the walk is in its pause
    with open(img, "r+b") as f:
        f.seek(ib[0] * 4096)
        blk = f.read(4096)
        f.seek(vb[0] * 4096)
        f.write(blk)
        f.flush()
        os.fsync(f.fileno())
    subprocess.run([ipoke, img, "nlink", dino, "0"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    os._exit(0)
with open(P + "dir_walk_record_stall_ms", "w") as f:
    f.write("3000")
try:
    names = [e.name for e in os.scandir(fd)]
    # glibc's readdir() reads getdents' ENOENT -- a directory removed
    # under it -- as the end of the directory, as POSIX asks: empty.
    res = "intruder" if "bl51intrudername" in names else "victim" if "bl51victimname" in names else \
        "empty" if not names else "other"
except FileNotFoundError:
    res = "ENOENT"
except OSError as e:
    res = "errno%d" % e.errno
os.waitpid(pid, 0)
os.close(fd)
print("found=1 result=%s" % res, flush=True)
PY
)"
    echo 0 >/sys/module/cetrafs/parameters/dir_walk_record_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/dir_walk_no_alive
    umount "$MNT" || umount -l "$MNT"
    echo "$out"
}

R="$(round 0)"
log "checked: $R"
C="$(round 1)"
log "control (not checked): $C"
for v in "$R" "$C"; do
    grep -q "found=1" <<<"$v" || { fail "setup: the two dirent blocks were not found on the image ($v)"; ct_exit; }
done
pass "setup: D's block was replaced by E's while the walk of D was paused"
grep -qE "result=(ENOENT|empty)" <<<"$R" && pass "1: the readdir of the removed directory listed nothing of E's ($R)" ||
    fail "1: the readdir returned $R"
grep -q "result=intruder" <<<"$C" &&
    pass "control: unchecked, the readdir listed E's entry as D's" ||
    fail "control: the readdir did not list E's entry -- the suite does not reach the window ($C)"
ct_exit
