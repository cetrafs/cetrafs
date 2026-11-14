#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tree-block allocation refused at any point of a fsx run leaves fsck clean and the file as the model says
# ct-timeout: 900
#
# The class 56 instrument (docs/internal/BUG-CLASSES.md): an edit in place
# that removes a reference, followed by a tree-block allocation that can
# fail, leaves the referent named by nothing when the failure is not
# handled. tree_alloc_fail_at makes the Nth tree-block allocation of a run
# fail with ENOSPC: a held-back block, a leaf, an interior, a split's new
# leaf. fsx_cetra runs its model under FSX_ENOSPC=1 for this, where a
# refused operation must have left one of two states -- the file as the
# model stood before it, or as it would stand had it succeeded -- and a
# write may land a prefix at the length it returned.
#
# Mapped writes are plain writes in this run: a refused fault is a SIGBUS,
# not an errno, and mmap_enospc_sigbus.sh is the suite that covers it.
#
# What is asserted
#   1. the baseline run (no injection) completes and makes T tree-block
#      allocations. Setup: 1 <= T <= MAXN, so the sweep covers every one;
#      the injection reached an operation (ENOSPC surfaced at least once),
#      and every operation kind ran;
#   2. for each N in 1..T, with the Nth allocation refused: the knob fired
#      (it reads 0 afterwards), the run passes its model checks, fsck is
#      clean, and after an unmount and a remount the file is byte-identical
#      to the model's dump. The sweep stops at the first N that fails;
#   3. the random model never fills a 254-slot leaf, so it cannot reach a
#      convert whose split needs the tree. A second, fixed workload does:
#      a preallocated file written every other block until its one leaf
#      holds 253 extents (as convert_append_nospc.sh), then one more
#      write and fsync with the Nth tree-block allocation of THAT step
#      refused, for every N it makes. A failed fsync is retried once; after
#      a remount every written block must read back, and fsck be clean;
#   4. NEGATIVE CONTROL: with tree_resv_off (the order before FD-1 fixed:
#      a convert shrinks a full leaf before reserving the append's blocks),
#      the sweep of 3 must find a failing N. A sweep that passes the old
#      order cannot be counted as covering the new one.
#
# Knobs: FSX_ENOSPC_SEED, FSX_ENOSPC_OPS (default 400), FSX_ENOSPC_MAXN
# (default 160) bound the run; the model's stream is a pure function of the
# seed, so N always lands on the same operation.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in tree_alloc_fail_at tree_resv_off; do
    [ -w "$P/$k" ] || { fail "setup: module parameter $k is missing -- the module predates the class 56 instrument"; ct_exit; }
done

SEED="${FSX_ENOSPC_SEED:-11}"
OPS="${FSX_ENOSPC_OPS:-400}"
MAXN="${FSX_ENOSPC_MAXN:-160}"
MAXSIZE="${FSX_ENOSPC_SIZE:-1048576}"
FSX="$(ct_helper fsx_cetra)"
DEV="$(ct_big_dev 1536 fsx-enospc)"
MNT="$(ct_mnt fsx-enospc)"
DUMP="$(ct_tmp fsx-enospc-dump)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
grep -q '^tree_allocs: ' "$INFO" || { fail "setup: info has no tree_allocs -- the module predates the class 56 instrument"; ct_exit; }
allocs() { sed -n 's/^tree_allocs: //p' "$INFO"; }
ct_param_set auto_defrag 0
ct_param_set convert_append_nospc 0
ct_param_set tree_resv_off 0
ct_param_set tree_alloc_fail_at 0

# One fsx run on a fresh file with the Nth tree-block allocation refused
# (0 = no injection). Sets RUN_RC, RUN_OUT, RUN_SEEN (allocations made) and
# RUN_LEFT (the countdown afterwards: 0 means it fired, or was never armed).
run_once() {
    local a0
    a0="$(allocs)"
    ct_param_set tree_alloc_fail_at "$1"
    RUN_RC=0
    RUN_OUT="$(FSX_ENOSPC=1 FSX_DROPCACHE=1 FSX_DUMP="$DUMP" "$FSX" "$MNT/sweep.dat" "$SEED" "$OPS" "$MAXSIZE" 100 2>&1)" || RUN_RC=$?
    RUN_SEEN=$(($(allocs) - a0))
    RUN_LEFT="$(cat "$P/tree_alloc_fail_at")"
}

# Unmount, fsck, remount, and compare the file with the model's dump.
# Sets CHECK_WHY to the first thing wrong, or nothing.
durable_check() {
    CHECK_WHY=""
    ct_umount "$MNT"
    local rc=0 out
    out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    if [ "$rc" != 0 ]; then
        CHECK_WHY="fsck reports a problem: $(grep -m2 -iE 'ERR|problem|leaked|overlap' <<<"$out" | tr '\n' ' ')"
    elif ! cmp -s "$DUMP" "$MNT/sweep.dat"; then
        CHECK_WHY="after a remount the file differs from the model ($(stat -c %s "$DUMP" 2>/dev/null || echo 0) model bytes, file $(stat -c %s "$MNT/sweep.dat" 2>/dev/null || echo missing))"
    fi
}

# The sweep proper: N = 1..T, stopping at the first failure. Sets
# SWEEP_FAIL_N (0 if none) and SWEEP_WHY; SWEEP_T, SWEEP_COVER, SWEEP_ENOSPC.
sweep() {
    SWEEP_FAIL_N=0
    SWEEP_WHY=""
    SWEEP_ENOSPC=0
    local n
    for ((n = 1; n <= SWEEP_T; n++)); do
        run_once "$n"
        SWEEP_COVER=$n
        if [ "$RUN_LEFT" != 0 ]; then
            SWEEP_FAIL_N=$n; SWEEP_WHY="the knob did not fire at allocation $n (the run made $RUN_SEEN, the baseline $SWEEP_T)"
            return 0
        fi
        local got
        got="$(grep -o 'FSX enospc=[0-9]*' <<<"$RUN_OUT" | tail -1 | cut -d= -f2 || true)"
        SWEEP_ENOSPC=$((SWEEP_ENOSPC + ${got:-0}))
        if [ "$RUN_RC" != 0 ] || ! grep -q '^FSX PASS' <<<"$RUN_OUT"; then
            SWEEP_FAIL_N=$n
            SWEEP_WHY="fsx: $(grep -m1 -E 'MISMATCH|I/O ERROR|neither|DID NOT FIRE' <<<"$RUN_OUT" || echo "exit $RUN_RC")"
            return 0
        fi
        durable_check
        if [ -n "$CHECK_WHY" ]; then
            SWEEP_FAIL_N=$n; SWEEP_WHY="$CHECK_WHY"
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------- baseline
run_once 0
if [ "$RUN_RC" = 0 ] && grep -q '^FSX PASS' <<<"$RUN_OUT"; then
    pass "baseline: the fsx run without injection passes ($OPS ops, seed $SEED)"
else
    fail "baseline: fsx fails with no injection: $(grep -m1 -E 'MISMATCH|I/O ERROR|neither' <<<"$RUN_OUT" || echo "exit $RUN_RC")"
    ct_exit
fi
SWEEP_T="$RUN_SEEN"
COUNTS="$(grep '^COUNTS' <<<"$RUN_OUT" || true)"
MISSING=""
for k in read write mread trunc falloc punch zero dread dwrite fsync reopen verify; do
    grep -qE " $k=[1-9][0-9]*" <<<"$COUNTS" || MISSING="$MISSING $k"
done
[ -z "$MISSING" ] && pass "baseline: every operation kind ran (mapped writes are plain writes here)" ||
    fail "baseline: setup did not exercise:$MISSING -- the sweep would check less than it claims"
if [ "$SWEEP_T" -ge 1 ] && [ "$SWEEP_T" -le "$MAXN" ]; then
    pass "baseline: the run makes $SWEEP_T tree-block allocations, all inside the sweep's bound of $MAXN"
else
    fail "setup: the run makes $SWEEP_T tree-block allocations, want 1..$MAXN -- the sweep would not cover them all (shorten FSX_ENOSPC_OPS)"
    ct_exit
fi

# ---------------------------------------------------------- the sweep
sweep
if [ "$SWEEP_FAIL_N" = 0 ] && [ "$SWEEP_COVER" = "$SWEEP_T" ] && [ "$SWEEP_ENOSPC" -ge 1 ]; then
    pass "sweep: each of the $SWEEP_T tree-block allocations refused in turn: fsck clean, the file as the model says after a remount (ENOSPC surfaced $SWEEP_ENOSPC times)"
else
    fail "sweep: allocation $SWEEP_FAIL_N -- $SWEEP_WHY (covered $SWEEP_COVER of $SWEEP_T; ENOSPC surfaced $SWEEP_ENOSPC times)"
fi

# ---------------------------------------------------------- the full leaf
LEAFW="$(ct_tmp fsx-enospc-leaf.py)"
cat >"$LEAFW" <<'PY'
import fcntl, os, struct, sys
path, armp, infop, n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def allocs():
    for l in open(infop):
        if l.startswith("tree_allocs: "):
            return int(l.split()[1])
fd = os.open(path, os.O_RDWR)
def extents():
    buf = bytearray(struct.pack("QQIIII", 0, 2**64 - 1, 0, 0, 0, 0))
    fcntl.ioctl(fd, 0xC020660B, buf)
    return struct.unpack("QQIIII", bytes(buf))[3]
i = 1
while extents() < 253 and i < 400:
    os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
    os.fsync(fd)
    i += 1
full = extents()
a0 = allocs()
open(armp, "w").write(n)
os.pwrite(fd, bytes([65 + i % 26]) * 4096, 2 * i * 4096)
try:
    os.fsync(fd); first = "ok"
except OSError as e:
    first = "ENOSPC" if e.errno == 28 else "err%d" % e.errno
try:
    os.fsync(fd); second = "ok"
except OSError as e:
    second = "err%d" % e.errno
seen = allocs() - a0
left = open(armp).read().strip()
open(armp, "w").write("0")
try:
    os.close(fd)  # close may report the write error again, as in convert_append_nospc.sh
except OSError:
    pass
print(full, i, first, second, seen, left, flush=True)
PY
LEAFR="$(ct_tmp fsx-enospc-leafr.py)"
cat >"$LEAFR" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
print(sum(1 for i in range(1, int(sys.argv[2]) + 1) for x in os.pread(fd, 4096, 2 * i * 4096) if x != 65 + i % 26), flush=True)
PY

# leaf_once <N>: one full-leaf step with its Nth tree-block allocation
# refused. Sets LEAF_FULL LEAF_FIRST LEAF_SEEN LEAF_LEFT LEAF_WHY.
leaf_once() {
    local i second bad rc=0 out
    rm -f "$MNT/leaf.dat"
    fallocate -l 4M "$MNT/leaf.dat"
    read -r LEAF_FULL i LEAF_FIRST second LEAF_SEEN LEAF_LEFT <<<"$(python3 "$LEAFW" "$MNT/leaf.dat" \
        "$P/tree_alloc_fail_at" "$INFO" "$1")"
    LEAF_WHY=""
    ct_umount "$MNT"
    out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
    ct_mount "$DEV" "$MNT"
    bad="$(python3 "$LEAFR" "$MNT/leaf.dat" "$i")"
    if [ "$second" != ok ]; then
        LEAF_WHY="the retried fsync failed ($second)"
    elif [ "$bad" != 0 ]; then
        LEAF_WHY="$bad byte(s) of written blocks read back wrong after a remount"
    elif [ "$rc" != 0 ]; then
        LEAF_WHY="fsck: $(grep -m2 -iE 'ERR|problem|leaked|overlap' <<<"$out" | tr '\n' ' ')"
    fi
}

# leaf_sweep: N = 1..LEAF_T, first failure stops it. Sets LEAF_FAIL_N, LEAF_FAIL_WHY, LEAF_HITS.
leaf_sweep() {
    LEAF_FAIL_N=0; LEAF_FAIL_WHY=""; LEAF_HITS=0
    local n
    for ((n = 1; n <= LEAF_T; n++)); do
        leaf_once "$n"
        [ "$LEAF_FIRST" = ENOSPC ] && LEAF_HITS=$((LEAF_HITS + 1))
        if [ "$LEAF_LEFT" != 0 ]; then
            LEAF_FAIL_N=$n; LEAF_FAIL_WHY="the knob did not fire at allocation $n"; return 0
        fi
        if [ -n "$LEAF_WHY" ]; then
            LEAF_FAIL_N=$n; LEAF_FAIL_WHY="$LEAF_WHY"; return 0
        fi
    done
}

leaf_once 0
LEAF_T="$LEAF_SEEN"
if [ "$LEAF_FULL" = 253 ] && [ "${LEAF_T:-0}" -ge 1 ] && [ -z "$LEAF_WHY" ]; then
    pass "full leaf: setup -- 253 extents in the leaf, and the next convert makes $LEAF_T tree-block allocation(s)"
else
    fail "full leaf: setup -- $LEAF_FULL extents, $LEAF_T tree-block allocation(s), '$LEAF_WHY': the step does not need the tree"
    ct_exit
fi
leaf_sweep
[ "$LEAF_FAIL_N" = 0 ] && [ "$LEAF_HITS" -ge 1 ] &&
    pass "full leaf: each of its $LEAF_T tree-block allocations refused in turn: every written block reads back, fsck clean (ENOSPC surfaced $LEAF_HITS times)" ||
    fail "full leaf: allocation $LEAF_FAIL_N -- $LEAF_FAIL_WHY (ENOSPC surfaced $LEAF_HITS times)"

# ---------------------------------------------------------- negative control
# The pre-FD-1 order (tree_resv_off) must be found by the same sweep. If it
# is not, the sweep does not reach that site and proves nothing about it.
ct_param_set tree_resv_off 1
leaf_sweep
ct_param_set tree_resv_off 0
if [ "$LEAF_FAIL_N" != 0 ]; then
    pass "control: with tree_resv_off the full-leaf sweep fails at allocation $LEAF_FAIL_N ($LEAF_FAIL_WHY)"
else
    fail "control: with tree_resv_off the full-leaf sweep passes -- it does not reach the convert append's blocks"
fi

ct_exit
