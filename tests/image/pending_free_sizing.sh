#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# mkfs sizes the per-ZG pending-free queue, and every reader takes the
# size from the superblock.
#
# The queue holds one entry per freed EXTENT. A node deleting a large VM
# image produces tens of thousands at once, and anything past the end of
# the queue is dropped and leaked until the owner's scrub reclaims it.
# So the target is large (CETRAFS_PENDING_FREE_BLOCKS_PER_ZG). But the
# reservation is dead space on a small volume that will never fill it,
# so mkfs caps the whole pending area at CETRAFS_PENDING_FREE_MAX_PERCENT
# and shrinks the per-ZG size to fit, never below
# CETRAFS_PENDING_FREE_BLOCKS_MIN.
#
# Both halves are asserted: a regression that drops the cap wastes
# space on small volumes, and one that drops the target silently brings
# back the overflow this sizing exists to prevent.
# set -euo pipefail, and the BASH_SOURCE form, like every other suite.
# Without -e a failed mkfs or mount here was ignored and the assertions
# below ran against nothing -- the vacuous pass tests/README.md exists
# to prevent.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
suite "pending-free queue sizing"

TARGET="$(grep -oP '#define CETRAFS_PENDING_FREE_BLOCKS_PER_ZG\s+\K[0-9]+' "$ROOT/include/cetrafs.h")"
log "target=$TARGET blocks/ZG = $((TARGET * 256)) queued extents per Zone Group"

SBP="$(ct_helper sb_poke)"

field() { "$SBP" "$1" | grep -oP "$2=\K[0-9]+"; }

# Sets PER/ZGS/PCT_USED. NOT a command substitution: fail() inside
# $(...) runs in a subshell, so its failures never reach the suite's
# counters and the assertions would be decorative.
PER=""; ZGS=""; PCT_USED=""
measure() { # <MiB> <label> [mkfs args...]
    local mb="$1" label="$2"; shift 2
    local img loop total
    img="$(ct_image "$mb" pfsize)"
    loop="$(ct_loop "$img")"
    ct_mkfs "$loop" -f "$@" >/dev/null
    ZGS="$(field "$img" zone_group_count)"
    PER="$(field "$img" pending_free_blocks_per_zg)"
    total="$(field "$img" total_blocks)"
    if [ -z "$ZGS" ] || [ -z "$PER" ] || [ -z "$total" ]; then
        fail "$label: could not read the superblock back"
        PER=""; return
    fi
    PCT_USED=$(( 100 * ZGS * PER / total ))
    log "$label: zgs=$ZGS per_zg=$PER -> ${PCT_USED}% of the volume"
}

# Every geometry gets the full queue -- see the header for why no cap
# is applied -- and the reservation stays a negligible share of the
# volume. Both sizes are checked because the share is worst on the
# smallest volume mkfs will build.
for CASE in "8192 8 GiB" "1200 1.2 GiB"; do
    set -- $CASE
    measure "$1" "$2 $3"
    [ -n "$PER" ] || continue
    [ "$PER" = "$TARGET" ] &&
        pass "$2 $3: full queue ($PER blocks/ZG = $((PER * 256)) entries)" ||
        fail "$2 $3: per_zg=$PER, not the target $TARGET"
    [ "$PCT_USED" -le 1 ] &&
        pass "$2 $3: the queues cost ${PCT_USED}% of the volume" ||
        fail "$2 $3: the queues cost ${PCT_USED}% of the volume -- more than expected"
done

# The kernel must use what the superblock says, not the constant it was
# compiled with -- that is the whole point of storing it.
grep -q "pending_free_blocks_per_zg" "$ROOT/kmod/zonegroup.c" &&
    pass "the kernel reads the queue size from the superblock" ||
    fail "the kernel does not read pending_free_blocks_per_zg from the superblock"

ct_exit
