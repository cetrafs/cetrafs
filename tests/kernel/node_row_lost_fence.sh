#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node whose registry row is no longer its own fences itself instead of carrying on
#
# The heartbeat renews this node's row by compare-and-swap. If the row
# has stopped being ours -- freed, taken by an offline repairer that
# judged us dead, or registered into by another machine -- the swap's
# mutator refused with -EINVAL, which the tick logged as "failed to
# renew" and then went on to claim Zone Groups, drain queues and replay
# journals as a node no peer believes exists. Losing the row is a
# revoked lease by another route, and gets the same answer: fence.
#
# The tick's read-only pre-check already notices a lost row; the renew
# is the authoritative test, because a row can be taken between the
# two. fence_skip_precheck takes the pre-check out so the renew is the
# SOLE path to the fence (same approach as fence_lease.sh).
#
# DISCRIMINATION (measured on the unfixed code): the tick logs "failed
# to renew our own row: -22" every beat and writes keep succeeding.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

run_case() { # <label> <state> <uuid byte>
    local label="$1" state="$2" ub="$3" dev mnt mark
    dev="$(ct_dev 560 rowlost)"
    mnt="$(ct_mnt rowlost)"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    echo before >"$mnt/f"
    sync
    mark="$(dmesg_mark)"
    "$NODE_POKE" "$dev" 0 "$state" "$ub" "$(date +%s)" >/dev/null
    if wait_for 20 'dmesg_since "'"$mark"'" | grep -q "row is no longer ours"' 2>/dev/null; then
        pass "$label: the node fenced itself"
    else
        fail "$label: no fence -- the tick says: $(dmesg_since "$mark" | grep -E 'heartbeat|fence' | tail -1)"
    fi
    if (echo after >"$mnt/g" && sync -f "$mnt/g") 2>/dev/null; then
        fail "$label: a write still succeeded on a node whose row is gone"
    else
        pass "$label: writes are refused"
    fi
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
}

compress_timing
ct_param_set fence_skip_precheck 1
run_case "row freed" 0 00
run_case "row registered to another machine" 1 ee
ct_param_set fence_skip_precheck 0
ct_exit
