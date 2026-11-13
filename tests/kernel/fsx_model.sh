#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsx-style seeded data ops (buffered, mapped, O_DIRECT, fallocate, punch, zero-range) against a model, remounted and compared
# ct-timeout: 900
#
# tests/helpers/fsx_cetra.c drives a seeded random stream over one file:
# buffered and mapped reads and writes, truncate, fallocate (allocate,
# keep-size, punch, zero-range), O_DIRECT reads and writes, fsync and
# close-reopen. Every read is compared with an in-memory model as it is
# made, the size after every op, and the whole file every check interval.
# This is the interaction-of-everything tool that finds punch-versus-
# preallocation and mapping-versus-write bugs in minutes; churn_oracle.sh
# is the concurrent cousin with its own oracle, and this suite is the
# serial, mmap-and-punch-aware one.
#
# What is asserted
#   1. every seed runs to completion: every op kind was exercised (setup),
#      every read and full check matched the model, and the size matched
#      after every op;
#   2. after an unmount and a remount, each file is byte-identical to the
#      model's dump (kept outside the filesystem), and fsck is clean;
#   3. NEGATIVE CONTROL: with FSX_NEGATIVE the tool corrupts one byte of its
#      MODEL on purpose; the run must exit 1 with a MISMATCH. A tool that
#      passes with a broken model cannot be trusted with a clean one.
#
# Replay: a failure prints the seed, the op index and the last ops; run
# FSX_SEED=<seed> with the same FSX_OPS to reproduce it exactly.
# Knobs: FSX_SEEDS (space list), FSX_OPS, FSX_LONG=1 (eight seeds at
# 40000 ops each, for an unattended run; the default is three short seeds).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FSX="$(ct_helper fsx_cetra)"
DEV="$(ct_big_dev 1536 fsx)"
MNT="$(ct_mnt fsx)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

if [ -n "${FSX_SEED:-}" ]; then
    SEEDS="$FSX_SEED"
elif [ "${FSX_LONG:-0}" = 1 ]; then
    SEEDS="${FSX_SEEDS:-1 2 3 4 5 6 7 8}"
else
    SEEDS="${FSX_SEEDS:-1 2 3}"
fi
if [ "${FSX_LONG:-0}" = 1 ]; then OPS_DEFAULT=40000; else OPS_DEFAULT=3000; fi
OPS="${FSX_OPS:-$OPS_DEFAULT}"
log "fsx: seeds=[$SEEDS] ops=$OPS (replay one with FSX_SEED=<seed> FSX_OPS=$OPS)"

KINDS="read write mread mwrite trunc falloc punch zero dread dwrite fsync reopen verify"
DUMPS=""
for s in $SEEDS; do
    f="$MNT/fsx-$s.dat"
    d="$(ct_tmp fsx-dump)"
    rc=0
    out="$(FSX_DROPCACHE=1 FSX_DUMP="$d" "$FSX" "$f" "$s" "$OPS" 4194304 500 2>&1)" || rc=$?
    if [ "$rc" = 0 ] && grep -q '^FSX PASS' <<<"$out"; then
        pass "fsx seed $s: $OPS ops, every read and full check matched the model"
    else
        fail "fsx seed $s exited $rc: $(grep -m1 -E 'MISMATCH|I/O ERROR|DID NOT FIRE' <<<"$out" || echo 'no reason printed')"
        sed -n '1,30p' <<<"$out" | sed 's/^/    | /'
    fi
    # Setup: the mix must actually have exercised every kind. An op that
    # never ran checks nothing, and a green run that did not run it is a lie.
    counts="$(grep '^COUNTS' <<<"$out" || true)"
    missing=""
    for k in $KINDS; do
        grep -qE " $k=[1-9][0-9]*" <<<"$counts" || missing="$missing $k"
    done
    if [ -z "$missing" ]; then
        pass "fsx seed $s: every operation kind ran"
    else
        fail "fsx seed $s: setup did not exercise:$missing -- the run checked less than it claims"
    fi
    DUMPS="$DUMPS $s:$d"
done

# ---------------------------------------------------------- remount + compare
# The model is compared against the page cache during the run. After an
# unmount and a remount the bytes must come back off the device unchanged,
# which is the durability half of the same claim.
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
if [ "$FSCK_RC" = 0 ]; then
    pass "fsck is clean after the fsx run"
else
    fail "fsck reports a problem after the fsx run: $(grep -m2 -iE 'ERR|problem|leaked|overlap' <<<"$FSCK_OUT" | tr '\n' ' ')"
fi
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for pair in $DUMPS; do
    s="${pair%%:*}"
    d="${pair#*:}"
    f="$MNT/fsx-$s.dat"
    if [ -s "$d" ] && cmp -s "$d" "$f"; then
        pass "seed $s: after a remount the file is byte-identical to the model ($(stat -c %s "$f") bytes)"
    else
        fail "seed $s: after a remount the file differs from the model (model $(stat -c %s "$d" 2>/dev/null || echo 0) bytes, file $(stat -c %s "$f" 2>/dev/null || echo missing))"
        cmp "$d" "$f" 2>&1 | head -1 | sed 's/^/    | /' || true
    fi
done

# ---------------------------------------------------------- negative control
# The tool's model is deliberately wrong from op NEG on: the byte it
# corrupts is read back at once, so the mismatch is reported immediately.
# The control must be CAUGHT -- exit 1 with a MISMATCH -- and it must be
# caught for that reason, not because the tool could not run (2) or never
# reached the control (3).
NEG_FILE="$MNT/fsx-negative.dat"
rc=0
out="$(FSX_NEGATIVE=150 "$FSX" "$NEG_FILE" 5 1000 2>&1)" || rc=$?
if [ "$rc" = 1 ] && grep -q 'FSX MISMATCH' <<<"$out" && grep -q 'NEGATIVE CONTROL' <<<"$out"; then
    pass "negative control: a model byte corrupted on purpose (op 150) was reported as a MISMATCH"
else
    fail "negative control NOT caught (exit $rc): the tool's own check is blind to a wrong model -- $(grep -m1 'FSX' <<<"$out" || echo 'no output')"
fi

ct_exit
