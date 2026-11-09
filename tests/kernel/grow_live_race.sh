#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two live growers never both grow, and the kernel refuses a grow computed from a superseded superblock
#
# Two growers would compute the same new space from the same superblock
# and write their Block Groups over each other's -- and the second could
# do it after the first had published and nodes had begun to allocate
# there. The exclusion is the volume's repair claim (kmod/grow.c's
# header): growfs holds it from before it reads the superblock it
# computes from until after the publish, and refuses or yields when it
# finds another claim.
#
#  A. two live growers pass the "is anyone repairing?" check together
#     (CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS): at most one publishes, the
#     layout moves by at most one generation, and fsck is clean.
#  B. a live grower starting while another holds the claim
#     (CETRAFS_TEST_REPAIR_HOLD_SECS) refuses; the holder completes.
#  C. the kernel's own check behind the claim: a superblock that is not
#     exactly one generation ahead of the published one -- what a grower
#     that read a superseded superblock would submit -- is refused
#     (-ESTALE) with nothing written (CETRAFS_GROWFS_TEST_GEN_SKIP).
#  D. a live grow that outlasts several heartbeats of the mounted node
#     completes. The claim's timer watched for REGISTERED rows beating
#     under it -- right for an offline repair, where one means a node got
#     in, and wrong for a live grow, whose volume is mounted by design:
#     every live grow longer than one renewal died at its first write
#     (GROWFS-LIVE-REVIEW M1). Held with CETRAFS_TEST_REPAIR_HOLD_SECS.
#  E. the kernel refuses to publish a grow while no growfs claim is held
#     (-EBUSY): the claim was a premise about the caller, and any
#     CAP_SYS_ADMIN program could call the ioctl without it (M2).
#     CETRAFS_GROWFS_TEST_UNCLAIMED releases the claim before the call.
#
# DISCRIMINATION: C is the negative control of the kernel's generation
# check -- the same grow without the skip is published (A/B). D fails
# with the beat watch left on in live mode ("a node is mounted on this
# volume while it is being grown", 2026-11-08). E publishes with the
# kernel's claim check removed (2026-11-08). The
# claim's own controls live in repair_claim_concurrent.sh; a race with
# the claim removed is not staged here because its failure is the
# destruction of a live volume's new Block Groups, which no assertion
# afterwards could tell apart from any other corruption.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 5200 growrace)"
MNT="$(ct_mnt growrace)"
WORK="$(ct_mnt growracework)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2 # D needs several beats inside one grow
O1="$(ct_tmp growrace-1)"; O2="$(ct_tmp growrace-2)"

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
sb_sum() { dd if="$DEV" bs=4096 count=1 iflag=direct status=none | md5sum; }
grew() { grep -q 'completed live' "$1"; }

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for i in 0 1 2; do dd if=/dev/urandom of="$MNT/d$i" bs=1M count=8 conv=fsync status=none; done
(cd "$MNT" && md5sum d* >"$WORK/digests")

# ----------------------------------------------------- A: started together
log "A: two live growers pass the claim check together"
gen0="$(info layout_gen)"
CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS=2 ct_growfs "$DEV" -s 1400M >"$O1" 2>&1 &
p1=$!
CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS=2 ct_growfs "$DEV" -s 1400M >"$O2" 2>&1 &
p2=$!
wait "$p1" || true
wait "$p2" || true
n=0; grew "$O1" && n=$((n + 1)); grew "$O2" && n=$((n + 1))
gen1="$(info layout_gen)"
[ "$n" -le 1 ] && pass "A: $n of the two growers published" ||
    fail "A: BOTH growers published -- $(tail -1 "$O1") / $(tail -1 "$O2")"
[ "$gen1" -le "$((gen0 + 1))" ] && [ "$gen1" -eq "$((gen0 + n))" ] &&
    pass "A: the layout moved by exactly the grows that published ($gen0 -> $gen1)" ||
    fail "A: layout_gen $gen0 -> $gen1 with $n grower(s) reporting success"
(cd "$MNT" && md5sum -c --quiet "$WORK/digests") && pass "A: the data reads back intact" ||
    fail "A: data damaged by the racing growers"

# ------------------------------------------------- B: one holds the claim
log "B: a live grower starting while another holds the claim"
gen0="$(info layout_gen)"
CETRAFS_TEST_REPAIR_HOLD_SECS=6 ct_growfs "$DEV" -s 2200M >"$O1" 2>&1 &
p1=$!
sleep 2
if ct_growfs "$DEV" -s 2200M >"$O2" 2>&1; then
    fail "B: a second grower ran while the first held the claim"
else
    grep -qiE 'being repaired|claimed' "$O2" && pass "B: the second grower refuses while the claim is held" ||
        fail "B: the second grower failed for another reason: $(tail -1 "$O2")"
fi
wait "$p1" && grew "$O1" && pass "B: the holder completed its grow" ||
    fail "B: the holder did not complete: $(tail -1 "$O1")"
[ "$(info layout_gen)" = "$((gen0 + 1))" ] && pass "B: exactly one generation published" ||
    fail "B: layout_gen $gen0 -> $(info layout_gen)"

# ---------------------------------------------- C: a superseded superblock
log "C: the kernel refuses a grow that is not exactly one generation ahead"
gen0="$(info layout_gen)"; sum0="$(sb_sum)"
if CETRAFS_GROWFS_TEST_GEN_SKIP=1 ct_growfs "$DEV" -s 3400M >"$O1" 2>&1; then
    fail "C: the kernel published a superblock two generations ahead"
else
    grep -q 'changed while this grow ran' "$O1" && pass "C: refused as stale (-ESTALE)" ||
        fail "C: refused, but not as stale: $(tail -1 "$O1")"
fi
[ "$(sb_sum)" = "$sum0" ] && [ "$(info layout_gen)" = "$gen0" ] && pass "C: and nothing was published" ||
    fail "C: the refused grow changed the superblock or the layout"
out="$(ct_growfs "$DEV" -s 3400M 2>&1)" && pass "C: control: the same grow without the skip is published" ||
    fail "C: control: the same grow without the skip failed: $(tail -1 <<<"$out")"

# ------------------------------------------------ D: a long live grow
log "D: a live grow that outlasts several heartbeats of the mounted node"
gen0="$(info layout_gen)"
out="$(CETRAFS_TEST_REPAIR_HOLD_SECS=14 ct_growfs "$DEV" -s 4400M 2>&1)" && grep -q 'completed live' <<<"$out" &&
    pass "D: the grow completed with the node beating under its claim" ||
    fail "D: the long live grow did not complete: $(tail -1 <<<"$out")"
[ "$(info layout_gen)" = "$((gen0 + 1))" ] && pass "D: and was published (layout_gen $((gen0 + 1)))" ||
    fail "D: layout_gen $gen0 -> $(info layout_gen)"

# ----------------------------------------------- E: no claim, no publish
log "E: the kernel refuses a grow while no growfs claim is held"
gen0="$(info layout_gen)"; sum0="$(sb_sum)"
if out="$(CETRAFS_GROWFS_TEST_UNCLAIMED=1 ct_growfs "$DEV" -s 5000M 2>&1)"; then
    fail "E: the kernel published a grow with no claim held"
else
    grep -q 'found no growfs claim' <<<"$out" && pass "E: refused for want of a claim (-EBUSY)" ||
        fail "E: refused, but not for the claim: $(grep -iE 'growfs.cetra|nothing|refus' <<<"$out" | head -3 | tr '\n' ' ')"
fi
[ "$(sb_sum)" = "$sum0" ] && [ "$(info layout_gen)" = "$gen0" ] && pass "E: and nothing was published" ||
    fail "E: the unclaimed grow changed the superblock or the layout"

(cd "$MNT" && md5sum -c --quiet "$WORK/digests") && pass "the data reads back intact" || fail "data damaged"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck is clean after the races" ||
    fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
