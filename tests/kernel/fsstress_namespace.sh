#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsstress-style multi-process namespace churn (create, link, rename incl. cross-dir and over, rmdir, xattr, chmod) with a per-process model, then fsck
# ct-timeout: 900
#
# tests/helpers/fsstress_cetra.c runs several processes at once, each on a
# seeded stream of namespace operations: create, write, truncate, unlink,
# hard and symbolic links, rename within and across directories (over an
# existing name too), mkdir and rmdir, setxattr and removexattr, chmod,
# fsync, and read-back checks. A process's own tree is modelled exactly
# (names, hard-link sets, nlink, sizes and bytes, modes, xattrs, symlink
# targets); a shared directory where every process races on the same
# names is checked only against the errno contract. Nothing else in the
# tree is exercised by a serial suite, and nothing checks a namespace
# under concurrent renames without this.
#
# What is asserted
#   1. every process agrees with its model at the end of its run (the tool
#      exits 0), and no shared-directory call failed with an errno outside
#      the race contract (EIO, EUCLEAN, ENOSPC and friends are failures);
#   2. setup: every operation class ran at least once across the processes;
#   3. after the run the volume is unmounted and fsck is clean: no leaked
#      block, no orphan (allocated, nlink=0) inode, no structural problem;
#   4. NEGATIVE CONTROL: FSSTRESS_NEGATIVE=1 makes process 0's model wrong
#      by one byte in one file; the run must exit nonzero. A checker that
#      cannot see a wrong model proves nothing about a right one.
#
# Knobs: FSSTRESS_SEEDS (space list), FSSTRESS_PROCS, FSSTRESS_OPS,
# FSSTRESS_LONG=1 (eight processes, 5000 ops each, three seeds). A failure
# prints the seed, process and op; rerun with FSSTRESS_SEEDS=<seed>.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

STRESS="$(ct_helper fsstress_cetra)"
# The scrub reclaims the residue a racing delete leaves (an allocated
# nlink=0 inode). It is armed here at a short interval, as churn_oracle
# arms it, so the orphan assertion below judges the volume after the
# scrub has had its quiet cycles rather than before.
ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
DEV="$(ct_big_dev 1536 fsstress)"
MNT="$(ct_mnt fsstress)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -N 4096 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

if [ "${FSSTRESS_LONG:-0}" = 1 ]; then
    SEEDS="${FSSTRESS_SEEDS:-1 2 3}"
    PROCS="${FSSTRESS_PROCS:-8}"
    OPS="${FSSTRESS_OPS:-5000}"
else
    SEEDS="${FSSTRESS_SEEDS:-1 2}"
    PROCS="${FSSTRESS_PROCS:-4}"
    OPS="${FSSTRESS_OPS:-1000}"
fi
log "fsstress: seeds=[$SEEDS] procs=$PROCS ops/proc=$OPS"

CLASSES="creat write trunc unlink link symlink rename mkdir rmdir setx rmx chmod fsync verify shared"
n=0
for s in $SEEDS; do
    n=$((n + 1))
    dir="$MNT/run-$s"
    mkdir "$dir"
    rc=0
    out="$("$STRESS" "$dir" "$s" "$PROCS" "$OPS" 2>&1)" || rc=$?
    if [ "$rc" = 0 ] && grep -q '^FSSTRESS PASS' <<<"$out"; then
        pass "fsstress seed $s: $PROCS processes agreed with their models"
    else
        fail "fsstress seed $s exited $rc: $(grep -m1 'MISMATCH\|FAILED' <<<"$out" || echo 'no reason printed')"
    fi
    # Setup: each class must have run. Summed over the processes, a class
    # with no count is one the run did not check, whatever it reports.
    allcounts="$(grep '^COUNTS' <<<"$out" || true)"
    missing=""
    for c in $CLASSES; do
        grep -qE " $c=[1-9][0-9]*" <<<"$allcounts" || missing="$missing $c"
    done
    if [ -z "$missing" ]; then
        pass "fsstress seed $s: every operation class ran in at least one process"
    else
        fail "fsstress seed $s: setup did not run:$missing -- the namespace was not churned as claimed"
    fi
done

# ------------------------------------------------- quiet scrub, unmount, fsck
# The shared directory races creates against unlinks on purpose, and a
# delete that loses such a race leaves an allocated nlink=0 inode that the
# scrub reclaims (fsck's own note: "reclaimable (-r, or the online scrub)").
# With the volume quiet, two full scrub cycles must have run before the
# verdict: that is the scrub doing its job, and an orphan that survives
# them is a real failure.
PROC="$(ct_procdir "$DEV")"
scrub_cycles() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }
C0="$(scrub_cycles)"
wait_for 60 '[ "$(( $(sed -n "s/^scrub_cycles: //p" "'"$PROC"'/info") - '"$C0"' ))" -ge 2 ]' ||
    fail "the scrub ran fewer than two quiet cycles -- the orphan verdict below would be made before it could reclaim anything"
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
if [ "$FSCK_RC" = 0 ]; then
    pass "fsck is clean after the namespace churn"
else
    fail "fsck reports a problem after the namespace churn: $(grep -m2 -iE 'ERR|problem|overlap' <<<"$FSCK_OUT" | tr '\n' ' ')"
fi
ORPHANS="$(grep -c 'is allocated but has nlink=0' <<<"$FSCK_OUT" || true)"
if [ "$ORPHANS" = 0 ]; then
    pass "no orphan inode (allocated, nlink=0) survived the run"
else
    fail "$ORPHANS orphan inode(s) survived the run -- a name was dropped without its inode"
fi
LEAKED="$(sed -n 's/^WARN: \([0-9]*\) data block(s) marked in use but referenced by no inode (leaked)/\1/p' <<<"$FSCK_OUT" | head -1)"
[ -n "$LEAKED" ] || LEAKED=0
if [ "$LEAKED" = 0 ]; then
    pass "fsck finds no leaked data blocks"
else
    fail "fsck finds $LEAKED leaked data block(s) after the namespace churn"
fi

# ---------------------------------------------------------- negative control
# A fresh mount: the control must not share a volume with a run that
# already failed for a different reason.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/negative"
rc=0
out="$(FSSTRESS_NEGATIVE=1 "$STRESS" "$MNT/negative" 9 4 300 2>&1)" || rc=$?
if [ "$rc" = 1 ] && grep -q 'NEGATIVE CONTROL: proc 0' <<<"$out" && grep -q 'FSSTRESS MISMATCH' <<<"$out"; then
    pass "negative control: process 0's model off by one byte was reported as a MISMATCH"
else
    fail "negative control NOT caught (exit $rc): $(grep -m1 'FSSTRESS' <<<"$out" || echo 'no output')"
fi

ct_exit
