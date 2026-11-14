#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the allocation-bitmap flush visits only the Block Groups it has to write
#
# Every fsync, close, tree edit and namespace swap flushes the
# allocation bitmaps, and the flush tested every Block Group's mark to
# find the few that had bits: O(groups) per call, several per fdatasync
# -- ~0.5 ms of CPU each on a large volume (audit 2026-11-14 P7). It
# now walks the marks word-wise and visits only the marked groups.
#
# A volume of ~128 groups; 20 allocating writes, each fsynced. The
# groups the flushes visit (bmap_flush_visits in info) must stay a few
# per write.
#
# DISCRIMINATION: bmap_flush_scan_all tests every mark, as before: the
# visits then run ~128 per flush.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bmap_flush_scan_all ] || { skip "bmap_flush_scan_all is missing"; ct_exit; }
IMG="$(ct_image 65536 bfv)" # sparse; a Block Group is at least 512 MiB
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bfv)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set bmap_flush_scan_all 0
ct_mount "$DEV" "$MNT"
PD="$(ct_procdir "$DEV")"
visits() { sed -n 's/^bmap_flush_visits: //p' "$PD/info"; }
NBG="$(sed -n 's/^block_groups: //p;s/^block_group_count: //p' "$PD/info" | head -1)"

# -> visits for 20 allocating fsynced writes
run() {
    local v0 v1
    v0="$(visits)"
    python3 - "$MNT/f$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(20):
    os.pwrite(fd, b"v" * 4096, i * 2 * 4096 * 64)
    os.fsync(fd)
os.close(fd)
PY
    v1="$(visits)"
    echo $((v1 - v0))
}
V="$(run 0)"
ct_param_set bmap_flush_scan_all 1
V0="$(run 1)"
ct_param_set bmap_flush_scan_all 0
ct_umount "$MNT"
log "groups ${NBG:-?}; visits for 20 fsynced writes: $V, scanning every group: $V0"
[ "$V0" -ge 2000 ] || fail "setup: scanning every group visited only $V0 -- not the many-group volume, or no flushes"
[ "$V" -le 200 ] && pass "the flushes visited $V groups for 20 writes, not every group each time" ||
    fail "the flushes visited $V groups for 20 writes -- still O(groups) per flush"
[ "$V0" -gt $((V * 10)) ] && pass "control: testing every mark visits $V0 -- the suite discriminates" ||
    fail "control: $V0 vs $V -- the suite cannot tell"
ct_exit
