#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node whose device is smaller than the grown volume refuses I/O into the new space without calling it damage
#
# A live grow is run on one host after its LUN was resized; the other
# hosts see the bigger device only once they rescan. Until then their
# layout refresh cannot adopt the grown superblock (it would describe
# blocks their device does not have), and an extent a peer wrote into
# the new space lies past everything they know. That used to read as
# "not a data address": the inode was marked damaged -- a sticky mark,
# every later write to it refused with EUCLEAN -- for an address that is
# valid on every node that has rescanned (GROWFS-LIVE-REVIEW H2). The
# address check now has a third answer, "cannot tell" (-EAGAIN): the I/O
# is refused with EIO and nothing is marked.
#
# Staged on one node over a dm-linear device: grow_skip_local_publish
# commits a grow without switching this node; the device is then cut
# back below the grown size (what a host that has not rescanned sees);
# a file's extent is aimed into the new Block Group, as a peer's write
# would leave it. layout_refresh_hb_off keeps the heartbeat out of it.
#
#  - the read through the new space fails, and no damage is counted;
#  - the device "rescanned" (table restored), the same file reads the
#    block the grow added and still takes writes: it was never marked.
#
# DISCRIMINATION: with "cannot tell" folded into "not data"
# (cetrafs_lba_run_past_end() answering -EUCLEAN when the refresh
# fails), the read marks the inode, the corruption count moves, and the
# write after the rescan is refused (2026-11-08).
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v dmsetup >/dev/null 2>&1 || { skip "dmsetup is missing"; ct_exit; }
PPOKE="$(ct_helper extent_phys_poke)"

IMG="$(ct_big_image 2100 growbehind)"
LOOP="$(ct_loop "$IMG")"
DMN="ctgb$$"
FULL=$(blockdev --getsz "$LOOP")
dmsetup create "$DMN" --table "0 $FULL linear $LOOP 0"
ct_track dm "$DMN"
DEV="/dev/mapper/$DMN"
MNT="$(ct_mnt growbehind)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
dm_size() { # <sectors>
    dmsetup suspend --noflush --nolockfs "$DMN"
    dmsetup load "$DMN" --table "0 $1 linear $LOOP 0"
    dmsetup resume "$DMN"
}

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/v1" bs=4096 count=1 conv=fsync status=none
INO1="$(stat -c %i "$MNT/v1")"

ct_param_set layout_refresh_hb_off 1
gen0="$(info layout_gen)"
ct_param_set grow_skip_local_publish 1
out="$(ct_growfs "$DEV" -s 1400M 2>&1)" || { fail "setup: the grow failed: $(tail -2 <<<"$out")"; ct_exit; }
[ "$(info layout_gen)" = "$gen0" ] || { fail "setup: this node switched to the grown layout itself"; ct_exit; }
NEWBG="$(sed -n 's/.*new BG regions: LBA \([0-9][0-9]*\) .*/\1/p' <<<"$out")"
[ -n "$NEWBG" ] || { fail "setup: growfs did not say where the new Block Group is"; ct_exit; }
T1=$((NEWBG + 65536))
printf 'MARKER-ONE\n' | dd of="$IMG" bs=4096 seek="$T1" conv=notrunc,sync status=none
P1="$("$PPOKE" "$IMG" "$INO1" "$T1")" || { fail "setup: could not aim the extent: $P1"; ct_exit; }
sync; echo 3 >/proc/sys/vm/drop_caches

dm_size $((1000 * 2048)) # 1000 MiB: the grown volume (1400M) no longer fits
[ "$(blockdev --getsz "$DEV")" -lt "$FULL" ] || { fail "setup: the device did not shrink"; ct_exit; }
pass "setup: the volume is grown on disk, this node is at layout_gen $gen0, and its device is smaller than the grow"

log "the device is behind the volume"
c0="$(info corruptions)"
mark="$(dmesg_mark)"
if got="$(head -c 10 "$MNT/v1" 2>/dev/null)" && [ "$got" = "MARKER-ONE" ]; then
    fail "setup: the read through the new space succeeded on a device that does not hold it"
else
    pass "the read through the new space is refused"
fi
D="$(dmesg_since "$mark")"
grep -q "device has" <<<"$D" && pass "the node says its device is behind the volume" ||
    fail "the node did not report its device as behind"
grep -q "not a data address" <<<"$D" && fail "the address was called damage: $(grep -m1 'not a data address' <<<"$D")" ||
    pass "the address was not called damage"
[ "$(info corruptions)" = "$c0" ] && pass "no corruption was counted" ||
    fail "the corruption count moved ($c0 -> $(info corruptions))"
[ "$(info layout_gen)" = "$gen0" ] || fail "the node adopted a layout its device cannot hold"

log "the device is rescanned"
dm_size "$FULL"
sleep 1.5 # past the one-second reuse of "behind"
sync; echo 3 >/proc/sys/vm/drop_caches
got="$(head -c 10 "$MNT/v1" 2>/dev/null || true)"
[ "$got" = "MARKER-ONE" ] && pass "the same file now reads the block the grow added" ||
    fail "after the rescan the read returned '${got:-an error}'"
[ "$(info layout_gen)" = "$((gen0 + 1))" ] && pass "and the node is at layout_gen $((gen0 + 1))" ||
    fail "the node is at layout_gen $(info layout_gen), expected $((gen0 + 1))"
echo more >>"$MNT/v1" && sync && pass "the file still takes writes: it was never marked damaged" ||
    fail "the file refuses writes after the rescan: it was marked damaged while the device was behind"
ct_param_set layout_refresh_hb_off 0
ct_umount "$MNT"
ct_exit
