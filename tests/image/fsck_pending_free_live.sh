#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck refuses a pending-free entry for a block a file still uses, and repair drops the entry
#
# A per-ZG pending-free queue entry is consumed before it is applied, so
# an entry still queued has never been applied -- and when its owner
# drains it, the block is freed whoever references it. fsck counted
# every queued block as "referenced" so that a queue in normal use does
# not read as leaks, and the same line silently accepted a queued block
# that a live file ALSO names: a clean bill of health for a volume whose
# next drain frees live data.
#
# DISCRIMINATION (measured on the unfixed code): fsck exits 0 with the
# root directory's own block queued for free.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
PPOKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 pflive)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

read -r RLBA RLEN < <("$PPOKE" "$DEV" extent 1)
[ -n "${RLBA:-}" ] && [ "${RLEN:-0}" -ge 1 ] && pass "setup: the root directory's block is $RLBA" ||
    { fail "setup: no root directory extent"; ct_exit; }

log "control: a queued block nothing references is a queue in normal use, not a fault"
# A block marked used and referenced by nothing -- what a cross-node
# free looks like until the owner drains it.
FREE_LBA=$((RLBA + 100))
out="$("$PPOKE" "$DEV" add 0 "$FREE_LBA" 1 2>&1)" || { fail "setup: queue append failed: $out"; ct_exit; }
blockdev --flushbufs "$DEV"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if grep -q 'queued for free.*still in use' <<<"$out"; then
    fail "control: a queued block nobody uses was reported as live"
else
    pass "control: an ordinary queued free is not reported as in use (fsck rc=$rc)"
fi

log "the fault: the root directory's own block queued for free"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
"$PPOKE" "$DEV" add 0 "$RLBA" 1 >/dev/null
blockdev --flushbufs "$DEV"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if [ "$rc" != 0 ] && grep -q "block $RLBA is queued for free.*still in use" <<<"$out"; then
    pass "fsck refuses the volume: the queued block is still in use"
else
    fail "fsck rc=$rc did not report the live queued block: $(grep -E '^(ERR|WARN)' <<<"$out" | head -2 | tr '\n' ' ')"
fi

rc=0
out="$(ct_fsck_repair "$DEV" 2>&1)" || rc=$?
log "repair rc=$rc"
q="$("$PPOKE" "$DEV" dump 0 2>&1 || true)"
if grep -q "^$RLBA " <<<"$q"; then
    fail "repair left the entry queued: draining it still frees the root directory's block"
else
    pass "repair dropped the entry"
fi
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "the repaired volume checks clean" ||
    fail "after repair fsck rc=$rc: $(grep -E '^(ERR|WARN)' <<<"$out" | head -2 | tr '\n' ' ')"

ct_exit
