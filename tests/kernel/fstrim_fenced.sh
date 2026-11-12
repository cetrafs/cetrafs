#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node fenced mid-FITRIM neither discards nor gives back the run it claimed
#
# FITRIM claims a free run (sets its bits), discards it, then clears the
# bits again. A node that loses its device in between is declared dead by
# a peer, which bumps its fence epoch, takes its Zone Groups and
# allocates from them -- into that very run, which reads free on the
# device. When the stalled trim resumes, its discard would zero the
# peer's new data and its give-back would clear the peer's bits. Both
# are refused once the node has fenced itself: cetrafs_discard_issue()
# returns -EIO without sending anything, which the trim treats as an
# outcome it cannot know, so the run is left allocated for the scrub
# (cetrafs_trim_release() checks the fence as well, for a discard that
# completed).
#
# The peer is played on the device, as in fence_drops_dirty_metadata.sh:
# bump this node's fence epoch, wait for the self-fence, write the
# peer's data into the claimed run. Two nodes cannot stage it on demand:
# a running peer takes a stale node's Zone Group only when it owns none.
#
# DISCRIMINATION (measured with the fence checks in
# cetrafs_discard_issue() and cetrafs_trim_release() removed): the
# peer's data in the run is gone -- the fenced node's UNMAP landed -- and
# the run is given back.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/trim_discard_stall_ms ] || { skip "trim_discard_stall_ms is missing"; ct_exit; }
# The fenced mount leaves a row that reads mounted: the next mkfs would
# watch it for the default 120 s.
export CETRAFS_PEER_PROBE_SECS=3
PP="$(ct_helper pending_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_big_image 1200 ftfence)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ftfence)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing

# An 8 MiB hole at the front of the data, a kept file behind it: with
# runs of 4 MiB or more the first run the trim claims is the hole.
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
sync
HOLE="$("$PP" "$IMG" extent "$(stat -c %i "$MNT/h")" | awk '{ print $1 }')"
rm -f "$MNT/h"
sync
[ -n "$HOLE" ] && [ "$HOLE" -gt 0 ] || { fail "setup: could not locate the hole"; ct_exit; }

MARK="$(dmesg_mark)"
ct_param_set trim_discard_stall_ms 8000
fstrim -m 4M "$MNT" >/dev/null 2>&1 &
TPID=$!
sleep 1
kill -0 "$TPID" 2>/dev/null && pass "setup: fstrim is stalled holding its first claim" ||
    { fail "setup: fstrim already finished -- nothing was claimed"; ct_exit; }

log "a peer revokes this node's lease"
"$NODE_POKE" "$DEV" 0 --bump-fence 1 >/dev/null
wait_for 15 "dmesg_since '$MARK' | grep -q SELF-FENCED" || { fail "setup: this node never self-fenced"; ct_exit; }
pass "setup: the node self-fenced while its trim was stalled"

# The peer, now owning the group, writes into the run: on the device.
PEER="$(mktemp /tmp/cetrafs-ftfence-peer-XXXXXX)"
ct_track file "$PEER"
head -c $((8 << 20)) /dev/urandom >"$PEER"
dd if="$PEER" of="$IMG" bs=4096 seek="$HOLE" conv=notrunc,fsync status=none
WANT="$(md5sum <"$PEER" | awk '{ print $1 }')"

ct_param_set trim_discard_stall_ms 0
wait "$TPID" || true
pass "the stalled fstrim returned"
umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true

GOT="$(dd if="$IMG" bs=4096 skip="$HOLE" count=2048 status=none | md5sum | awk '{ print $1 }')"
[ "$GOT" = "$WANT" ] && pass "the peer's data in the claimed run survived: no discard from a fenced node" ||
    fail "the peer's data in the claimed run changed -- the fenced node's UNMAP landed on it"
dmesg_since "$MARK" | grep -qE "left this node during a trim|may still land -- left allocated" &&
    pass "the run was left allocated, not given back" ||
    fail "no 'left allocated' from the trim -- the fenced node gave its run back into a bitmap it no longer owns"

ct_exit
