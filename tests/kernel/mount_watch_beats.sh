#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount that watches its peers' rows beats its own while it does, and refuses beside a peer it could not fence
#
# Every mount-time liveness check watches a row for a window and calls a
# row that never moved dead. They all run before this node's heartbeat
# starts -- so this node's OWN row stood still for the whole of each one.
# Two nodes mounting within a window of each other each watched the
# other's still row and judged it dead: on a volume with no atomic CAW
# both went ahead (each then fencing the other), and on a CAW volume an
# ON and an OFF file-lock mode both passed the mode check (audit
# 2026-11-11 N1). A mount now renews its own row while it watches.
#
# And the no-CAW gate, having judged a row dead, fences it before
# mounting -- the revoked lease is all a stalled peer that resumes on
# such a volume will see. A fence that failed with anything but "it came
# back" was logged and the mount went ahead beside it (N3).
#
#  1. a post-registration watch (a silent row planted after the gate,
#     before registration): our own row's hb_seq moves while it runs.
#  2. the pre-registration gate over a dead row whose fence fails: the
#     mount is refused and says why.
#  3. CONTROL: the same gate with the fence working mounts.
#
# DISCRIMINATION (2026-11-11): without the beat, 1 reads our hb_seq
# unchanged across the watch; without the refusal, 2 mounts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in mount_register_stall_ms nocaw_gate_fence_fail; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 mwbeat)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mwbeat)"
ct_track mnt "$MNT"
compress_timing

# clear: row 1 back to FREE, so the next mkfs's own live-peer probe has
# nothing to wait out.
clear1() { "$POKE" "$DEV" 1 0 00 0 >/dev/null; blockdev --flushbufs "$DEV"; }
# hbseq <row>: the row's hb_seq as the DEVICE holds it, read while a
# mount is in progress -- O_DIRECT into a copy, since a flushbufs waits
# for the mount and a cached read could be stale.
SNAP="$(ct_tmp mwbeat-snap)"
hbseq() {
    dd if="$DEV" of="$SNAP" bs=1M count=16 iflag=direct status=none
    "$POKE" "$SNAP" "$1" | sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p'
}

# ------------------------------------------------------------------- 1
log "1: a post-registration watch -- our own row beats while it runs"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_param_set mount_register_stall_ms 3000
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" &
MP=$!
sleep 1 # inside the stall: past the gate, not yet registered
# A row advertising 20 s: the watch lasts that long, so both samples
# below fall inside it, before this mount's heartbeat starts.
poke_dead_peer "$DEV" 1 aa
"$POKE" "$DEV" 1 --stale 20 >/dev/null # (no flushbufs: it would wait for the mount)
wait_for 20 "dmesg_since '$MARK' | grep -q 'watching 1 registry row'" ||
    { fail "setup: no post-registration watch ran: $(dmesg_since "$MARK" | tail -3)"; wait "$MP" || true; ct_exit; }
H0="$(hbseq 0)"
sleep 5
H1="$(hbseq 0)"
dmesg_since "$MARK" | grep -q "mounted OK" && { fail "setup: the mount finished before the second sample -- nothing measured"; wait "$MP" || true; ct_exit; }
wait "$MP" && MOUNTED=1 || MOUNTED=0
[ -n "$H0" ] && [ "$H1" -gt "$H0" ] && pass "1: our row beat while the watch ran (hb_seq $H0 -> $H1)" ||
    fail "1: our row stood still for the watch (hb_seq $H0 -> $H1) -- a peer watching it would call us dead"
[ "$MOUNTED" = 1 ] && pass "1: and the mount went ahead past the dead row" || fail "1 setup: the mount failed"
mountpoint -q "$MNT" && ct_umount "$MNT"
clear1

# ------------------------------------------------------------------- 2
log "2: the gate judges a row dead and cannot fence it"
ct_mkfs_small "$DEV" -M 4 >/dev/null
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
ct_param_set nocaw_gate_fence_fail 1
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    fail "2: the mount went ahead beside a dead row whose lease it could not revoke"
    umount "$MNT"
else
    dmesg_since "$MARK" | grep -q "its lease could not be revoked" &&
        pass "2: refused, and said why" || fail "2: refused, but not for the fence: $(dmesg_since "$MARK" | tail -2)"
fi
ct_param_set nocaw_gate_fence_fail 0
clear1

# ------------------------------------------------------------------- 3
log "3: CONTROL -- the same gate with the fence working"
ct_mkfs_small "$DEV" -M 4 >/dev/null
poke_dead_peer "$DEV" 1 aa
blockdev --flushbufs "$DEV"
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null && pass "3: mounted once the dead row was fenced" ||
    fail "3: the gate refused a dead row it could fence"
mountpoint -q "$MNT" && ct_umount "$MNT"
clear1
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"
ct_exit
