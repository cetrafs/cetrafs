#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# per-mount switches for defragmentation, in procfs
#
# The defragmenter pins the file's cross-node EXCLUSIVE lock while it
# relocates, so a peer is refused any open -- reads included -- for the
# duration. That is accepted for a VM datastore, where one node owns an
# image anyway, but an operator needs to be able to turn it off on a
# volume where it is not: a background optimisation on one node must not
# be allowed to make a file unopenable on another.
#
# Two independent switches, because they answer different questions:
#   auto_defrag  -- the background janitor only; a manual defrag.cetra
#                   run still works
#   defrag       -- defragmentation at all, the ioctl included, so
#                   NOTHING pins the exclusive lock for an optimisation
#
# Per mount rather than per module: one node may own the images on this
# volume while another is only reading them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 dctl)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dctl-mnt)"
ct_mkfs_small "$LOOPDEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="/proc/fs/cetrafs/$(basename "$LOOPDEV")"
CTL="$PROC/controls"

[ -e "$CTL" ] && pass "the controls file exists" || fail "$CTL missing"
[ -w "$CTL" ] && pass "and is writable" || fail "$CTL is not writable"

# Defaults: both on, so behaviour is unchanged unless an operator says so.
grep -q "^auto_defrag: on$"  "$CTL" && pass "auto_defrag defaults to on" ||
    fail "auto_defrag default wrong: $(cat "$CTL")"
grep -q "^defrag: on$" "$CTL" && pass "defrag defaults to on" ||
    fail "defrag default wrong: $(cat "$CTL")"

# A genuinely fragmented file: consecutive blocks, with a filler file
# grown between each pair so the allocator cannot keep the run going.
# It must NOT be sparse -- defrag declines a file with interior holes
# with -EOPNOTSUPP, and a test built on one proves nothing about the
# switches (the first draft of this suite did exactly that).
mkfrag() { # name (relative to $MNT)
    local n="$1" i
    for i in $(seq 0 7); do
        dd if=/dev/urandom of="$MNT/$n" bs=4096 seek="$i" count=1 conv=notrunc status=none
        printf x >"$MNT/filler-$n-$i"
    done
    sync
}
POKE="$(ct_helper inode_block_poke)"
# The extent tree's full SHAPE, not a single number: at depth 1 the
# inode's own eh_entries counts INDEX entries (always 1) and the real
# extent count lives in the external leaf, so reading eh_entries alone
# reports "1" for a badly fragmented file and makes every assertion
# built on it vacuous. The real count comes from defrag.cetra's own
# output, wherever the tool is allowed to run.
# sync + flushbufs before every read: these helpers read the loop device
# directly while the filesystem is mounted, so without it they see the
# device's own cached image and report the state as of some earlier
# moment -- which made the janitor look like it never ran.
_fresh() { sync; blockdev --flushbufs "$LOOPDEV"; }
shape_of() { _fresh; "$POKE" "$LOOPDEV" extents "$(stat -c '%i' "$1")" 2>&1; }
# The number that actually moves when a file is defragmented. A >4-extent
# file is relocated by rewriting its leaf IN PLACE, so depth/eh_entries
# read identically before and after -- a comparison on those cannot see
# the janitor run at all, which is what the opposite control below
# exists to catch.
# A file collapsed to <= 4 extents reverts to depth 0 and has no leaf at
# all, which is what success looks like -- report that as 1 rather than
# as an empty string nothing can compare.
leafcount_of() {
    _fresh
    local out
    out="$("$POKE" "$LOOPDEV" leaf "$(stat -c '%i' "$1")" 2>&1)"
    case "$out" in
        *no\ external\ leaf*) echo 1 ;;
        *) echo "$out" | grep -oP 'leaf_entries=\K[0-9]+' ;;
    esac
}


DEFRAG="$ROOT/userspace/defrag.cetra"

log "defrag: off refuses the ioctl"
echo "defrag=off" >"$CTL"
grep -q "^defrag: off$" "$CTL" && pass "the switch reads back off" ||
    fail "defrag=off did not take: $(cat "$CTL")"
mkfrag f1
BEFORE="$(shape_of "$MNT/f1")"
case "$BEFORE" in
    depth=1*) pass "the probe file really is fragmented ($BEFORE)" ;;
    *) fail "test setup no longer fragments: $BEFORE" ;;
esac
if "$DEFRAG" "$MNT/f1" >/dev/null 2>&1; then
    fail "defrag.cetra succeeded with defrag disabled"
else
    pass "defrag.cetra is refused while defrag is off"
fi
AFTER="$(shape_of "$MNT/f1")"
[ "$BEFORE" = "$AFTER" ] && pass "and the extent tree was not touched" ||
    fail "extent tree changed with defrag off: $BEFORE -> $AFTER"

log "defrag: on allows it again"
echo "defrag=on" >"$CTL"
OUT="$("$DEFRAG" "$MNT/f1" 2>&1)" && pass "defrag.cetra succeeds once re-enabled" ||
    fail "defrag.cetra still refused after re-enabling: $OUT"
N="$(echo "$OUT" | grep -oP 'extents \K[0-9]+' || true)"
[ -n "$N" ] && [ "$N" -ge 5 ] &&
    pass "and it had $N extents to collapse -- the switch was the only thing stopping it" ||
    fail "defrag reported no real work: $OUT"

log "auto_defrag: off leaves the manual path working"
echo "auto_defrag=off" >"$CTL"
grep -q "^auto_defrag: off$" "$CTL" && pass "auto_defrag reads back off" ||
    fail "auto_defrag=off did not take: $(cat "$CTL")"
grep -q "^defrag: on$" "$CTL" && pass "and defrag is independent of it" ||
    fail "auto_defrag=off also turned defrag off"
mkfrag f2
OUT2="$("$DEFRAG" "$MNT/f2" 2>&1)" && pass "a manual defrag still runs with the janitor off" ||
    fail "manual defrag refused with only auto_defrag off: $OUT2"

log "the janitor does not run with auto_defrag off"
# The module-wide param stays ON for both probes, so the PER-MOUNT
# switch is the only variable -- otherwise this section would be
# testing the harness's own default (require_module turns the module
# param off for every suite, because a janitor relocating deliberately
# fragmented files would wreck unrelated tests).
ct_param_set auto_defrag 1
# Both probes are built with the per-mount switch OFF, so neither can be
# relocated during its own construction; the only difference between
# them is that switch's state when each is poked afterwards. A bare
# write-open and close is the trigger (same as defrag_auto.sh).
echo "auto_defrag=off" >"$CTL"
mkfrag f3
mkfrag f4
B3="$(leafcount_of "$MNT/f3")"
B4="$(leafcount_of "$MNT/f4")"
[ -n "$B3" ] && [ "$B3" -ge 5 ] &&
    pass "the janitor's probe file holds $B3 extents, so it would qualify" ||
    fail "janitor probe has only ${B3:-0} leaf extents -- leaving it alone would prove nothing"

: >>"$MNT/f3"
sync; sleep 6
A3="$(leafcount_of "$MNT/f3")"
[ "$B3" = "$A3" ] && pass "and the janitor left it alone ($A3 extents)" ||
    fail "the janitor relocated a file with auto_defrag off: $B3 -> $A3"

log "the janitor DOES run when it is on -- the opposite control"
# Without this, the assertion above passes against a build whose janitor
# never runs at all, which proves nothing about the switch.
echo "auto_defrag=on" >"$CTL"
: >>"$MNT/f4"
A4="$B4"
for _ in $(seq 1 30); do
    A4="$(leafcount_of "$MNT/f4")"
    [ "$A4" = "1" ] && break
    sleep 1
done
[ "$A4" = "1" ] && pass "the same probe is collapsed to 1 extent once the janitor is on ($B4 -> 1)" ||
    fail "the janitor never ran with auto_defrag on: still $A4 extents"

log "cluster timing, settable on a live mount"
# The staleness window is ~60s by default, which is a minute of waiting
# in every scenario that needs a node to time out. These are per MOUNT
# so a test can compress them without reloading the module.
# In-bounds values: the controls file clamps hb_interval_secs to
# [5,30], stale_secs to [15,120], stale >= 3x interval (see
# controls_timing_bounds.sh). hb=5 then stale=15 is the tightest legal
# window and the order keeps the ratio satisfied throughout (stale is 60
# when hb drops to 5, 15 is exactly 3x5 after).
echo "hb_interval_secs=5" >"$CTL"
echo "stale_secs=15" >"$CTL"
grep -q "^hb_interval_secs: 5$" "$CTL" && pass "hb_interval_secs is settable" ||
    fail "hb_interval_secs did not take: $(cat "$CTL")"
grep -q "^stale_secs: 15$" "$CTL" && pass "stale_secs is settable" ||
    fail "stale_secs did not take: $(cat "$CTL")"
# Bounded on both sides: 0 would mean "beat never" / "nothing is ever
# stale", which is not a tuning choice, it is a broken cluster.
echo "stale_secs=0" >"$CTL" 2>/dev/null && fail "accepted stale_secs=0" ||
    pass "zero is refused"
echo "hb_interval_secs=99999" >"$CTL" 2>/dev/null && fail "accepted an absurd interval" ||
    pass "an absurd interval is refused"
grep -q "^stale_secs: 15$" "$CTL" && pass "and the refused values changed nothing" ||
    fail "a refused write altered state: $(cat "$CTL")"

log "bad input is refused rather than half-applied"
echo "defrag=maybe" >"$CTL" 2>/dev/null && fail "accepted a non-boolean value" ||
    pass "a non-boolean value is refused"
echo "nosuchkey=on" >"$CTL" 2>/dev/null && fail "accepted an unknown key" ||
    pass "an unknown key is refused"
grep -q "^defrag: on$" "$CTL" && pass "and the refused writes changed nothing" ||
    fail "a refused write still altered state: $(cat "$CTL")"

ct_umount "$MNT"
ct_fsck "$LOOPDEV"
pass "fsck clean"
ct_exit
