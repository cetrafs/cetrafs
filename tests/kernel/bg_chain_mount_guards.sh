#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the MOUNT must refuse a hostile Block Group table chain, not just fsck
#
# bg_table_chain.sh already injects a loop, a bad magic, a corrupt
# checksum and a dangling next -- and asserts that FSCK reports each
# one. Nobody ever asked the other half of the question, so nobody
# noticed that fill_super() checked only the magic:
#
#   - the segment header carries a CRC32C that growfs stamps and fsck
#     verifies, and the mount path never looked at it. A volume whose
#     segment checksum was destroyed MOUNTED CLEAN (measured).
#   - the descriptor count came off the device straight into a loop
#     with no bound. 2^32-1 walked four billion iterations before the
#     final tally refused it: 2264ms against 16ms for a healthy chain,
#     and a count that wraps the u32 cursor onto the recorded Block
#     Group total passes every test there is.
#   - neither the segment LBAs nor the chain's next were range-checked
#     against the device.
#
# This exists because the chain is the ONE structure a fuzzer could not
# reach: it only appears on a volume that has been GROWN, and every
# golden image was freshly made, so fs.c's walk never executed a single
# iteration under fuzzing. mkgolden.sh grows the golden now, fuzz.py
# knows the structure, and seg_poke learned to set the count -- without
# which this suite could not be written at all.
#
# Discrimination: each assertion below was measured against the code
# before the guards. The checksum one MOUNTED; the count one took 2264ms
# to be refused by a different check entirely.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SEG="$(ct_helper seg_poke)"

IMG="$(ct_image 1300 bgchainmnt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgchainmnt)"

# A volume with a real chain: mkfs small, then grow into the rest.
ct_mkfs "$DEV" -s 600M -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_growfs "$DEV" >/dev/null 2>&1 || fail "the grow that creates the chain failed"
ct_track mnt "$MNT"

HEAD="$("$SEG" "$DEV" dump | sed -n 's/.*head=\([0-9]*\).*/\1/p')"
[ -n "$HEAD" ] && [ "$HEAD" != "0" ] ||
    fail "no chain head after the grow -- there is no chain to make hostile"

mount_ms() {   # echoes "<verdict> <milliseconds>"
    local t0 t1 v
    t0=$(date +%s%N)
    if timeout 120 mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        v=mounted; umount "$MNT"
    else
        v=refused
    fi
    t1=$(date +%s%N)
    echo "$v $(( (t1 - t0) / 1000000 ))"
}

read -r V HEALTHY_MS <<<"$(mount_ms)"
[ "$V" = mounted ] &&
    pass "control: the healthy grown volume mounts (${HEALTHY_MS}ms)" ||
    fail "the healthy grown volume will not mount -- nothing below would mean anything"

"$SEG" "$DEV" crc >/dev/null
read -r V MS <<<"$(mount_ms)"
[ "$V" = refused ] &&
    pass "a segment whose checksum does not verify is refused (${MS}ms)" ||
    fail "the volume MOUNTED with a corrupt segment checksum -- growfs stamps it and fsck checks it, and the mount ignored it"

# Rebuild the chain, then make the count hostile.
ct_growfs "$DEV" >/dev/null 2>&1 || true
"$SEG" "$DEV" count 4294967295 >/dev/null
read -r V MS <<<"$(mount_ms)"
[ "$V" = refused ] &&
    pass "a segment claiming 2^32-1 descriptors is refused (${MS}ms)" ||
    fail "a segment claiming 2^32-1 descriptors was accepted"

# And refused PROMPTLY: the old code reached the same verdict only after
# walking the count, which is the denial-of-service half of the fault.
[ "$MS" -lt $(( HEALTHY_MS + 500 )) ] &&
    pass "and refused without walking it (${MS}ms vs ${HEALTHY_MS}ms healthy)" ||
    fail "refused only after ${MS}ms against ${HEALTHY_MS}ms for a healthy chain -- the count was walked"

ct_growfs "$DEV" >/dev/null 2>&1 || true
"$SEG" "$DEV" dangle 999999999 >/dev/null
read -r V MS <<<"$(mount_ms)"
[ "$V" = refused ] &&
    pass "a chain linking past the end of the device is refused (${MS}ms)" ||
    fail "a chain linking to block 999999999 was followed"

ct_exit
