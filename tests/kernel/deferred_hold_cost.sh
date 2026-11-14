#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# re-holding an already held-back tree block costs no CRC and no list walk
#
# A regular file's extent-tree block is held back (leafdefer.c) until the
# next durability boundary. Every 4 KiB write into a preallocated image
# re-holds the same leaf, and the re-hold used to cost a pre-image CRC
# over the block (its value is never read for a held-back block: the
# device image is kept in its listing), and an O(cap) walk of the
# inode's held-back list to decide adoption. Now the listing carries an
# orphan flag, so adoption is two loads, and the pre-image CRC is skipped.
#
# Two runs on fresh images, same seeded workload: random 4 KiB writes into
# a fallocated file, fsync every 16. The fix run is the default; the
# control sets deferred_hold_eager=1, which restores the old walk and the
# old pre-image CRC.
#
#  setup:    the held-back path ran (holds moved, the file has > 4 extents)
#  fix:      no list steps at all on the re-hold path
#  control:  the walk runs (steps > 0), and the control computes one CRC
#            per re-hold the fix does not -- the discrimination
#  both:     every write reads back after a remount; fsck clean
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/deferred_hold_eager ] || { skip "deferred_hold_eager is missing"; ct_exit; }
command -v python3 >/dev/null || { skip "python3 not found"; ct_exit; }

WRITES=512
MNT="$(ct_mnt holdcost)"
ct_track mnt "$MNT"
OKS="$(ct_tmp holdcost-ok)"
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# Fallocate, then WRITES random 4 KiB writes, fsync every 16.
workload() {
    python3 - "$MNT/img" "$OKS" "$WRITES" <<'PY'
import os, sys, random
path, oks, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
os.posix_fallocate(fd, 0, 64 << 20)
os.fsync(fd)
random.seed(7)
good = []
for i, b in enumerate(random.sample(range(0, (64 << 20) // 4096), n)):
    os.pwrite(fd, (b"%08d" % b) * 512, b * 4096)
    good.append(b)
    if i % 16 == 15:
        os.fsync(fd)
os.fsync(fd)
os.close(fd)
open(oks, "w").write("\n".join(str(b) for b in good))
PY
}

readback() {
    python3 - "$MNT/img" "$OKS" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
offs = [int(l) for l in open(sys.argv[2]) if l.strip()]
print(sum(1 for b in offs if os.pread(fd, 8, b * 4096) != b"%08d" % b))
os.close(fd)
PY
}

# Extent count from FIEMAP (fm_mapped_extents).
extents() {
    python3 - "$MNT/img" <<'PY'
import fcntl, os, struct, sys
FS_IOC_FIEMAP = 0xC020660B
fd = os.open(sys.argv[1], os.O_RDONLY)
buf = bytearray(struct.pack("<QQIIII", 0, (1 << 64) - 1, 0, 0, 4096, 0) + bytes(4096 * 56))
fcntl.ioctl(fd, FS_IOC_FIEMAP, buf)
print(struct.unpack_from("<I", buf, 20)[0])
os.close(fd)
PY
}

# run <tag> <knob>: sets H_HOLDS H_STEPS H_CRCS H_LOST H_EXT H_FSCK
run() {
    local tag="$1" knob="$2" h0 s0 c0
    ct_param_set deferred_hold_eager "$knob"
    IMG="$(ct_image 1024 "holdcost-$tag")"
    DEV="$(ct_loop "$IMG")"
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    h0=$(info deferred_holds)
    s0=$(info deferred_list_steps)
    c0=$(info update_crcs)
    workload
    H_HOLDS=$(($(info deferred_holds) - h0))
    H_STEPS=$(($(info deferred_list_steps) - s0))
    H_CRCS=$(($(info update_crcs) - c0))
    H_EXT="$(extents)"
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    H_LOST="$(readback)"
    ct_umount "$MNT"
    H_FSCK=ok
    ct_fsck "$DEV" >/dev/null 2>&1 || H_FSCK=bad
    ct_param_set deferred_hold_eager 0
    log "$tag (eager=$knob): holds $H_HOLDS, list steps $H_STEPS, update CRCs $H_CRCS, extents $H_EXT, $H_LOST lost, fsck $H_FSCK"
}

log "fix run: the default"
run fix 0
F_HOLDS=$H_HOLDS; F_STEPS=$H_STEPS; F_CRCS=$H_CRCS; F_EXT=$H_EXT; F_LOST=$H_LOST; F_FSCK=$H_FSCK
log "control run: the old walk and pre-image CRC"
run control 1
C_HOLDS=$H_HOLDS; C_STEPS=$H_STEPS; C_CRCS=$H_CRCS; C_LOST=$H_LOST; C_FSCK=$H_FSCK

[ "$F_HOLDS" -ge $((WRITES / 2)) ] && [ "$F_EXT" -ge 5 ] && [ "$C_HOLDS" -ge $((WRITES / 2)) ] &&
    pass "setup: the held-back path ran ($F_HOLDS and $C_HOLDS holds; $F_EXT extents)" ||
    { fail "setup: the workload did not reach the held-back path (holds $F_HOLDS/$C_HOLDS, extents $F_EXT)"; ct_exit; }
[ "$F_STEPS" = 0 ] && pass "fix: no held-back list steps" || fail "fix: $F_STEPS list steps on the re-hold path"
[ "$C_STEPS" -gt 0 ] && pass "control: the old walk ran ($C_STEPS steps)" ||
    fail "control: no list steps -- the control does not reach the walk"
# Each re-hold is one fewer pre-image CRC in the fix.
SAVED=$((C_CRCS - F_CRCS))
[ "$SAVED" -ge $((F_HOLDS * 9 / 10)) ] && pass "fix: $SAVED fewer update CRCs than the control over $F_HOLDS holds" ||
    fail "fix: only $SAVED fewer update CRCs than the control for $F_HOLDS holds"
[ "$F_LOST" = 0 ] && [ "$C_LOST" = 0 ] && pass "both: all writes read back after a remount" ||
    fail "both: lost after remount (fix $F_LOST, control $C_LOST)"
[ "$F_FSCK" = ok ] && [ "$C_FSCK" = ok ] && pass "both: fsck clean" || fail "both: fsck not clean (fix $F_FSCK, control $C_FSCK)"
ct_exit
