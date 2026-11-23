#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held block its own write put on the device is unpinned at once, not at the next tick
#
# Every in-place metadata update is held from the block layer's
# writeback (A-15), and defrag's copied data blocks go through the same
# publish. A held block is pinned while listed, and only the maintenance
# tick's held flush unlisted -- so a block written by its caller's own
# synchronous write stayed pinned until the next tick or later: a defrag
# moving an image at device speed pinned its throughput times the
# heartbeat interval, unreclaimable (audit 2026-11-15 F-27). The write
# that clears the held bit now unlists it.
#
# A 2000-block file, fragmented by interleaving, is defragmented with the
# tick at its slowest (30 s); the listed count is read as the tool
# returns, before any tick or sync.
#   fixed:   what stays listed is a handful, not the copies;
#   control: held_unlist_off=1 -- every copied block is still listed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "the defragmenter, which nofilelock disables (nofilelock_no_defrag.sh)"
[ -w /sys/module/cetrafs/parameters/held_unlist_off ] || { skip "held_unlist_off is missing"; ct_exit; }
IMG="$(ct_image 560 heldun)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt heldun)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set held_unlist_off 0
ct_param_set hb_interval_secs 30
N=2000

# <unlist_off 0|1> -> RES: "listed=<n> moved=<n>"
round() {
    local out
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    python3 - "$MNT" "$N" <<'PY'
import os, sys
d, n = sys.argv[1], int(sys.argv[2])
a = os.open(os.path.join(d, "a"), os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(os.path.join(d, "b"), os.O_CREAT | os.O_WRONLY, 0o644)
blk = os.urandom(4096)
for i in range(n):
    os.pwrite(a, blk, i * 4096)
    os.pwrite(b, blk, i * 4096)
    if i % 64 == 63:
        os.fsync(a); os.fsync(b)
os.fsync(a); os.fsync(b)
os.close(a); os.close(b)
PY
    sync
    sleep 1
    echo "$1" >/sys/module/cetrafs/parameters/held_unlist_off
    out="$("$ROOT/userspace/defrag.cetra" "$MNT/a" 2>&1 || true)"
    RES="listed=$(sed -n 's/^held_listed: //p' "$(ct_procdir "$DEV")/info")"
    RES="$RES moved=$(sed -n 's/.*(\([0-9]*\) blocks moved).*/\1/p' <<<"$out" | head -1)"
    echo 0 >/sys/module/cetrafs/parameters/held_unlist_off
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 || RES="$RES fsck=bad"
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

round 0
F="$RES"
round 1
C="$RES"
log "fixed: $F; control (unlisted only by the tick): $C"
[ "${C##*fsck=}" != bad ] && [ "${F##*fsck=}" != bad ] || fail "fsck after a round: fixed $F, control $C"
[ -n "$(field moved "$C")" ] && [ "$(field moved "$C")" -ge $((N / 2)) ] ||
    { fail "setup: the defrag moved $(field moved "$C") block(s), not the file -- nothing to pin: $C"; ct_exit; }
[ "$(field listed "$C")" -ge $((N / 2)) ] &&
    pass "control: listed until the tick, the copies stay pinned ($(field listed "$C"))" ||
    fail "control: only $(field listed "$C") listed -- the suite does not see the pins"
[ "$(field listed "$F")" -le 64 ] &&
    pass "fixed: $(field listed "$F") block(s) left listed after moving $(field moved "$F")" ||
    fail "fixed: $(field listed "$F") block(s) still listed after the defrag: $F"
ct_exit
