#!/usr/bin/env bash
# mkfs.cetra -s formats part of a device and the result is a correct, self-consistent volume
#
# -s exists so the grow path can be tested without asking a storage
# array to resize a LUN, but it is a real option an operator can use to
# format a volume smaller than its LUN on purpose. Every other suite
# exercises it only as a step on the way to a grow, which means a volume
# that is formatted undersize and then simply USED -- never grown -- has
# no coverage at all. That is the case an operator hits first.
#
# Image-level: no module, nothing mounted. What is checked is that the
# superblock -s produces describes the size it was asked for, stays
# inside the device, and is accepted by fsck -- and that the bytes past
# the end of the filesystem are genuinely untouched, which is what makes
# a later grow safe.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
CT_NEED_MODULE=0
require_root

DEV="$(ct_big_dev 1400 mkfspartial)"
POKE="$(ct_helper sb_poke)"
DUMP="$(ct_tmp mkfspartialdump)"

# Stamp a recognisable pattern over the region that will lie PAST the
# end of the filesystem, so "the tail is untouched" is a claim about
# observed bytes and not about a sparse file nobody ever wrote to.
# Only the checked region is stamped: writing all 1400 MiB would
# materialise the whole image for no extra coverage.
dd if=/dev/zero bs=1M count=64 2>/dev/null | tr '\0' '\272' |
    dd of="$DEV" bs=1M seek=680 status=none 2>/dev/null || true

log "formatting 600 MiB of a 1400 MiB device"
if out="$(ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 2048 -f 2>&1)"; then
    pass "mkfs -s succeeded"
else
    fail "mkfs -s failed: $out"
    ct_exit
fi

grep -q 'note: formatting 629145600 of 1468006400 bytes' <<<"$out" &&
    pass "mkfs announces the undersize loudly" ||
    fail "mkfs did not announce that it was formatting part of the device: $out"
# On failure, print what mkfs ACTUALLY said. This assertion failed once
# inside a full `make check` and could not be reproduced afterwards --
# 0 of 20 standalone runs and clean through the image group -- so the
# next occurrence needs to carry its own evidence rather than leaving
# somebody to guess from the assertion name.
if grep -q 'filesystem bytes: 629145600' <<<"$out"; then
    pass "mkfs reports the filesystem size separately from the device size"
else
    fail "mkfs did not report the filesystem size. Full output was: $(printf '%s' "$out" | tr '\n' '|')"
fi

ct_fsck "$DEV" >/dev/null 2>&1 && pass "an undersized volume is clean" ||
    fail "an undersized volume does not pass fsck"

# sb_poke with no field dumps every one of them.
"$POKE" "$DEV" > "$DUMP" 2>/dev/null || true
sbval() { sed -n "s/^$1=//p" "$DUMP" | head -1; }

v="$(sbval version)"
[ "$v" = "9" ] && pass "mkfs stamps the current format version (9)" ||
    fail "mkfs stamped format version '$v', expected 9"

tb="$(sbval total_blocks)"
[ "$tb" = "153600" ] && pass "superblock total_blocks is the -s size, not the device size ($tb)" ||
    fail "superblock total_blocks is '$tb', expected 153600"

for f in layout_gen tail_reserve_start tail_reserve_blocks orphan_blocks bg_data_end; do
    v="$(sbval "$f")"
    case "$v" in
        0) pass "$f is zero on a never-grown volume" ;;
        "") fail "sb_poke does not report $f -- the never-grown assertion is vacuous" ;;
        *) fail "$f is $v on a volume that has never been grown" ;;
    esac
done

# The bytes past the filesystem must still be the pattern: a grow writes
# Block Group headers there and trusts that nothing it did not put there
# is being relied on, and mkfs must not have scribbled past its own end.
log "checking that the space past the filesystem is untouched"
# Exactly 16 bytes read, so nothing in the pipeline gets SIGPIPEd and
# killed under `set -o pipefail` -- an earlier version used `od -N16`
# against a 1 MiB dd and aborted the suite instead of asserting.
tail_byte="$(dd if="$DEV" bs=1 skip=$((700 * 1024 * 1024)) count=16 status=none 2>/dev/null |
    od -An -tx1 | tr -d ' \n')"
[ "$tail_byte" = "babababababababababababababababa" ] &&
    pass "bytes past the end of the filesystem are untouched" ||
    fail "mkfs wrote past the end of the filesystem it was asked for: '$tail_byte'"

# And the refusals.
if ct_mkfs "$DEV" -s 99999G -f >/dev/null 2>&1; then
    fail "mkfs -s accepted a size larger than the device"
else
    pass "mkfs -s refuses a size larger than the device"
fi
if ct_mkfs "$DEV" -s 1M -f >/dev/null 2>&1; then
    fail "mkfs -s accepted a size too small to hold a filesystem"
else
    pass "mkfs -s refuses a size too small to hold a filesystem"
fi
if ct_mkfs "$DEV" -s 600Q -f >/dev/null 2>&1; then
    fail "mkfs -s accepted a bogus suffix"
else
    pass "mkfs -s refuses a bogus suffix"
fi
if ct_mkfs "$DEV" -s 600001 -f >/dev/null 2>&1; then
    fail "mkfs -s accepted a size that is not a multiple of the block size"
else
    pass "mkfs -s refuses a size that is not a multiple of 4KiB"
fi

ct_exit
