#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the inline pending-free drain probes the queues in one batch
#
# A write that allocates runs the pending-free drain twice a second, and
# the drain first asks each owned Zone Group's queue whether anything is
# in it: two serial forced-fresh reads per Zone Group, charged to the
# write while it holds inode_lock and invalidate_lock (audit 2026-11-14
# A5). The heads of every owned queue are now read as one batch.
#
# pf_drain_min_ms 0 drains on every allocation; 50 allocating writes,
# each fsynced; the loop device's completed reads are counted.
#
# DISCRIMINATION: pf_probe_serial probes each queue with its own reads,
# as before -- at least one more request per drain.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pf_probe_serial ] || { skip "pf_probe_serial is missing"; ct_exit; }
DEV="$(ct_loop "$(ct_image 560 ppb)")"
MNT="$(ct_mnt ppb)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set pf_probe_serial 0
ct_param_set auto_defrag 0
ct_param_set alloc_run_blocks 0 # every block through the pick, where the drain runs
ct_mount "$DEV" "$MNT"
PD="$(ct_procdir "$DEV")"
reads() { awk '{print $1}' "/sys/block/$(basename "$DEV")/stat"; }
drains() { sed -n 's/^pf_drains: //p' "$PD/info"; }
run() {
    local r0 d0
    r0="$(reads)"; d0="$(drains)"
    python3 - "$MNT/f$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(50):
    os.pwrite(fd, b"p" * 4096, i * 8 * 4096)
    os.fsync(fd)
os.close(fd)
PY
    echo "$(($(reads) - r0)) $(($(drains) - d0))"
}
ct_param_set pf_drain_min_ms 0
read -r R D <<<"$(run 0)"
ct_param_set pf_probe_serial 1
read -r R0 D0 <<<"$(run 1)"
ct_param_set pf_probe_serial 0
ct_param_set pf_drain_min_ms 500
ct_umount "$MNT"
log "batched: $R reads over $D drains; serial: $R0 reads over $D0 drains"
[ "$D" -ge 40 ] && [ "$D0" -ge 40 ] || fail "setup: only $D / $D0 drains ran -- the probe was not exercised"
[ $((R0 - R)) -ge $((D / 2)) ] && pass "the batched probe saves $((R0 - R)) read requests over $D drains" ||
    fail "batched $R against serial $R0 over $D drains -- the probe is not batched"
ct_exit
