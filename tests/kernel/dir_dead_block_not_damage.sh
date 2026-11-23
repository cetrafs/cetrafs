#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a block of a directory that died under the read is not counted as that directory's damage
#
# A dirent block read that fails its tail check on every attempt marks
# the directory damaged (and under corruption=stop, stops the mount) --
# and only then does the walk ask whether the directory is still alive.
# A peer's rmdir frees the blocks, and the next allocation may make one
# file data: a lockless lookup in the dead directory then read garbage,
# called it the directory's damage, and counted it, for a directory that
# no longer exists (N-27). The read now asks the record, fresh, before
# it marks anything: a directory that died is not damaged.
#
# Staged on one node as dir_walk_block_reused.sh: directory D with one
# entry, caches dropped, a lookup in D paused after its record read; in
# the pause the backing image gets D's record dead and random bytes over
# D's dirent block:
#   1. the lookup fails ENOENT;
#   2. nothing is counted as damage, and no block is called corrupted.
#
# DISCRIMINATION: dirent_damage_unjudged=1 marks before asking, as
# before: the dead directory's block is counted as damage.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dir_walk_record_stall_ms dirent_damage_unjudged; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt ddbd)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set dir_walk_record_stall_ms 0
ct_param_set dirent_damage_unjudged 0

# <tag> <unjudged 0|1> -> RES "result= corrupt_lines= counted="
round() {
    local img dev dino out mark c0 c1 proc
    img="$(ct_image 560 "ddbd$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    mkdir "$MNT/D"
    : >"$MNT/D/n27victimname"
    dino="$(stat -c %i "$MNT/D")"
    sync
    echo "$2" >/sys/module/cetrafs/parameters/dirent_damage_unjudged
    c0="$(sed -n 's/^corruptions: //p' "$proc/info")"
    mark="$(dmesg_mark)"
    out="$(python3 -I - "$MNT/D" "$img" "$IPOKE" "$dino" <<'PY'
import os, subprocess, sys, time
d, img, ipoke, dino = sys.argv[1:5]
P = "/sys/module/cetrafs/parameters/"
hits = []
with open(img, "rb") as f:
    n = 0
    while True:
        b = f.read(4096)
        if not b:
            break
        if b"n27victimname" in b:
            hits.append(n)
        n += 1
if not hits:
    print("result=nofind")
    sys.exit(0)
vb = max(hits) # the journal holds images too; the data regions come last
fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
subprocess.run(["sync"])
with open("/proc/sys/vm/drop_caches", "w") as f:
    f.write("3")
mark = "ddbd-mark-%d-%d" % (os.getpid(), time.time_ns())
with open("/dev/kmsg", "w") as f:
    f.write(mark + "\n")
pid = os.fork()
if pid == 0:
    for _ in range(100):
        out = subprocess.run(["dmesg"], capture_output=True, text=True).stdout
        if mark in out and ("ino=%s: TEST pause" % dino) in out[out.rindex(mark):]:
            break
        time.sleep(0.05)
    else:
        os._exit(3)
    subprocess.run([ipoke, img, "nlink", dino, "0"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    with open(img, "r+b") as f:
        f.seek(vb * 4096)
        f.write(os.urandom(4096))
        f.flush()
        os.fsync(f.fileno())
    os._exit(0)
with open(P + "dir_walk_record_stall_ms", "w") as f:
    f.write("4000")
try:
    os.stat("n27victimname", dir_fd=fd)
    res = "found"
except FileNotFoundError:
    res = "ENOENT"
except OSError as e:
    res = "errno%d" % e.errno
_, st = os.waitpid(pid, 0)
os.close(fd)
if os.waitstatus_to_exitcode(st) == 3:
    res = "nopause"
print("result=%s" % res, flush=True)
PY
)"
    echo 0 >/sys/module/cetrafs/parameters/dir_walk_record_stall_ms
    echo 0 >/sys/module/cetrafs/parameters/dirent_damage_unjudged
    c1="$(sed -n 's/^corruptions: //p' "$proc/info")"
    RES="$out corrupt_lines=$(dmesg_since "$mark" | grep -c 'corrupted, not just a torn' || true) counted=$((c1 - c0))"
    umount "$MNT" || umount -l "$MNT"
}
get() { sed -n "s/.*\b$1=\([a-zA-Z0-9]*\).*/\1/p" <<<"$2"; }

round c 1
C="$RES"; log "control (marked before asking): $C"
round f 0
R="$RES"; log "fixed: $R"
case "$(get result "$R")" in nofind | nopause) fail "setup: $R"; ct_exit ;; esac
[ "$(get result "$R")" = ENOENT ] && pass "1: the lookup in the dead directory fails ENOENT" || fail "1: $R"
[ "$(get corrupt_lines "$R")" = 0 ] && [ "$(get counted "$R")" = 0 ] &&
    pass "2: the dead directory's block is not counted as damage" || fail "2: $R"
[ "$(get counted "$C")" -ge 1 ] && pass "control: marked before asking, the dead directory's block is counted" ||
    fail "control: $C -- the read never judged the garbage block"
ct_exit
