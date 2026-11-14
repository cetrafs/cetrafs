#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an ENOSPC with no release in flight scans the tables once, not twice
#
# Out of space, the allocator tries to claim a Zone Group, then a free
# Block Group, then waits for any surplus release and -- always -- tried
# both claims again: a second read of every Zone Group record and Block
# Group descriptor, under the writer's locks, for an answer it already
# had (audit 2026-11-14 A4). It now looks again only if a release ended
# since the allocation began; release_drain_no_enospc.sh covers the case
# where one did.
#
# A volume filled to ENOSPC, then 20 more writes that must fail:
#   1. each fails with ENOSPC;
#   2. none of them rescanned (enospc_rescans unchanged).
#
# DISCRIMINATION: enospc_always_rescan, the old behaviour: one rescan
# per failed allocation.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/enospc_always_rescan ] || { skip "enospc_always_rescan is missing"; ct_exit; }
DEV="$(ct_dev 560 enoone)"
MNT="$(ct_mnt enoone)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set enospc_always_rescan 0
ct_param_set scrub 0
INFO="$(ct_procdir "$DEV")/info"
P=/sys/module/cetrafs/parameters

dd if=/dev/zero of="$MNT/fill" bs=1M status=none 2>/dev/null || true
sync
[ "$(stat -f -c %a "$MNT")" -lt 64 ] || { fail "setup: the volume did not fill ($(stat -f -c %a "$MNT") blocks left)"; ct_exit; }

# <always 0|1> -> "<ENOSPC failures of 20> <rescans>"
probe() {
    local r0 r1 n=0 i
    echo "$1" >$P/enospc_always_rescan
    r0="$(sed -n 's/^enospc_rescans: //p' "$INFO")"
    for i in $(seq 20); do
        rc=0
        python3 -c '
import errno, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
try:
    os.pwrite(fd, b"x" * (1 << 20), 0); os.fsync(fd)
except OSError as e:
    sys.exit(0 if e.errno == errno.ENOSPC else 1)
sys.exit(2)' "$MNT/more$1-$i" || rc=$?
        [ "$rc" = 0 ] && n=$((n + 1))
        rm -f "$MNT/more$1-$i"
    done
    r1="$(sed -n 's/^enospc_rescans: //p' "$INFO")"
    echo 0 >$P/enospc_always_rescan
    echo "$n $((r1 - r0))"
}

read -r N R <<<"$(probe 0)"
log "fixed: $N of 20 writes failed ENOSPC, $R rescans"
[ "$N" = 20 ] && pass "1: all 20 writes failed with ENOSPC" || fail "1: $N of 20 failed with ENOSPC"
[ "$R" = 0 ] && pass "2: no release ran, and none of them scanned the tables a second time" ||
    fail "2: $R second scans with no release in flight"
read -r N0 R0 <<<"$(probe 1)"
[ "$N0" = 20 ] && [ "$R0" -ge 20 ] &&
    pass "control: always rescanning, the same 20 failures scanned again $R0 times -- the suite discriminates" ||
    fail "control: $N0 ENOSPC, $R0 rescans -- the suite cannot tell"
ct_umount "$MNT"
ct_exit
