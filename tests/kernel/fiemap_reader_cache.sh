#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fiemap, SEEK_DATA/SEEK_HOLE and the close-time extent count read the extent tree from cache, not the device
#
# Both only report the map, so a node that does not hold the file for
# write may trust its cached tree under the data read path's rule
# (cetrafs_lock_read_cache_trusted(): the change stamp checked at least
# once a second). They used to ask the write lock's question instead,
# which sends EVERY tree block to the device on EVERY call: filefrag on
# a fallocated 16 GiB image on an FC array made ~880 FIEMAP calls,
# re-read its 1,021 tree blocks on each, and held the inode lock for
# 285 s. qemu's block status is the same lseek pair, per request. The
# close-time defrag nudge had the same question after the write lock was
# cleared: every close of a fragmented file read its whole tree.
#
# A depth-2 file (one extent per written block, every other block) is
# opened read-only; filefrag and a bounded SEEK_DATA/SEEK_HOLE walk then
# run against it, and the loop device's read count says what reached
# the device.
#
# DISCRIMINATION: read_trust_off puts the readers back on the write
# lock's question; the same calls then read the tree from the device
# each time.
#
# Under nofilelock a sole opener's tree is cached by the presence gate
# (cetrafs_lock_held_for_write_locally()) whether or not the caller is a
# reader, and the control knob does not reach it: skipped there.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "the reader trust branch this suite measures"
command -v filefrag >/dev/null || { skip "filefrag is missing"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/read_trust_off ] || { skip "read_trust_off is missing"; ct_exit; }

IMG="$(ct_image 560 fmrc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fmrc-mnt)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set read_trust_off 0
LOOP="$(basename "$DEV")"
dev_reads() { awk '{print $1}' "/sys/block/$LOOP/stat"; }

N=6000
python3 - "$MNT/frag" "$N" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
blk = b"x" * 4096
for i in range(int(sys.argv[2])):
    os.pwrite(fd, blk, i * 8192)
os.fsync(fd)
os.close(fd)
PY
# The kernel's own extent count (FIEMAP with no buffer): filefrag merges
# extents whose physical gaps match their logical ones when it prints.
EXT="$(python3 - "$MNT/frag" <<'PY'
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
buf = bytearray(struct.pack("QQIIII", 0, 2**64 - 1, 0, 0, 0, 0))
fcntl.ioctl(fd, 0xC020660B, buf)  # FS_IOC_FIEMAP, fm_extent_count 0: count only
print(struct.unpack("QQIIII", bytes(buf))[3])
PY
)"
[ "${EXT:-0}" -ge "$N" ] || { fail "setup: $MNT/frag has ${EXT:-?} extents, wanted $N (the tree is not deep)"; ct_umount "$MNT"; ct_exit; }
pass "setup: $EXT extents, one per written block"

# <label>: device reads for a filefrag and 300 seek pairs, through one
# read-only fd per tool -- the tree already in this node's cache.
measure() {
    local before ff sk
    sync
    before="$(dev_reads)"
    filefrag "$MNT/frag" >/dev/null
    ff=$(($(dev_reads) - before))
    before="$(dev_reads)"
    python3 - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
off = 0
for _ in range(300):
    d = os.lseek(fd, off, os.SEEK_DATA)
    off = os.lseek(fd, d, os.SEEK_HOLE)
os.close(fd)
PY
    sk=$(($(dev_reads) - before))
    echo "$ff $sk"
}

read -r FF SK <<<"$(measure)"
ct_param_set read_trust_off 1
read -r FF_OFF SK_OFF <<<"$(measure)"
ct_param_set read_trust_off 0
log "device reads: filefrag $FF (control $FF_OFF), 300 seek pairs $SK (control $SK_OFF)"

# The control must show the per-call re-read, or the suite cannot see it.
[ "$FF_OFF" -ge $((4 * FF + 100)) ] && [ "$SK_OFF" -ge $((4 * SK + 100)) ] &&
    pass "control: with the write lock's question the tree is re-read per call (filefrag $FF_OFF, seeks $SK_OFF device reads)" ||
    fail "control: read_trust_off did not re-read the tree per call (filefrag $FF_OFF, seeks $SK_OFF) -- the suite cannot tell"
# With the fix: the stamp check's record read, at most once a second.
[ "$FF" -le 50 ] && pass "filefrag reads the tree from cache ($FF device reads)" ||
    fail "filefrag made $FF device reads -- the tree is read from the device per call"
[ "$SK" -le 50 ] && pass "SEEK_DATA/SEEK_HOLE read the tree from cache ($SK device reads)" ||
    fail "300 seek pairs made $SK device reads -- the tree is read from the device per call"

# The close-time defrag nudge counts the tree's extents after the write
# lock is cleared (cetrafs_tree_extent_count_for()): it only queues a
# defrag, so it reads as a reader. The write-open drops the cached tree
# (a handoff lands at open, cetrafs_tree_invalidate_cached()), so the fd
# first reads the whole file, as a VM using its image does -- the leaves
# are then in cache -- and only the close is counted.
close_reads() {
    sync
    python3 - "$MNT/frag" "/sys/block/$LOOP/stat" <<'PY'
import os, sys
st = lambda: int(open(sys.argv[2]).read().split()[0])
fd = os.open(sys.argv[1], os.O_RDWR)
while os.read(fd, 1 << 20):
    pass
before = st()
os.close(fd)
print(st() - before)
PY
}
CL="$(close_reads)"
ct_param_set read_trust_off 1
CL_OFF="$(close_reads)"
ct_param_set read_trust_off 0
log "device reads for a write-open and close: $CL (control $CL_OFF)"
[ "$CL_OFF" -ge $((CL + 20)) ] && pass "control: the close nudge read the tree from the device ($CL_OFF reads)" ||
    fail "control: the close nudge did not read the tree from the device ($CL_OFF reads) -- the suite cannot tell"
[ "$CL" -le 10 ] && pass "a write-open and close reads the tree from cache ($CL device reads)" ||
    fail "a write-open and close made $CL device reads"

# Still the same answers: the walk agrees with the file's layout.
python3 - "$MNT/frag" "$N" <<'PY' && pass "SEEK_DATA/SEEK_HOLE still find every written block" || fail "the seek walk disagrees with the layout"
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
n = int(sys.argv[2])
for i in (0, 1, n // 2, n - 1):
    assert os.lseek(fd, i * 8192, os.SEEK_DATA) == i * 8192
    assert os.lseek(fd, i * 8192, os.SEEK_HOLE) == i * 8192 + 4096
os.close(fd)
PY
ct_umount "$MNT"
ct_exit
