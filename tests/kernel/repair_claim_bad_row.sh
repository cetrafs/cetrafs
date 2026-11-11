#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a REPAIR row that fails its checksum never lets a mount through
#
# fill_super() refuses to mount while an offline repairer (fsck -r,
# growfs) holds a live REPAIR row. The gate's comment said a row whose
# checksum does not verify "is ignored", which read as a hole: a
# repairer's row read bad would let the mount in mid-repair (audit
# 2026-11-11 N5). It is not one -- the registry reader retries a tear
# and then marks the volume corrupt, so the mount is refused as damage.
# This pins that, for a bad row standing still and for one being
# rewritten (bad every time) while the mount watches.
#
# DISCRIMINATION (2026-11-11, cetrafs_read_node_entry() reading a bad
# row as FREE): 1 mounts. 2 is still refused there, as a live repair --
# its writer's renewal verifies for a moment between rewrites.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 repbad)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt repbad)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ROW=3

try_mount() { # <case> <what>
    local RC=0 LOG
    timeout 90 mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || RC=$?
    LOG="$(dmesg_since "$MARK")"
    if [ "$RC" = 0 ]; then
        fail "$1: the volume mounted beside $2"
        ct_umount "$MNT"
    elif echo "$LOG" | grep -qE "node row $ROW failed its checksum repeatedly|being repaired right now"; then
        pass "$1: refused beside $2"
    else
        fail "$1: the mount failed for another reason (exit $RC): $(echo "$LOG" | grep cetrafs | tail -2)"
    fi
}

"$NPOKE" "$IMG" $ROW 2 aa "$(date +%s)" >/dev/null
"$NPOKE" "$IMG" $ROW --badsum >/dev/null
blockdev --flushbufs "$DEV"
MARK="$(dmesg_mark)"
try_mount 1 "a REPAIR row that fails its checksum"

"$NPOKE" "$IMG" $ROW 2 aa "$(date +%s)" >/dev/null
"$NPOKE" "$IMG" $ROW --badsum >/dev/null
blockdev --flushbufs "$DEV"
bash -c 'for _ in $(seq 1 120); do "$1" "$2" "$3" --beat >/dev/null 2>&1; "$1" "$2" "$3" --badsum >/dev/null 2>&1; sleep 0.5; done' _ "$NPOKE" "$IMG" $ROW &
W=$!
MARK="$(dmesg_mark)"
try_mount 2 "a REPAIR row rewritten bad while the mount watches"
kill "$W" 2>/dev/null || true; wait "$W" 2>/dev/null || true

"$NPOKE" "$IMG" $ROW 0 00 0 >/dev/null
ct_exit
