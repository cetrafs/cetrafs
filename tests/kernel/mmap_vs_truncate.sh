#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a fault racing a shrinking truncate: no stale data, no lost bytes, fsck clean
#
# A shrink publishes the new size, then frees the dropped blocks after a
# window (truncate_free_stall_ms widens it). Two mappers store through a
# MAP_SHARED mapping over the whole file while a third process shrinks
# and regrows it. A store past the new end must SIGBUS without allocating;
# a store into a regrown hole must allocate a block the truncate did not
# free. The helper (mmap_trunc_race) checks the content afterwards: pages
# below the kept size hold the stored value (no lost bytes), pages above
# hold a hole or a stored value and never the original pattern (a dropped
# block that came back is stale data), and the size is the last grow.
# The helper exits 2 when no store ever hit the shrunk window: the race
# was not arranged, so the run tests nothing and says so.
#
# No negative control. The fault path takes invalidate_lock (rule 18),
# which the truncate holds from publish through the frees; no test knob
# removes that lock, and truncate_free_stall_ms only widens the window
# (a pass here shows the serialisation holds, not that the oracle would
# catch its absence). The oracle is a model check against that lock.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/truncate_free_stall_ms ] || { skip "truncate_free_stall_ms is missing"; ct_exit; }

RACE="$(ct_helper mmap_trunc_race)"
IMG="$(ct_image 560 mmtrunc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmtrunc)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set truncate_free_stall_ms 3
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# keep/pages pairs: a shrink to a quarter, and to three quarters.
for cfg in "40 64 16" "40 64 48"; do
    set -- $cfg
    rounds=$1 pages=$2 keep=$3
    rm -f "$MNT/race"
    OUT="$(timeout 240 "$RACE" "$MNT/race" "$rounds" "$pages" "$keep" 2>&1)" && RC=0 || RC=$?
    log "race rounds=$rounds pages=$pages keep=$keep: $OUT (rc=$RC)"
    case "$RC" in
        0) pass "race (keep=$keep of $pages, $rounds shrinks): no lost bytes, no stale page, size is the last grow ($OUT)" ;;
        2) fail "setup: no store reached the shrunk window -- the race was not arranged ($OUT)" ;;
        *) fail "race (keep=$keep of $pages): content oracle failed, rc=$RC ($OUT)" ;;
    esac
done

ct_param_set truncate_free_stall_ms 0
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -qE '^ERR' <<<"$OUT"; then fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"; else pass "fsck clean"; fi
ct_exit
