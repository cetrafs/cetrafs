#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow published while a mount is in flight is adopted by that mount; any other rewrite of block 0 is still refused
#
# After registering, a mount reads block 0 again and refuses to come up
# if it is no longer the superblock it validated: mkfs may have started
# under it. A grow rewrites block 0 too -- live, under mounted nodes --
# and one that publishes between a mount's first read and that re-check
# made the mount fail as "rewritten (mkfs?)" (GROWFS-LIVE-REVIEW L2).
# The re-check now adopts a grow of what it read, through the same
# refresh every mounted node runs, and still refuses anything else.
#
# Staged with mount_register_stall_ms (a pause between the mount gate
# and registration) and an offline growfs run inside the pause: nothing
# is registered yet, so the grow goes ahead, holds and releases its
# claim, and publishes -- block 0 is a grow of what the mount read, the
# same state a live grow by a peer leaves.
#
#  A. the stalled mount comes up at the grown layout, and fsck is clean.
#  B. the same pause with block 0 changed in a way a grow does not
#     (inode_table_start moved, layout_gen bumped, checksum restamped):
#     the mount is refused.
#
# DISCRIMINATION: with any difference refused, A's mount fails with
# "rewritten while this mount was in flight" (2026-11-08). B is the
# control that the re-check still refuses.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_big_image 1500 growmidmount)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt growmidmount)"
ct_track mnt "$MNT"
ct_param_set mount_register_stall_ms 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/d0" bs=1M count=4 conv=fsync status=none
SUM="$(md5sum <"$MNT/d0")"
ct_umount "$MNT"
GEN0="$("$SBPOKE" "$IMG" | sed -n 's/^layout_gen=//p')"
[ -n "$GEN0" ] || { fail "setup: could not read layout_gen"; ct_exit; }

# ------------------------------------------------------------------- A
log "A: a grow published while a mount is in flight"
ct_param_set mount_register_stall_ms 15000
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" 2>"$(ct_tmp growmid-err)" &
MP=$!
sleep 2
out="$(ct_growfs "$DEV" -s 1400M 2>&1)" || true
GEN1="$("$SBPOKE" "$IMG" | sed -n 's/^layout_gen=//p')"
if wait "$MP"; then
    MOUNTED=1
else
    MOUNTED=""
fi
[ "$(cat /sys/module/cetrafs/parameters/mount_register_stall_ms)" = 0 ] ||
    { fail "A: setup: the mount never reached the stall"; ct_exit; }
[ "$GEN1" = "$((GEN0 + 1))" ] ||
    { fail "A: setup: the grow did not publish inside the stall (layout_gen $GEN0 -> $GEN1): $(tail -1 <<<"$out")"; ct_exit; }
pass "A: setup: the grow published inside the mount's stall (layout_gen $GEN0 -> $GEN1)"
if [ -n "$MOUNTED" ]; then
    pass "A: the mount came up"
    [ "$(info layout_gen)" = "$GEN1" ] && pass "A: at the grown layout (layout_gen $GEN1)" ||
        fail "A: the mount is at layout_gen $(info layout_gen), not $GEN1"
    dmesg_since "$MARK" | grep -q 'grown live while this mount was in flight' &&
        pass "A: and said it adopted the grow" || fail "A: the mount did not report the grow it adopted"
    [ "$(md5sum <"$MNT/d0")" = "$SUM" ] && pass "A: data written before reads back" || fail "A: data damaged"
    ct_umount "$MNT"
else
    fail "A: the mount was refused: $(dmesg_since "$MARK" | grep -m1 -E 'refusing|rewritten' || cat "$(ct_tmp growmid-err)")"
fi
out="$(ct_fsck "$DEV" 2>&1)" && pass "A: fsck is clean" || fail "A: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"

# ------------------------------------------------------------------- B
log "B: block 0 rewritten in a way a grow does not, while a mount is in flight"
ITS="$("$SBPOKE" "$IMG" | sed -n 's/^inode_table_start=//p')"
GEN="$("$SBPOKE" "$IMG" | sed -n 's/^layout_gen=//p')"
ct_param_set mount_register_stall_ms 4000
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null &
MP=$!
sleep 1.5
"$SBPOKE" "$IMG" inode_table_start "$((ITS + 1))" >/dev/null
"$SBPOKE" "$IMG" layout_gen "$((GEN + 1))" >/dev/null
if wait "$MP"; then
    fail "B: the mount came up on a superblock rewritten in a way a grow does not"
    ct_umount "$MNT"
else
    dmesg_since "$MARK" | grep -q 'rewritten while this mount was in flight' &&
        pass "B: refused as a rewrite" || fail "B: refused, but not as a rewrite"
fi
"$SBPOKE" "$IMG" inode_table_start "$ITS" >/dev/null
"$SBPOKE" "$IMG" layout_gen "$GEN" >/dev/null
ct_exit
