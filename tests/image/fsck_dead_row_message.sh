#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck does not describe a row a peer declared dead as one that left cleanly
#
# A full registry is relieved by retiring a departed row that nothing
# references. The departed rows it considers include ones a peer declared
# DEAD after watching them stop, as well as ones that said goodbye. The
# message named every one of them "departed cleanly" (audit 2026-11-14
# U11): an operator reading it about a crashed node was told the node had
# left in order.
#
# The suite fills a four-row registry with rows declared DEAD and runs
# fsck -r. The row it retires must be described as declared dead, and
# nowhere may the run say "cleanly" about it.
#
# DISCRIMINATION (measured on the unfixed code): the retirement line reads
# "which departed cleanly".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 deadrowmsg)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
# Rows 0..2 were declared dead. Row 3 left cleanly: the only row a repair
# may borrow at once (a DEAD row is watched for a whole stale window
# first), so the claim takes it and the registry-full retirement then
# has departed rows to consider. The borrowed row is not one of them.
for r in 0 1 2 3; do
    "$NPOKE" "$IMG" "$r" 1 bb "$(date +%s)" >/dev/null
done
for r in 0 1 2; do "$NPOKE" "$IMG" "$r" --depart 2 >/dev/null; done
"$NPOKE" "$IMG" 3 --depart 1 >/dev/null
blockdev --flushbufs "$DEV"
grep -q 'departure=2' <<<"$("$NPOKE" "$IMG" 0)" ||
    { fail "setup: row 0 is not a declared-dead row: $("$NPOKE" "$IMG" 0)"; ct_exit; }

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
blockdev --flushbufs "$DEV"
line="$(grep 'retired node slot' <<<"$OUT" | head -1 || true)"
if [ -z "$line" ]; then
    fail "setup: fsck -r retired no row from the full registry: $(grep -E '^ERR|registry' <<<"$OUT" | head -2 | tr '\n' ' ')"
else
    pass "setup: fsck -r retired a declared-dead row from the full registry"
    case "$line" in *"which departed cleanly"*) fail "the retired row was described as departed cleanly: $line" ;;
        *) pass "the retired row is not described as departed cleanly" ;; esac
    case "$line" in *"declared dead"*) pass "and the line says it was declared dead by a peer" ;;
        *) fail "the line does not say how the row departed: $line" ;; esac
fi
ct_exit
