#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the unmount of a stopped mount writes nothing to the device
#
# A stopped mount -- fenced, its lease lost, a fatal error -- writes
# nothing (docs/internal/ERRORS.md): a peer may already have claimed its
# journal area and be replaying it, and own the blocks it had dirtied.
# The unmount still parked the journal flag: the header block was marked
# dirty, its own sync was refused under the fence and left it dirty, and
# put_super's sync_blockdev() wrote it out anyway -- the whole header,
# CLEAN, blind (audit 2026-11-06 M1).
#
# Staged: a volume with a journal, a few creates (the flag goes DIRTY and
# metadata is dirtied), `shutdown=now` through procfs, then the unmount.
# The backing image must be byte-identical before and after the unmount.
#
# DISCRIMINATION: with the unmount's journal park and syncs run on a
# stopped mount, the image changes across the unmount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 stopum)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt stopum)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -N 1024 -f >/dev/null # a journal, unlike ct_mkfs_small
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
PROC="$(ct_procdir "$DEV")"
grep -qE '^journal_(slots|area)' "$PROC/info" || log "note: info does not name the journal"

mkdir "$MNT/d"
for i in $(seq 1 20); do echo "$i" >"$MNT/d/f$i"; done
sync
for i in $(seq 21 40); do echo "$i" >"$MNT/d/f$i"; done # dirty again, unsynced
echo shutdown=now >"$PROC/controls"
touch "$MNT/after" 2>/dev/null && fail "setup: the mount still takes writes after shutdown=now" ||
    pass "setup: the mount is stopped"
sleep 3 # the stop sweep, and any tick that would still run
sync -f "$IMG" 2>/dev/null || true
A="$(md5sum <"$IMG")"
umount "$MNT" || umount -l "$MNT"
sync -f "$IMG" 2>/dev/null || true
B="$(md5sum <"$IMG")"
[ "$A" = "$B" ] && pass "the unmount of a stopped mount wrote nothing" ||
    fail "the unmount of a stopped mount changed the image"
ct_exit
