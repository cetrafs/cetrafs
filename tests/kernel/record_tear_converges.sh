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
# cetrafs_tear_backoff()). Every record read tears for 8 ms
# (record_tear_ms) while one operation that reads each kind runs.
#
# DISCRIMINATION (2026-11-11, the four readers before this fix): every
# case reports "corrupted, not just a torn concurrent read".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
[ -w $P/record_tear_ms ] || { skip "record_tear_ms is missing"; ct_exit; }

DEV="$(ct_dev 560 rectear)"
MNT="$(ct_mnt rectear)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="/proc/fs/cetrafs/$(basename "$(readlink -f "$DEV")")"
touch "$MNT/f"
python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"v")' "$MNT/f"
sync

torn() { # <case> <cmd...>: run cmd while every record read tears for 8 ms
    local c="$1" h0 h1 mark rc=0
    shift
    mark="$(dmesg_mark)"
    h0="$(cat $P/record_tear_hits)"
    ct_param_set record_tear_ms 8
    "$@" >/dev/null 2>&1 || rc=$?
    h1="$(cat $P/record_tear_hits)"
    sleep 0.05
    ct_param_set record_tear_ms 0
    [ "$h1" -gt "$h0" ] || { fail "$c: setup: no record read was torn"; return; }
    if dmesg_since "$mark" | grep -q "corrupted, not just a torn concurrent read"; then
        fail "$c: a tear of 8 ms was declared corruption: $(dmesg_since "$mark" | grep "corrupted, not just" | head -1)"
    elif [ "$rc" != 0 ]; then
        fail "$c: the operation failed (exit $rc)"
    else
        pass "$c: $((h1 - h0)) torn read(s) converged"
    fi
}

torn "inode record (getxattr)" python3 -c 'import os,sys; os.getxattr(sys.argv[1], "user.k")' "$MNT/f"
torn "node row (cluster dump)" cat "$PROC/cluster"
torn "ZG and BG records (statfs)" stat -f "$MNT"
C="$(awk '$1 == "corruptions:" { print $2 }' "$PROC/info")"
[ "$C" = 0 ] && pass "the volume counts no corruption" || fail "the volume counts $C corruption(s) from tears"
ct_umount "$MNT"
ct_exit
