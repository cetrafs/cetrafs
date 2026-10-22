#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate(ALLOCATE): reserve blocks without writing them
#
# qemu asks for this when a qcow2 is created with preallocation=metadata.
# Without it the call fails EOPNOTSUPP and glibc's posix_fallocate falls
# back to WRITING ZEROES over the range -- measured on the deployment LUN
# as a 32 GiB create allocating 1.07 GiB and taking 11 seconds.
#
# Reserved blocks are marked CETRAFS_EXT_UNINIT: owned and on the bitmap,
# contents undefined. They must read as ZEROES, never as whatever the
# previous owner of those blocks left -- that is a disclosure bug, not
# stale content -- and the first write to each must convert just that
# block, leaving the rest reserved.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 falloc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt falloc)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Poison the device so a reserved-but-unwritten block that leaked its
# previous contents would read as 0xAB, not as zero. This is the whole
# point of the uninit bit, so the test must be able to see it fail.
# Poison nearly the WHOLE free volume, not a token amount. With only a
# small region poisoned, the later fallocate could land on blocks that
# were never written and read as zeroes anyway -- the assertion below
# would then pass without proving anything. Filling the volume forces
# the reservation to come from poisoned blocks.
FREE_MB=$(( $(stat -f -c %f "$MNT") * 4096 / 1048576 ))
POISON_MB=$(( FREE_MB - 16 ))
[ "$POISON_MB" -ge 64 ] || fail "volume too small to poison meaningfully (${FREE_MB} MiB free)"
"$(ct_helper poison_fill)" "$MNT/poison" "$POISON_MB" || fail "could not poison the volume"
sync
log "poisoned ${POISON_MB} MiB of the volume with 0xAB before freeing it"
rm -f "$MNT/poison"
sync

FREE0="$(stat -f -c %f "$MNT")"
fallocate -l 8388608 "$MNT/pre" || fail "fallocate(ALLOCATE) refused -- still EOPNOTSUPP?"
sync
FREE1="$(stat -f -c %f "$MNT")"
USED=$((FREE0 - FREE1))
log "fallocate 8 MiB consumed $USED blocks (2048 expected)"

[ "$USED" -ge 2048 ] || fail "fallocate reserved only $USED blocks -- it did not allocate"
[ "$(stat -c %s "$MNT/pre")" = 8388608 ] || fail "size not set by fallocate without KEEP_SIZE"

# THE assertion: reserved-but-unwritten blocks read as zero.
WHY="$(python3 - "$MNT/pre" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
if len(d) != 8 << 20:
    print("short read: %d bytes" % len(d)); sys.exit(1)
bad = d.count(bytes([0xAB]))
if bad:
    print("%d bytes of a deleted file's data leaked through a preallocated extent" % bad); sys.exit(1)
if d != bytes(8 << 20):
    print("preallocated range did not read as zeroes"); sys.exit(1)
PY
)" || fail "$WHY"
log "preallocated range reads as zeroes (no leak of the poisoned blocks)"

# Writing into it must convert only what is written, and must not
# allocate again -- the blocks are already reserved.
FREE2="$(stat -f -c %f "$MNT")"
dd if=/dev/urandom of="$MNT/pre" bs=4096 count=512 conv=notrunc status=none
sync
FREE3="$(stat -f -c %f "$MNT")"
log "writing 2 MiB into the reservation changed free blocks by $((FREE2 - FREE3))"
[ "$((FREE2 - FREE3))" -le 8 ] ||
    fail "writing into preallocated space allocated $((FREE2 - FREE3)) more blocks -- it double-allocated"

# The written part must read back exactly; the rest must still be zero.
WHY="$(python3 - "$MNT/pre" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
tail = d[2 << 20:]
if tail != bytes(len(tail)):
    print("unwritten remainder of the reservation is not zero"); sys.exit(1)
PY
)" || fail "$WHY"
log "written region intact, unwritten remainder still zeroes"

# --- writing into the MIDDLE of a preallocated extent ---
# This is the three-way split: [preallocated head][written][preallocated
# tail]. Both untouched sides must still read as zeroes, and the written
# block must read back exactly, or the split put the wrong physical
# blocks under the wrong logical offsets.
rm -f "$MNT/mid"
fallocate -l 4194304 "$MNT/mid" || fail "fallocate for the middle-split case failed"
sync
FREE_M0="$(stat -f -c %f "$MNT")"
python3 - "$MNT/mid" <<'PY2'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.pwrite(fd, bytes([0xCD]) * 4096, 2 << 20)   # one block, exactly halfway
os.close(fd)
PY2
sync
FREE_M1="$(stat -f -c %f "$MNT")"
[ "$((FREE_M0 - FREE_M1))" -le 8 ] ||
    fail "a middle write into preallocated space allocated $((FREE_M0 - FREE_M1)) blocks -- it should reuse the reservation"

WHY="$(python3 - "$MNT/mid" <<'PY2'
import sys
d = open(sys.argv[1], "rb").read()
off = 2 << 20
if len(d) != 4 << 20:
    print("size changed to %d" % len(d)); sys.exit(1)
if d[:off] != bytes(off):
    print("preallocated HEAD stopped reading as zeroes after the split"); sys.exit(1)
if d[off:off+4096] != bytes([0xCD]) * 4096:
    print("the written block did not read back"); sys.exit(1)
if d[off+4096:] != bytes(len(d) - off - 4096):
    print("preallocated TAIL stopped reading as zeroes after the split"); sys.exit(1)
PY2
)" || fail "$WHY"
log "middle split: head and tail still zero, written block intact"

# KEEP_SIZE must not move i_size.
truncate -s 0 "$MNT/ks"
fallocate -n -l 1048576 "$MNT/ks" || fail "fallocate KEEP_SIZE refused"
[ "$(stat -c %s "$MNT/ks")" = 0 ] || fail "KEEP_SIZE changed i_size"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after preallocation"

pass "fallocate(ALLOCATE) reserves blocks that read as zeroes and convert on write"

ct_exit
