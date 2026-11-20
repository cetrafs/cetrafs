#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# what the fence witness read costs per operation, on real hardware (DESTRUCTIVE)
#
# Audit 2026-11-15 F-13: every journaled block, record publish, tree
# batch, bitmap flush, discard run and zero-out extent first asks
# cetrafs_sb_fence_witnessed(), a forced-fresh read of this node's own
# registry row. On a loop device that read is served from the host page
# cache and costs nothing, so `make check` cannot see it; on an array it
# is a round trip (5.5 ms measured on the reference iSCSI LUN) ahead of
# the first write of each operation.
#
# This measures it. Each workload runs twice on one mount: with the
# witness (the shipped behaviour) and with fence_witness_off=1 (TEST knob:
# no witness read). It prints ms per operation and witness reads per
# operation for both, and the difference is the witness's cost.
#   1. append + fdatasync (record publish, bitmap flush, tree batch)
#   2. create + unlink in one directory (journaled dirent blocks)
#   3. 4 KiB overwrite + fdatasync of written blocks (the VM steady state)
# Asserted: the instrument works -- the witnessed run reads the row at
# least once per operation of workloads 1 and 2, and the run with the
# witness off reads it zero times. The timings are a measurement, not an
# assertion; read them against the per-read latency the log prints.
#
# DESTRUCTIVE: it mkfs'es the device you name. No default, and `make
# check` never runs it. Needs a module built WITHOUT CETRAFS_RELEASE (the
# knob is read-only in a release build).
#
#   ./tests/device/fence_witness_cost.sh /dev/sdX [ops]
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}
fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}
log() { echo "== $1"; }

DEV="${1:-}"
OPS="${2:-300}"
if [ -z "$DEV" ]; then
    echo "usage: $0 <device> [ops]   (DESTRUCTIVE -- the device is reformatted)" >&2
    exit 2
fi
[ "$(id -u)" = 0 ] || { echo "must be run as root" >&2; exit 2; }
[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 2; }
if grep -q "^$(readlink -f "$DEV") " /proc/mounts || grep -q "^$DEV " /proc/mounts; then
    echo "$DEV is mounted -- refusing" >&2
    exit 2
fi

MNT="$(mktemp -d /tmp/cetrafs-fwc-mnt-XXXXXX)"
MOUNTED=0
MODULE_LOADED=0
P=/sys/module/cetrafs/parameters
cleanup() {
    set +e
    [ -w "$P/fence_witness_off" ] && echo 0 >"$P/fence_witness_off"
    [ "$MOUNTED" = 1 ] && umount "$MNT" 2>/dev/null
    [ "$MODULE_LOADED" = 1 ] && rmmod cetrafs 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

modprobe libcrc32c 2>/dev/null
if ! grep -q '^cetrafs ' /proc/modules; then
    insmod "$ROOT/kmod/cetrafs.ko" || { echo "insmod failed" >&2; exit 2; }
    MODULE_LOADED=1
fi
[ -w "$P/fence_witness_off" ] || {
    echo "fence_witness_off is not writable (a CETRAFS_RELEASE build?) -- nothing to compare" >&2
    exit 2
}

log "formatting $DEV"
"$ROOT/userspace/mkfs.cetra" "$DEV" -f >/dev/null || { fail "mkfs failed"; exit 1; }
mount -t cetrafs "$DEV" "$MNT" || { fail "mount failed"; exit 1; }
MOUNTED=1
INFO="/proc/fs/cetrafs/$(basename "$(readlink -f "$DEV")")/info"
[ -r "$INFO" ] || { fail "no procfs info at $INFO"; exit 1; }
grep -q '^fence_witness_reads:' "$INFO" || { fail "no fence_witness_reads counter"; exit 1; }

# <workload> <off 0|1> -> "ms_per_op=X reads_per_op=Y"
run() {
    local w="$1" off="$2" out
    echo "$off" >"$P/fence_witness_off"
    out="$(python3 -I - "$MNT" "$INFO" "$w" "$OPS" "$off" <<'PY'
import os, sys, time
mnt, info, w, n, off = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
def reads():
    for line in open(info):
        if line.startswith("fence_witness_reads:"):
            return int(line.split()[1])
    raise SystemExit("no counter")
buf = os.urandom(4096)
d = os.path.join(mnt, "%s-%s" % (w, off))
os.mkdir(d)
if w == "overwrite":
    fd = os.open(os.path.join(d, "f"), os.O_RDWR | os.O_CREAT, 0o644)
    for i in range(64):
        os.pwrite(fd, buf, i * 4096)
    os.fsync(fd)
r0 = reads()
t0 = time.monotonic()
if w == "append":
    fd = os.open(os.path.join(d, "f"), os.O_RDWR | os.O_CREAT, 0o644)
    for i in range(n):
        os.pwrite(fd, buf, i * 4096)
        os.fdatasync(fd)
    os.close(fd)
elif w == "create":
    for i in range(n):
        p = os.path.join(d, "n%d" % i)
        os.close(os.open(p, os.O_CREAT | os.O_WRONLY, 0o644))
        os.unlink(p)
    os.fsync(os.open(d, os.O_RDONLY))
else:
    for i in range(n):
        os.pwrite(fd, buf, (i % 64) * 4096)
        os.fdatasync(fd)
    os.close(fd)
dt = time.monotonic() - t0
print("ms_per_op=%.3f reads_per_op=%.2f" % (dt * 1000 / n, (reads() - r0) / n), flush=True)
PY
)"
    echo 0 >"$P/fence_witness_off"
    echo "$out"
}
field() { sed -n "s/.*\b$1=\([0-9.]*\).*/\1/p" <<<"$2"; }

for w in append create overwrite; do
    ON="$(run "$w" 0)"
    OFF="$(run "$w" 1)"
    log "$w x$OPS: witness on: $ON | witness off: $OFF"
    python3 -I -c 'import sys; a,b=float(sys.argv[1]),float(sys.argv[2]); print("== %s: the witness costs %.3f ms per operation (%.1f%%)" % (sys.argv[3], a-b, (a-b)*100/b if b else 0))' \
        "$(field ms_per_op "$ON")" "$(field ms_per_op "$OFF")" "$w"
    R_OFF="$(field reads_per_op "$OFF")"
    [ "$R_OFF" = "0.00" ] && pass "$w: with the witness off, no witness read" ||
        fail "$w: the witness was read with the knob off ($OFF) -- the comparison is void"
    case "$w" in append | create)
        python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 1 else 1)' "$(field reads_per_op "$ON")" &&
            pass "$w: the witnessed run reads the row at least once per operation" ||
            fail "$w: fewer witness reads than operations ($ON) -- not the path F-13 is about" ;;
    esac
done

umount "$MNT" && MOUNTED=0
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null && pass "fsck clean after the runs" || fail "fsck after the runs"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
