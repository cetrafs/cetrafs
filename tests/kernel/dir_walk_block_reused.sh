#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless directory walk does not list or open a block that became another directory's after its record read
#
# readdir and lookup read the directory's record, then its dirent
# blocks, holding no lock a peer's rmdir takes. The rmdir frees the
# directory's blocks and the peer's next mkdir can make one of them its
# own: a valid dirent block, of the right kind, with another directory's
# names -- which the walk listed as this one's, and a lookup resolved:
# an open for write of a name in the dead directory lands in the other
# directory's file (audit 2026-11-15 BL-51). A walk that may visit a
# block loaded after its record read now asks the record first whether
# the directory still lives.
#
# Staged on one node: directories D and E, one entry each, every cached
# block dropped and D held open; a readdir of D paused right after its
# record read (dir_walk_record_stall_ms). In the pause the backing image
# gets the peer's work: D's record dead (nlink 0) and E's dirent block
# copied over D's.
#   setup: both blocks were found and the copy made;
#   1. the readdir lists nothing of E's: it fails ENOENT, which glibc's
#      readdir() reports as the end of an empty directory;
#   2. a lookup in D of E's name fails ENOENT.
# The image is changed only once the walk has logged its pause, which it
# does after its record read found D alive: what catches it is the
# re-read before a block installed since, not the first check.
#
# DISCRIMINATION: dir_walk_no_recheck=1 (the first check kept) -- the
# readdir lists E's entry as D's, and the lookup finds E's file in D.
#
# NOT STAGED: an install by ANOTHER thread still in flight when the walk
# looks (the in-flight half of the bracket, cetrafs_dirent_loads_moved());
# here the walk's own read is the install. Nothing in this rig can hold
# a second reader's I/O open across the walk's visit.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dir_walk_record_stall_ms dir_walk_no_recheck; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt dwbr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set dir_walk_record_stall_ms 0
ct_param_set dir_walk_no_recheck 0

# <no_recheck 0|1> <readdir|lookup> -> "found= result=<ENOENT|empty|intruder|victim|other>"
round() {
    local img dev dino out
    img="$(ct_image 560 "dwbr$2$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/D" "$MNT/E"
    : >"$MNT/D/bl51victimname"
    : >"$MNT/E/bl51intrudername"
    dino="$(stat -c %i "$MNT/D")"
    sync
    echo "$1" >/sys/module/cetrafs/parameters/dir_walk_no_recheck
    out="$(python3 -I - "$MNT/D" "$img" "$IPOKE" "$dino" "$2" <<'PY'
import os, subprocess, sys, time
d, img, ipoke, dino, mode = sys.argv[1:6]
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
# A marker, not a line count: a full ring buffer rotates, and the lines
# after a count are then none at all.
mark = "dwbr-mark-%d-%d" % (os.getpid(), time.time_ns())
with open("/dev/kmsg", "w") as f:
    f.write(mark + "\n")
pid = os.fork()
if pid == 0:
    # Only once the walk read D's record alive and paused.
    for _ in range(100):
        out = subprocess.run(["dmesg"], capture_output=True, text=True).stdout
        if mark in out and ("ino=%s: TEST pause" % dino) in out[out.rindex(mark):]:
            break
        time.sleep(0.05)
    else:
        os._exit(3)
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
    f.write("4000")
try:
    if mode == "lookup":
        os.stat("bl51intrudername", dir_fd=fd)
        res = "intruder"
    else:
        names = [e.name for e in os.scandir(fd)]
        # glibc's readdir() reads getdents' ENOENT -- a directory removed
        # under it -- as the end of the directory, as POSIX asks: empty.
        res = "intruder" if "bl51intrudername" in names else "victim" if "bl51victimname" in names else \
            "empty" if not names else "other"
except FileNotFoundError:
    res = "ENOENT"
except OSError as e:
    res = "errno%d" % e.errno
_, st = os.waitpid(pid, 0)
os.close(fd)
if os.waitstatus_to_exitcode(st) == 3:
    res = "nopause"
print("found=1 result=%s" % res, flush=True)
PY
)"
    echo 0 >/sys/module/cetrafs/parameters/dir_walk_record_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/dir_walk_no_recheck
    umount "$MNT" || umount -l "$MNT"
    echo "$out"
}

R="$(round 0 readdir)"
log "checked: $R"
C="$(round 1 readdir)"
log "control (not checked): $C"
L="$(round 0 lookup)"
log "lookup, checked: $L"
LC="$(round 1 lookup)"
log "lookup control (not checked): $LC"
for v in "$R" "$C" "$L" "$LC"; do
    grep -q "found=1" <<<"$v" || { fail "setup: the two dirent blocks were not found on the image ($v)"; ct_exit; }
    grep -q "result=nopause" <<<"$v" &&
        { fail "setup: the walk never paused after reading D's record alive ($v)"; ct_exit; }
done
pass "setup: D's block was replaced by E's after the walk of D read its record alive"
grep -qE "result=(ENOENT|empty)" <<<"$R" && pass "1: the readdir of the removed directory listed nothing of E's ($R)" ||
    fail "1: the readdir returned $R"
grep -q "result=intruder" <<<"$C" &&
    pass "control: unchecked, the readdir listed E's entry as D's" ||
    fail "control: the readdir did not list E's entry -- the suite does not reach the window ($C)"
grep -q "result=ENOENT" <<<"$L" && pass "2: the lookup in the removed directory found nothing ($L)" ||
    fail "2: the lookup returned $L"
grep -q "result=intruder" <<<"$LC" &&
    pass "control: unchecked, the lookup resolved E's file in D" ||
    fail "control: the lookup did not find E's file -- the suite does not reach the window ($LC)"
ct_exit
