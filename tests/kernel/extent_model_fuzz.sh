#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Model-based fuzz of the file data path -- the VM-image workload.
#
# A VM image is one large file hit with a long random interleaving of
# mid-file O_DIRECT writes (guest I/O), hole punches (guest TRIM),
# overwrites and truncates, all of which run through the extent tree and
# the data-block bitmap. The per-operation suites (punch_hole,
# extent_tree_depth2, truncate_leaf_unwind, direct_io, fallocate_allocate,
# seek_hole_data, fiemap) each prove one primitive correct; none drives the
# tree deep and fragmented with a random MIX and then proves the bytes are
# still exactly right. Extent split/merge/insert/delete bugs live in those
# interactions -- the same class of "a read walked a stale/wrong part of
# the extent tree" that the directory-leaf bug was.
#
# helpers/extent_model_fuzz.c keeps a shadow model (one write-epoch per
# 4 KiB block; a block's content is a pure function of (block, epoch)) and
# a seeded, reproducible random op stream, reading every block back through
# O_DIRECT (cache=none, the VM path) and asserting it matches the model --
# a written block its pattern, a hole zeros. fsck then proves the other
# half: the extent tree and the bitmap still agree, so no block was leaked
# and -- the failure the scrub once had -- no LIVE block was freed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FUZZ="$(ct_helper extent_model_fuzz)"
OPS="${EMF_OPS:-3000}"
BLOCKS="${EMF_BLOCKS:-16384}" # 64 MiB logical span
SEEDS="${EMF_SEEDS:-1 2 3}"

# Negative control, FIRST: the whole suite rests on "a block that reads
# back different from the model is a bug", so prove that check actually
# fires. selfcheck builds state, corrupts ONE block on the device without
# telling the model, and requires the verifier to catch it -- exit 0 means
# it did, a nonzero exit means the verifier is blind and every pass below
# would be worthless. (CLAUDE.md: every detection needs a negative control
# that injects the fault and requires it to be caught.)
log "negative control: the verifier must catch a planted block mismatch"
SC_DEV="$(ct_loop "$(ct_image 560 emf-sc)")"
SC_MNT="$(ct_mnt emf-sc)"
ct_mkfs_small "$SC_DEV" >/dev/null
ct_mount "$SC_DEV" "$SC_MNT"
require_cetrafs_mount "$SC_MNT"
if "$FUZZ" "$SC_MNT/f" selfcheck; then
    pass "verifier catches a planted block mismatch (negative control)"
else
    fail "verifier MISSED a planted mismatch -- the data check is blind; every pass below is meaningless"
fi
umount "$SC_MNT"

# The real thing: an independent fresh volume per seed, a long random
# write/punch/truncate stream read-back-verified against the model, then
# fsck-clean. Different seeds explore different interleavings; a failure
# names its seed and replays exactly.
for seed in $SEEDS; do
    log "extent/data fuzz: seed=$seed ops=$OPS span=${BLOCKS}blk"
    DEV="$(ct_loop "$(ct_image 560 emf)")"
    MNT="$(ct_mnt emf)"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"

    if "$FUZZ" "$MNT/img" "$seed" "$OPS" "$BLOCKS"; then
        pass "seed $seed: every block read back exactly as the model predicts"
    else
        fail "seed $seed: data mismatch under random write/punch/truncate (replay: $FUZZ <img> $seed $OPS $BLOCKS)"
    fi

    umount "$MNT"
    # A leak is an fsck WARN (exit still 0), so check the OUTPUT too --
    # same discipline as punch_hole.sh.
    FOUT="$(ct_fsck "$DEV" 2>&1)" && FRC=0 || FRC=$?
    if [ "$FRC" = 0 ] && ! echo "$FOUT" | grep -qiE 'leaked|but NO|not reachable|mismatch|ERR'; then
        pass "seed $seed: fsck clean -- extent tree and bitmap agree (no leaked or wrongly-freed block)"
    else
        echo "$FOUT" | tail -20
        fail "seed $seed: fsck found an inconsistency after the fuzz run (rc=$FRC)"
    fi
done

ct_exit
