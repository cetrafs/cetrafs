#!/usr/bin/env bash
# the Block Group table is a chain: the first segment never moves, and a broken chain is detected
#
# STAGE 5 of docs/internal/BG-OWNERSHIP-DESIGN.md, and the last thing
# standing between here and a grow that can run while nodes are mounted.
#
# Growing used to RELOCATE the Block Group table, which is the one
# thing a running peer cannot tolerate: every mounted node caches
# bg_table_start and reads it on the allocation path with no lock, so a
# peer that has not noticed keeps compare-and-swapping descriptors at
# superseded blocks. A chain only ever gets longer and existing links
# never change, so a node that has not re-walked it still resolves
# every Block Group it knows about to the right place -- it simply has
# not reached the new ones. Out of date means "I know about less",
# which is the harmless direction.
#
# What a chain brings that a contiguous array does not is a set of
# failure modes with no analogue: a loop, a segment that is not one, a
# link into data, a link left dangling by a crash. Each is injected
# here, because "fsck detects a broken chain" is otherwise an assertion
# nobody has measured -- and walking off the end of a bad chain is how
# a checker turns into a crash.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

SEG="$(ct_helper seg_poke)"
DEV="$(ct_big_dev 3000 bgchain)"
MNT="$(ct_mnt bgchain)"

sb_u64() { python3 -c "import struct,sys;d=open(sys.argv[1],'rb').read(4096);print(struct.unpack_from('<Q',d,int(sys.argv[2]))[0])" "$DEV" "$1"; }
BG_TABLE_START_OFF=40
BG_TABLE_NEXT_OFF=264
BG_COUNT_OFF=28

fresh() { ct_mkfs "$DEV" -s 700M -b 512 -z 2 -J 0 -N 1024 -f >/dev/null; }

# ------------------------------------------- the first segment never moves
log "the first segment stays put across three grows"
fresh
first_at="$(sb_u64 $BG_TABLE_START_OFF)"
moved=0
for tgt in 1400M 2100M 2800M; do
    ct_growfs "$DEV" -s "$tgt" >/dev/null 2>&1 || { fail "grow to $tgt failed"; break; }
    now="$(sb_u64 $BG_TABLE_START_OFF)"
    [ "$now" = "$first_at" ] || moved=1
    ct_fsck "$DEV" >/dev/null 2>&1 || fail "not clean after growing to $tgt"
done
[ "$moved" = "0" ] &&
    pass "bg_table_start stayed at block $first_at through every grow" ||
    fail "the Block Group table moved -- a mounted peer would be reading superseded blocks"

bgs="$(python3 -c "import struct;d=open('$DEV','rb').read(4096);print(struct.unpack_from('<I',d,$BG_COUNT_OFF)[0])")"
[ "$bgs" -gt 2 ] && pass "the chain describes $bgs Block Groups" || fail "only $bgs Block Groups after three grows"

head="$(sb_u64 $BG_TABLE_NEXT_OFF)"
[ "$head" != "0" ] && pass "a chain head is recorded ($head)" || fail "no chain head after growing"

# The volume must still be a working filesystem through all of it.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/after" bs=1M count=32 status=none && pass "the grown volume accepts writes" ||
    fail "the grown volume will not take a write"
sync
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "clean after writing into it" || fail "not clean after writing"

# -------------------------------------------------- a broken chain is caught
check_caught() { # <label> <expected-substring>
    local out
    out="$(ct_fsck "$DEV" 2>&1 || true)"
    if grep -q ERR <<<"$out"; then
        if grep -q "$2" <<<"$out"; then
            pass "$1 is detected, and named: $(printf '%s' "$out" | grep -m1 ERR | cut -c1-70)"
        else
            pass "$1 is detected (different message: $(printf '%s' "$out" | grep -m1 ERR | cut -c1-60))"
        fi
    else
        fail "$1 was NOT detected -- fsck called the volume clean"
    fi
}

log "injecting the failure modes a chain has and an array does not"

fresh; ct_growfs "$DEV" -s 1400M >/dev/null 2>&1; ct_growfs "$DEV" -s 2100M >/dev/null 2>&1
"$SEG" "$DEV" loop >/dev/null
check_caught "a chain that loops back on itself" "does not terminate"

fresh; ct_growfs "$DEV" -s 1400M >/dev/null 2>&1
"$SEG" "$DEV" magic >/dev/null
check_caught "a segment with no magic" "no magic"

fresh; ct_growfs "$DEV" -s 1400M >/dev/null 2>&1
"$SEG" "$DEV" crc >/dev/null
check_caught "a segment that fails its checksum" "checksum"

fresh; ct_growfs "$DEV" -s 1400M >/dev/null 2>&1
"$SEG" "$DEV" dangle 999999999 >/dev/null
check_caught "a link past the end of the volume" "past the end"

fresh; ct_growfs "$DEV" -s 1400M >/dev/null 2>&1
"$SEG" "$DEV" dangle 2 >/dev/null
check_caught "a link into the middle of the metadata" ""

fresh; ct_growfs "$DEV" -s 1400M >/dev/null 2>&1
"$SEG" "$DEV" firstid 99 >/dev/null
check_caught "a segment lying about which id it starts at" "expected"

# ------------------------------- an UNLINKED segment is not damage
#
# A crash between writing a segment and linking it leaves the segment
# unreferenced. Nothing points at it, so it is invisible and harmless --
# the same safe direction as a half-grown volume, and fsck must say so
# rather than calling the volume broken.
log "a segment written but never linked is harmless, not damage"
fresh
CETRAFS_GROWFS_TEST_NO_PUBLISH=1 ct_growfs "$DEV" -s 1400M >/dev/null 2>&1 || true
if ct_fsck "$DEV" >/dev/null 2>&1; then
    pass "an unlinked segment reads clean at the old size"
else
    fail "an unlinked segment was reported as damage: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"
fi
ct_mount "$DEV" "$MNT" 2>/dev/null && { pass "and the volume still mounts"; ct_umount "$MNT"; } ||
    fail "an unlinked segment stopped the volume mounting"

ct_exit
