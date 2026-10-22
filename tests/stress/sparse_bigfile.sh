#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# near-max sparse files and s_maxbytes enforcement (slow, opt-in)
#
#   (a) sb->s_maxbytes enforcement: cetrafs_compute_max_file_size()
#       (kmod/zonegroup.c) caps a volume's max file size to the
#       worst-case guaranteed ZG capacity any one node could ever claim,
#       instead of the plain VFS default (MAX_LFS_FILESIZE, ~8 EiB, no
#       relation to real capacity). This creates a sparse file at
#       exactly that reported max, confirms growing one byte past it
#       fails (-EFBIG) and growing to exactly the max succeeds.
#
#   (b) a near-max sparse file's head/tail surviving a remount intact,
#       with specific data written to the first and last 1 MiB and
#       verified by hash after reopening. This is the closest this
#       single-machine, single-kernel harness can get to "node A writes
#       and closes, node B opens and reads": unmount+remount (same
#       loaded module, same kernel) at least forces a real re-read from
#       the backing device rather than serving node A's own page cache,
#       but it is NOT a substitute for genuine cross-node validation --
#       see ctest/ or real two-node hardware for that.
#
# Deliberately NOT part of `make check` / mount_test.sh: mkfs'ing and
# exercising a multi-GiB device is slow (truncate -s/mkfs cost scales
# with device size). Run explicitly:
#
#   make check-slow
#   bash tests/sparse_bigfile_test.sh
#
# Override the device size with CETRAFS_SPARSE_TEST_SIZE_MB (default
# 10240, i.e. 10 GiB) -- must still leave enough per-ZG capacity for a
# 1 MiB head and 1 MiB tail write (use at least a few hundred MiB).

set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIZE_MB="${CETRAFS_SPARSE_TEST_SIZE_MB:-10240}"
IMG="$(mktemp /tmp/cetrafs-sparse-XXXXXX.img)"
MNT="$(mktemp -d /tmp/cetrafs-sparse-mnt-XXXXXX)"
LOOPDEV=""
MOUNTED=0
MODULE_LOADED=0
FAILURES=0
HEAD_REF=""
TAIL_REF=""

log() { echo "== $*"; }
pass() { echo "PASS: $*"; }
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

cleanup() {
    set +e
    [ "$MOUNTED" = "1" ] && umount "$MNT" 2>/dev/null
    [ "$MODULE_LOADED" = "1" ] && rmmod cetrafs 2>/dev/null
    [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
    rm -f "$IMG" "$HEAD_REF" "$TAIL_REF"
}
trap cleanup EXIT

if [ "$(id -u)" != "0" ]; then
    echo "must run as root" >&2
    exit 2
fi

log "building"
make -C "$ROOT" all >/dev/null

log "creating ${SIZE_MB} MiB sparse image, 3 Zone Groups, node capacity 3"
# -z 3 -M 3 is deliberate, not arbitrary: node_table_count (-M) must be
# <= zone_group_count for cetrafs_compute_max_file_size()'s worst-case
# formula to produce an interesting (non-degenerate) answer. With M > Z,
# the formula's own floor-at-1 (see its comment in zonegroup.c) still
# gives a correct, safe answer -- "this node keeps the one ZG it's
# already claimed" -- but that's the trivial floor case, not real
# worst-case-contention arithmetic (k = max(1, Z - (M-1))). M=3, Z=3
# gives k=1 through the actual subtraction, exercising the formula for
# real rather than only its floor.
truncate -s "${SIZE_MB}M" "$IMG"
LOOPDEV="$(losetup --find --show "$IMG")"
"$ROOT/userspace/mkfs.cetra" "$LOOPDEV" -z 3 -M 3 -f

log "loading module"
modprobe libcrc32c 2>/dev/null || true # crc32c() may be built into vmlinux instead
lsmod | grep -q '^cetrafs\b' && rmmod cetrafs
insmod "$ROOT/kmod/cetrafs.ko"
MODULE_LOADED=1

log "mounting"
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

DEV_NAME="$(basename "$LOOPDEV")"
PROC_INFO="/proc/fs/cetrafs/$DEV_NAME/info"

# The kernel's own reported max, not a re-derivation of the formula in
# shell -- the point is to test what the kernel actually enforces, not
# to re-check the arithmetic a second time in a different language.
MAX_SIZE="$(grep '^max_file_size_bytes:' "$PROC_INFO" | awk '{print $2}')"
if [ -z "$MAX_SIZE" ] || [ "$MAX_SIZE" -lt 2097152 ]; then
    echo "max_file_size_bytes missing or too small to run this test ($MAX_SIZE) -- image/config too small" >&2
    exit 2
fi
log "kernel-reported max_file_size_bytes = $MAX_SIZE ($((MAX_SIZE / 1048576)) MiB)"

WRITE_READY="$(grep '^write_ready:' "$PROC_INFO" | awk '{print $2}')"
[ "$WRITE_READY" = "yes" ] && pass "node is write_ready before attempting the sparse file" ||
    fail "node reports write_ready=$WRITE_READY, can't meaningfully run this test"

log "checking the max-file-size boundary (ftruncate enforcement)"
BIGFILE="$MNT/sparse-bigfile"

OVER_SIZE=$((MAX_SIZE + 1))
if truncate -s "$OVER_SIZE" "$BIGFILE" 2>/tmp/cetrafs-sparse-trunc.err; then
    fail "growing to max_file_size_bytes+1 ($OVER_SIZE) unexpectedly succeeded"
else
    pass "growing to max_file_size_bytes+1 ($OVER_SIZE) correctly failed: $(cat /tmp/cetrafs-sparse-trunc.err)"
fi
rm -f /tmp/cetrafs-sparse-trunc.err

# Whether or not the over-size attempt above left any partial state,
# ftruncate to exactly MAX_SIZE must succeed and is the file this test
# continues with -- "the biggest sparse file this volume can allocate".
if truncate -s "$MAX_SIZE" "$BIGFILE"; then
    pass "growing to exactly max_file_size_bytes ($MAX_SIZE) succeeded"
else
    echo "cannot continue: growing to exactly max_file_size_bytes failed" >&2
    exit 1
fi

GOT_SIZE="$(stat -c '%s' "$BIGFILE")"
[ "$GOT_SIZE" = "$MAX_SIZE" ] && pass "sparse file size reads back as exactly $MAX_SIZE" ||
    fail "sparse file size is $GOT_SIZE, expected $MAX_SIZE"

log "writing specific data to the first and last 1 MiB (node A's side)"
HEAD_REF="$(mktemp /tmp/cetrafs-sparse-head-XXXXXX)"
TAIL_REF="$(mktemp /tmp/cetrafs-sparse-tail-XXXXXX)"
dd if=/dev/urandom of="$HEAD_REF" bs=1M count=1 status=none
dd if=/dev/urandom of="$TAIL_REF" bs=1M count=1 status=none

TAIL_OFFSET=$((MAX_SIZE - 1048576))
dd if="$HEAD_REF" of="$BIGFILE" bs=1M count=1 conv=notrunc oflag=seek_bytes seek=0 status=none
dd if="$TAIL_REF" of="$BIGFILE" bs=1M count=1 conv=notrunc oflag=seek_bytes seek="$TAIL_OFFSET" status=none
sync

MID_OFFSET=$((MAX_SIZE / 2))
MID_BYTE="$(dd if="$BIGFILE" bs=1 count=1 iflag=skip_bytes skip="$MID_OFFSET" status=none | od -An -tu1 | tr -d ' ')"
[ "$MID_BYTE" = "0" ] && pass "sparse hole in the middle of the file still reads as zero" ||
    fail "middle-of-file byte is '$MID_BYTE', expected 0 (hole)"

HEAD_WANT="$(sha256sum "$HEAD_REF" | awk '{print $1}')"
TAIL_WANT="$(sha256sum "$TAIL_REF" | awk '{print $1}')"

log "closing (node A done writing), remounting (approximating node B opening it)"
umount "$MNT"
MOUNTED=0
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

POST_SIZE="$(stat -c '%s' "$BIGFILE")"
[ "$POST_SIZE" = "$MAX_SIZE" ] && pass "sparse file size survived the remount ($POST_SIZE)" ||
    fail "sparse file size after remount is $POST_SIZE, expected $MAX_SIZE"

HEAD_GOT="$(dd if="$BIGFILE" bs=1M count=1 iflag=skip_bytes skip=0 status=none | sha256sum | awk '{print $1}')"
[ "$HEAD_GOT" = "$HEAD_WANT" ] && pass "first 1 MiB hash matches after remount ($HEAD_GOT)" ||
    fail "first 1 MiB hash mismatch after remount: got $HEAD_GOT want $HEAD_WANT"

TAIL_GOT="$(dd if="$BIGFILE" bs=1M count=1 iflag=skip_bytes skip="$TAIL_OFFSET" status=none | sha256sum | awk '{print $1}')"
[ "$TAIL_GOT" = "$TAIL_WANT" ] && pass "last 1 MiB hash matches after remount ($TAIL_GOT)" ||
    fail "last 1 MiB hash mismatch after remount: got $TAIL_GOT want $TAIL_WANT"

log "unmounting and running fsck"
umount "$MNT"
MOUNTED=0
if "$ROOT/userspace/fsck.cetra" "$LOOPDEV" >/tmp/cetrafs-sparse-fsck.out 2>&1; then
    pass "fsck.cetra is clean after the sparse-bigfile run"
else
    fail "fsck.cetra reported a problem: $(cat /tmp/cetrafs-sparse-fsck.out)"
fi
rm -f /tmp/cetrafs-sparse-fsck.out

log "checking dmesg for crashes/warnings during the run"
if dmesg | grep -qiE '\b(BUG|Oops|WARNING)\b'; then
    fail "dmesg shows a BUG/Oops/WARNING during the run"
else
    pass "no BUG/Oops/WARNING in dmesg during the test"
fi

log "unloading module"
rmmod cetrafs
MODULE_LOADED=0

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "$FAILURES CHECK(S) FAILED"
    exit 1
fi
