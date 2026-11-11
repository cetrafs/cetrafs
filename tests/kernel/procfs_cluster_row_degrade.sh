#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# one registry row whose staleness cannot be judged does not cost the cluster file every other row
#
# procfs cluster prints a line per registry row and promises to degrade
# per row: an unreadable row is printed as such and the rest follow. A
# row that read fine but whose staleness check then failed returned the
# error for the WHOLE file instead -- rows after it, and the grow-gate
# line, gone (audit 2026-11-11 P2).
#
#  1. the staleness check of row 1 fails: the file still reads, row 1
#     says stale=unknown, row 0 and the trailing line are there.
#  2. CONTROL: with the check working, row 1 says stale=yes.
#
# DISCRIMINATION (2026-11-11, the early return back): 1's read fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/cluster_stale_fail_row ] || { skip "cluster_stale_fail_row is missing"; ct_exit; }

IMG="$(ct_image 560 clrow)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt clrow)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# A second row after ours: a dead peer, planted under the mount.
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
CL="$(ct_procdir "$DEV")/cluster"
grep -q "^node 1:" "$CL" || { fail "setup: row 1 is not in the cluster file: $(cat "$CL")"; ct_exit; }

log "2: CONTROL -- the staleness check working"
sleep 4 # past the compressed window
grep -q "^node 1: .*stale=yes" "$CL" && pass "2: row 1 reads stale=yes" || fail "2: row 1: $(grep '^node 1:' "$CL")"

log "1: row 1's staleness check fails"
ct_param_set cluster_stale_fail_row 2
OUT="$(cat "$CL" 2>&1)" && R=0 || R=$?
ct_param_set cluster_stale_fail_row 0
[ "$R" = 0 ] && pass "1: the file still reads" || fail "1: reading the cluster file failed ($R): $OUT"
grep -q "^node 1: .*stale=unknown" <<<"$OUT" && pass "1: row 1 says stale=unknown" || fail "1: row 1: $(grep '^node 1:' <<<"$OUT")"
grep -q "^node 0: .*(this node)" <<<"$OUT" && grep -q "^live_grow_ready:" <<<"$OUT" &&
    pass "1: and the rows around it and the trailing line are all there" || fail "1: lines missing: $OUT"
ct_umount "$MNT"
ct_exit
