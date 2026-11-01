#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a hostile extent length must cost fsck one complaint, not one per block
#
# ee_len is 31 bits read off the disk. A directory extent claiming
# 2^31-1 blocks made fsck's namespace walk pread and complain once PER
# BLOCK: 327,409 lines and 19 MB of stderr from a single crafted field,
# and a SIGXFSZ under any write limit -- which is how the release
# fuzzer surfaced it (fuzz_fsck_fields, three findings, all this).
#
# The content pass had already learned the lesson and fixed it in
# fsck_mark_run(); the namespace walk had rolled its own loop over the
# same extents and had not. So what this suite guards is not "fsck
# notices" -- it always did, loudly -- but that the complaint is made
# ONCE, before anything iterates.
#
# The assertion is therefore on the SIZE of the output. That is the
# whole fault: an fsck that reports the same extent correctly 327,409
# times is the bug.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
IPOKE="$(ct_helper inode_block_poke)"
OPOKE="$(ct_helper orphan_poke)"

IMG="$(ct_image 560 hostlen)"
DEV="$(ct_loop "$IMG")"

ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 ||
    fail "the freshly-made control image is already reported corrupt"
pass "setup: the control volume is clean before the field is poked"

# An allocated inode nothing names. It is what the LAST assertion
# measures, and without it that assertion passes over an empty set: a
# freshly-made volume has only the root, so "fsck still reports what it
# could not reach" was green because there was nothing to reach.
"$OPOKE" "$IMG" 2 1 0 >/dev/null 2>&1 ||
    fail "setup: orphan_poke could not plant an unreferenced inode"

# Inode 1 is the root directory, and extlen restamps the record's
# checksum -- so the length is the only thing wrong with it and the CRC
# cannot be what catches this.
"$IPOKE" "$IMG" extlen 1 0x7fffffff 2>&1 | grep -q "extent0 len" ||
    fail "setup: inode_block_poke did not report setting the length"
blockdev --flushbufs "$DEV"

# A write limit the old fsck blew through: 19 MB of stderr against a
# 4 MiB ceiling is SIGXFSZ (exit 128+25 = 153). The limit is applied to
# a subshell so the harness keeps its own.
OUT="$(ct_tmp fsck-out)"
rc=0
( ulimit -f 4096; timeout 120 "$ROOT/userspace/fsck.cetra" "$DEV" >"$OUT" 2>&1 ) || rc=$?

# Each check emits exactly ONE verdict. fail() does not abort, so a
# bare `check || fail` followed by pass() prints both for the same
# condition -- which is how a red run reads as 6 passed, 3 failed and
# the reader has to work out which half is true.
if [ "$rc" = 124 ]; then
    fail "fsck did not finish in 120s on one crafted extent (the unbounded walk)"
elif [ "$rc" -ge 128 ]; then
    fail "fsck died on signal $((rc - 128)) (25 = SIGXFSZ: it wrote past the limit, which is the bug)"
else
    pass "fsck finished without being killed (exit $rc)"
fi

if [ "$rc" = 0 ]; then
    fail "fsck called the volume CLEAN with a 2^31-block extent in the root directory"
else
    pass "fsck reported the volume as faulty"
fi

LINES="$(wc -l <"$OUT")"
BYTES="$(wc -c <"$OUT")"
# Generous by two orders of magnitude against the 327,409 lines the
# unfixed walk produced, and still far below anything a per-block loop
# can reach: this discriminates without being brittle about how many
# other things fsck legitimately notices on a poked image.
if [ "$LINES" -gt 200 ]; then
    fail "fsck wrote $LINES lines ($BYTES bytes) about one extent -- it is complaining per block"
else
    pass "the complaint is bounded: $LINES lines, $BYTES bytes"
fi

if grep -qE "extent \[[0-9]+,\+2147483647\) is outside every data region" "$OUT"; then
    pass "fsck named the extent and its absurd length"
else
    fail "fsck did not name the hostile extent: $(head -3 "$OUT" | tr '\n' ' ')"
fi

# The other direction, and the reason the bound above is not the whole
# test: a walk that simply stopped looking at directories would also be
# quiet, and would pass every assertion above. The planted orphan must
# still be named.
if grep -qE "NO directory entry names it|unreachable" "$OUT"; then
    pass "the planted orphan is still reported, so the namespace pass did not simply stop"
else
    fail "fsck went quiet about the inode nothing names -- the walk stopped rather than skipping one extent"
fi

ct_exit
