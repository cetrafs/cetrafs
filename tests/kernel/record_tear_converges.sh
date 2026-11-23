#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a checksummed record read torn for milliseconds converges instead of reading as corrupt
#
# The inode record, node row, ZG record and BG descriptor readers retry
# a checksum mismatch -- "a peer's in-flight write, which takes
# milliseconds" -- but slept a fixed 100-400 us between five attempts,
# so the whole budget was about a millisecond and a tear lasting longer
# was declared corruption: the volume marked damaged, writes refused
# (review E2). They now back off like the block readers (X1,
# cetrafs_tear_backoff()). Every record read tears for 60 ms
# (record_tear_ms) while one operation that reads each kind runs.
#
# 60 ms, not 8: the backoff alone still gave up after five attempts --
# 1+2+4+8 = 15 ms -- where a block reader waits 255 ms for the same
# kind of in-flight write, and a sync write on an array is tens of ms
# (audit 2026-11-22 N-65). One budget now, CETRAFS_RECORD_READ_RETRIES.
#
# DISCRIMINATION (2026-11-11, the four readers before E2): every case
# reports "corrupted, not just a torn concurrent read". Again
# (2026-11-23) with the record readers back on five attempts: all four
# declare a 60 ms tear corruption.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/record_tear_ms ] || { skip "record_tear_ms is missing"; ct_exit; }

DEV="$(ct_dev 560 rectear)"
MNT="$(ct_mnt rectear)"
TEAR_MS=60
# torn <case> <kind...> -- <python statement>: arm an 8 ms tear from
# inside the process, right before the call (interpreter start-up alone
# outlasts the window), then require the call to succeed, each named
# reader to have been torn, and nothing declared corrupt.
torn() {
    local c="$1" mark rc=0 k
    shift
    local kinds=()
    while [ "$1" != -- ]; do kinds+=("$1"); shift; done
    shift
    # A fresh volume per case: a tear declared corruption in one case
    # must not stop the next from reaching its reader.
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    PROC="$(ct_procdir "$DEV")"
    touch "$MNT/f"
    python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"v")' "$MNT/f"
    sync
    mark="$(dmesg_mark)"
    ct_param_set record_tear_ms 0
    python3 -I -c '
import os, sys
p = open("/sys/module/cetrafs/parameters/record_tear_ms", "w")
p.write(sys.argv[3]); p.flush()
'"$1" "$MNT" "$PROC" "$TEAR_MS" >/dev/null 2>&1 || rc=$?
    sleep 0.3
    ct_param_set record_tear_ms 0
    local C
    C="$(awk '$1 == "corruptions:" { print $2 }' "$PROC/info")"
    ct_umount "$MNT"
    for k in "${kinds[@]}"; do
        dmesg_since "$mark" | grep -q "record_tear_ms: tore a $k read" ||
            { fail "$c: setup: no $k read was torn"; return; }
    done
    [ "$C" = 0 ] || { fail "$c: the volume counts $C corruption(s) from a $TEAR_MS ms tear"; return; }
    if dmesg_since "$mark" | grep -q "corrupted, not just a torn concurrent read"; then
        fail "$c: a tear of $TEAR_MS ms was declared corruption: $(dmesg_since "$mark" | grep "corrupted, not just" | head -1)"
    elif [ "$rc" != 0 ]; then
        fail "$c: the operation failed (exit $rc)"
    else
        pass "$c: the torn read(s) converged"
    fi
}

torn "inode record (getxattr)" "inode record" -- 'os.getxattr(sys.argv[1] + "/f", "user.k")'
torn "node row (cluster dump)" "node row" -- 'open(sys.argv[2] + "/cluster").read()'
torn "ZG record (statfs)" "ZG record" -- 'os.statvfs(sys.argv[1])'
torn "BG descriptor (info dump)" "BG descriptor" -- 'open(sys.argv[2] + "/info").read()'
ct_exit
