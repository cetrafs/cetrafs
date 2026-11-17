#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a queued free sitting past the head of the queue is still applied
#
# The drain asks first whether a queue holds anything by reading its
# first CETRAFS_PF_DRAIN_EMPTY_RUN blocks, which holds everything only
# while appends fill from the front. An entry a drain left behind (a
# held copy, a busy region) or a peer's append landing after the sweep
# that emptied the head sits past it, and nothing brought a drain back:
# its blocks stayed allocated for good, and fsck -r keeps a queued free
# (audit 2026-11-15 BM-3). The mount's drain and one heartbeat drain in
# twenty now sweep every owned queue whole, and a queue its last drain
# left something in, on every heartbeat.
#
# Staged with an entry at queue block 5 naming a leaked block L (bitmap
# set, nothing references it), the scrub off:
#   A. written before the mount: the mount's drain applies it;
#   B. written while mounted, after that drain: a heartbeat drain
#      applies it within the twenty-tick sweep (the tick compressed).
# Applied: the queue is empty and fsck finds no leak (dropped instead,
# L would read leaked).
# DISCRIMINATION: pf_head_only=1 reads only the head, as before -- the
# entry is still queued (fsck counts its block as queued, not leaked).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pf_head_only ] || { skip "pf_head_only is missing"; ct_exit; }
LEAK="$(ct_helper data_leak_poke)"
PP="$(ct_helper pending_poke)"
IMG="$(ct_image 560 pfres)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfres)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set pf_head_only 0
compress_timing
queued() { "$PP" "$DEV" dump 0 | grep -c . || true; }
# <tag> <A|B> <head_only 0|1> -> RES
round() {
    local L out
    ct_mkfs_small "$DEV" -z 1 >/dev/null
    L="$("$LEAK" "$DEV" 0 40 1 | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
    [ -n "$L" ] || { RES="setup=noleak"; return 0; }
    echo "$3" >/sys/module/cetrafs/parameters/pf_head_only
    if [ "$2" = A ]; then
        "$PP" "$DEV" put 0 5 0 "$L" 1 >/dev/null
        blockdev --flushbufs "$DEV"
        ct_mount "$DEV" "$MNT"
        sleep 3
    else
        ct_mount "$DEV" "$MNT"
        sleep 3 # the mount's sweep is over
        "$PP" "$DEV" put 0 5 0 "$L" 1 >/dev/null
        blockdev --flushbufs "$DEV"
        sleep 30 # twenty one-second ticks and some
    fi
    ct_umount "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/pf_head_only
    RES="queued=$(queued)"
    out="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1 || true)"
    grep -q "referenced by no inode (leaked)" <<<"$out" && RES="$RES leak=yes" || RES="$RES leak=no"
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

for c in A B; do
    round "$c" "$c" 0
    F="$RES"
    round "$c" "$c" 1
    C="$RES"
    log "$c fixed: $F; control (head only): $C"
    [ "$(field queued "$C")" -ge 1 ] &&
        pass "$c control: read at its head only, the queue kept the entry (its block stays allocated)" ||
        fail "$c control: the entry did not stay -- the suite does not stage what it claims: $C"
    [ "$(field queued "$F")" = 0 ] && [ "$(field leak "$F")" = no ] &&
        pass "$c: the entry past the head was applied and the block freed" || fail "$c: $F"
done
ct_exit
