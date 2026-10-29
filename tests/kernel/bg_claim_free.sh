#!/usr/bin/env bash
# a Block Group owned by nobody is legal, is not allocated from, and is claimed with one atomic swap
#
# STAGE 3 of docs/internal/BG-OWNERSHIP-DESIGN.md. Stage 2 made each
# Block Group name its owner; this adds the state where it names
# nobody, and the claim that moves one out of that state.
#
# Why it matters: a grow can then add capacity without deciding in
# advance which node gets it, and -- once stage 4 lands -- a node
# sitting on empty Block Groups can hand them back for somebody else to
# take. Both need "unowned" to be a thing the format can say.
#
# The claim has to be a single compare-and-swap on the Block Group's
# own record, not a read-then-write: two nodes reaching for the same
# free Block Group at the same moment must resolve to exactly one
# winner, and the loser must not have damaged anything. The record's
# live fields end at byte 68 with its checksum at 52, so the whole
# thing fits inside one 512-byte sector -- the same unit every other
# contested claim in this filesystem uses.
#
# Written before the feature exists, and expected to FAIL until it
# does: that is the evidence these assertions test the new behaviour
# rather than describing the old.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FREE_MARK=65535

POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 1200 bgclaim)"
MNT="$(ct_mnt bgclaim)"
W="$(ct_mnt bgclaimwork)"

ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null

# ------------------------------------------------ the unowned state
log "a Block Group owned by nobody is a legal on-disk state"
"$POKE" "$DEV" 1 --owner "$FREE_MARK" >/dev/null

if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "fsck accepts a Block Group owned by nobody"
else
    fail "fsck rejects the unowned state: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"
fi

owner="$("$MAP" "$DEV" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
[ "$owner" = "$FREE_MARK" ] && pass "the unowned marker survives on disk" ||
    fail "Block Group 1 reads owner=$owner, expected $FREE_MARK"

# An owner that is neither a real Zone Group nor the free marker must
# still be refused -- otherwise "unowned" would just be a hole in the
# validation rather than a state.
"$POKE" "$DEV" 1 --owner 250 >/dev/null
if ct_fsck "$DEV" >/dev/null 2>&1; then
    fail "fsck accepted a Block Group owned by Zone Group 250, which does not exist"
else
    pass "a nonexistent owner is still rejected"
fi
"$POKE" "$DEV" 1 --owner "$FREE_MARK" >/dev/null

# ------------------------------------- it is not allocated from unclaimed
log "an unowned Block Group is not treated as this node's"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="/proc/fs/cetrafs/$(basename "$DEV")/info"
members="$(grep -oE 'block_groups=[0-9]+' "$INFO" | grep -oE '[0-9]+' | awk '{t+=$1} END{print t+0}')"
[ "${members:-0}" -lt 2 ] &&
    pass "the Zone Groups account for $members Block Group(s), not the unowned one" ||
    fail "the unowned Block Group is still counted as a member ($members)"
ct_umount "$MNT"

# ----------------------------------------------------- the claim itself
log "a node out of space claims the unowned Block Group"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Fill everything this node owns, so the next allocation has to reach
# for the unowned Block Group or fail.
i=0
while dd if=/dev/urandom of="$MNT/f$i" bs=1M count=16 status=none 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 200 ] && break
done
sync
[ "$i" -gt 4 ] && pass "filled this node's own Block Groups ($i files)" ||
    fail "only $i files written -- the volume is not what this suite assumes"

# The fill loop itself is the evidence: with only one Block Group owned
# it could not have got past ~512 MiB, so writing substantially more
# means the unowned one was claimed mid-fill and used. An earlier
# version wrote one more file AFTER the loop and called that the proof
# -- but the loop had already consumed the newly claimed Block Group
# too, so the follow-up correctly failed and the test blamed the claim.
written_mib=$((i * 16))
if [ "$written_mib" -gt 600 ]; then
    pass "wrote ${written_mib} MiB across more than the one owned Block Group (512 MiB)"
else
    fail "only ${written_mib} MiB written -- allocation stopped inside the one owned Block Group"
fi
ct_umount "$MNT"

claimed="$("$MAP" "$DEV" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
[ "$claimed" != "$FREE_MARK" ] &&
    pass "the Block Group is now owned by Zone Group $claimed, not free" ||
    fail "the Block Group is still unowned after the volume ran out of space"

ct_fsck "$DEV" >/dev/null 2>&1 && pass "clean after the claim" ||
    fail "not clean after the claim: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"

# ------------------------------------------------ concurrent claimers
#
# Two writers racing to exhaust the volume at the same moment both reach
# the claim path. Exactly one may win each free Block Group: if both
# "win" the same one, both roll its capacity into a Zone Group aggregate
# and fsck reports the aggregate as larger than the Block Groups behind
# it.
#
# HONEST LIMIT: a loop device has no atomic COMPARE AND WRITE, so the
# swap here takes caw.c's serialised fallback and what this really
# exercises is same-node exclusion. That is worth guarding -- two local
# threads racing was a real bug class in this filesystem before -- but
# the cross-node claim is only genuinely tested by ctest.
log "two writers racing into the claim path"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
"$POKE" "$DEV" 1 --owner "$FREE_MARK" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# A claim double-count has a SIGNATURE that benign drift does not: two
# claimers each roll a WHOLE Block Group's data capacity into their Zone
# Group aggregate, so a doubly-counted aggregate is off by ~a full BG
# (130k+ blocks for the 512 MiB BGs this suite builds). The ordinary
# concurrent-ENOSPC free-count drift -- a CACHE lag the bitmap never
# shares, benign per docs/internal/OPEN-DEFECTS.md and CLAUDE.md, and
# measured on 0.8.2 too -- is bounded by the write volume and runs in the
# low thousands. Measured empirically: 30-run sweeps drift ~25% of the
# time by at most ~3600 blocks; a real double-count is 130k. 50000 sits
# in the 30x gap between them. (Tied to -b 512 below; revisit for other
# BG sizes.)
CLAIM_DOUBLECOUNT_MIN=50000

# Largest free-count discrepancy fsck reports, across both the ZG
# aggregate check ("ZG.. aggregate free_data_blocks A != B") and the
# per-BG check ("BG.. cached free_data_blocks A != B actually free..").
# Echoes 0 when there is no count drift at all.
max_count_drift() {
    printf '%s\n' "$1" |
        sed -n 's/.*free_data_blocks \([0-9]*\) != \([0-9]*\).*/\1 \2/p' |
        awk '{ d = $1 - $2; if (d < 0) d = -d; if (d > m) m = d } END { print m + 0 }'
}

race_fill() {
    local tag="$1" n=0
    while dd if=/dev/urandom of="$MNT/${tag}_$n" bs=1M count=8 status=none 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -gt 120 ] && break
    done
}
race_fill a & p1=$!
race_fill b & p2=$!
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
sync
ct_umount "$MNT"

# This workload -- two writers racing to ENOSPC -- also triggers the
# pre-existing cross-file overlap recorded in
# docs/internal/OPEN-DEFECTS.md, at roughly one run in forty and on the
# released 0.8.2 too. So a bare "fsck must be clean" here is a flake
# that has nothing to do with claiming, and that file says in as many
# words not to build one.
#
# What belongs to the CLAIM is the aggregate: if two claimers both won
# the same Block Group, both rolled its capacity into a Zone Group and
# the aggregate exceeds the Block Groups behind it. That is asserted.
# The other structural classes are reported as the known defect, not
# passed over in silence and not blamed on this code.
race_out="$(ct_fsck "$DEV" 2>&1 || true)"
race_drift="$(max_count_drift "$race_out")"
if [ "$race_drift" -ge "$CLAIM_DOUBLECOUNT_MIN" ]; then
    fail "concurrent claimers double-counted a Block Group ($race_drift blocks): $(printf '%s' "$race_out" | grep -m1 free_data_blocks)"
elif grep -qE 'more than one inode|cross-file overlap|dirent-tail magic' <<<"$race_out"; then
    skip "hit the known concurrent-ENOSPC overlap defect (OPEN-DEFECTS.md #1), not a claim fault: $(printf '%s' "$race_out" | grep -m1 ERR)"
elif [ "$race_drift" -gt 0 ]; then
    # A sub-floor free-count drift is the benign cache lag the same
    # workload produces WITHOUT any claim (ZG-aggregate form there,
    # per-BG form here) -- not a claim fault. The swap's real proof is
    # the blind negative control below, which forces the double-count.
    skip "benign free-count cache drift of $race_drift blocks (below the ${CLAIM_DOUBLECOUNT_MIN}-block double-count floor); claim exclusion is measured by the blind control"
elif grep -q ERR <<<"$race_out"; then
    fail "concurrent claimers left it inconsistent: $(printf '%s' "$race_out" | grep -m1 ERR)"
else
    pass "concurrent claimers left the volume consistent"
fi

# ---------------------------------- does the swap do the excluding?
#
# Repeat with the claim forced to a blind read-decide-write. If the
# compare-and-swap is what keeps two claimers off one Block Group, this
# must now produce the double-count fsck looks for. If it passes anyway,
# the check above proves nothing about the swap.
if [ -w /sys/module/cetrafs/parameters/bg_claim_blind ]; then
    log "discrimination: the same race with the swap replaced by a blind write"
    ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
    "$POKE" "$DEV" 1 --owner "$FREE_MARK" >/dev/null
    ct_param_set bg_claim_blind 1
    ct_mount "$DEV" "$MNT"
    race_fill c & p3=$!
    race_fill d & p4=$!
    wait "$p3" 2>/dev/null || true
    wait "$p4" 2>/dev/null || true
    sync
    ct_umount "$MNT"
    ct_param_set bg_claim_blind 0
    blind_out="$(ct_fsck "$DEV" 2>&1 || true)"
    blind_drift="$(max_count_drift "$blind_out")"
    if [ "$blind_drift" -ge "$CLAIM_DOUBLECOUNT_MIN" ]; then
        pass "a blind claim double-counts a Block Group ($blind_drift blocks): the swap is what prevents it"
    elif grep -qE 'more than one inode|cross-file overlap|dirent-tail magic' <<<"$blind_out"; then
        skip "the blind run hit the known concurrent-ENOSPC overlap defect first (OPEN-DEFECTS.md #1) -- the swap stays unmeasured this time"
    else
        # A sub-floor drift (or none) is benign cache lag, NOT the
        # double-count: the two blind claimers did not both win the same
        # Block Group this run, so the swap stays unmeasured. Passing on
        # benign drift would be a false proof -- that drift happens with
        # the swap ON too.
        skip "the blind claim produced no double-count-sized drift (${blind_drift} blocks) -- the race did not land, so the swap stays unmeasured"
    fi
else
    skip "bg_claim_blind unavailable -- cannot measure what the swap contributes"
fi

ct_exit