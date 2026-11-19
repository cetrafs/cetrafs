#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replay entry whose owner is in an inode segment this node has not learned yet is checked, not dropped
#
# Replay confirms an entry's target still belongs to the owner the entry
# names, and an owner number past the inode table this node knows was
# taken as "owner gone": the redo was dropped as "no longer a block of
# its owner". A peer can live-grow the inode table, create a file in the
# new segment, journal a write to that file's metadata and die -- all
# before this node's heartbeat adopts the grown layout. The torn block
# the entry would have repaired stayed torn (audit 2026-11-15 F-61).
# The owner check now catches the layout up before it judges the owner.
#
# Staged on one node, as grow_live_replay.sh: grow_skip_local_publish
# commits a grow (with more inodes) without switching this node, and
# layout_refresh_hb_off keeps the heartbeat from catching up -- so the
# owner check is the only thing that can learn the new segment. A file
# f is given an xattr block (state A), then a second xattr (state B,
# block T). A record planted in the
# new segment (ino 1100) names T as its xattr block, as the peer's file
# would; a stale peer's journal holds one entry for T carrying A,
# guarded against B and naming ino 1100 as its owner. T lies in a Block
# Group this node already knows, so nothing else on the replay path
# refreshes the layout.
#   setup: the grow is on the device and this node is behind it;
#   1. the entry is redone: T holds A again;
#   2. it was never judged "no longer a block of its owner";
#   3. the owner check brought this node to the grown layout.
#
# DISCRIMINATION: journal_owner_known_only=1 restores the old verdict;
# the control requires the refusal in dmesg and T still at B.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_owner_known_only ] ||
    { skip "journal_owner_known_only is missing"; ct_exit; }
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
OWNER=1100
xset() { python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], b"x" * int(sys.argv[3]))' "$@"; }

ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0
ct_param_set journal_owner_known_only 0

# run <control 0|1> -- one staged replay; prints nothing, asserts
run() {
    local ctl="$1" tag="jobg$1"
    local IMG DEV MNT NID PEER gen0 out T A BSUM ASUM FI MARK i got refused D
    IMG="$(ct_big_image 1500 "$tag")"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt "$tag")"
    ct_track mnt "$MNT"
    info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
    blk() { dd if="$IMG" bs=4096 skip="$1" count=1 status=none | sha256sum | cut -d' ' -f1; }
    ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 4 -M 4 -N 1024 -f >/dev/null

    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo data >"$MNT/f"
    xset "$MNT/f" user.a 200
    FI="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    T="$("$IPOKE" "$IMG" xattrblk "$FI" 2>/dev/null)"
    [ -n "$T" ] && [ "$T" != 0 ] || { fail "setup($ctl): f has no xattr block"; return; }
    A="$(ct_tmp "$tag-a")"
    dd if="$IMG" of="$A" bs=4096 skip="$T" count=1 status=none
    ASUM="$(sha256sum <"$A" | cut -d' ' -f1)"

    ct_mount "$DEV" "$MNT"
    NID="$(info this_node_id)"
    PEER=$(((NID + 1) % 4))
    xset "$MNT/f" user.b 4
    sync
    ct_umount "$MNT"
    # setxattr writes a new block: T is now f's current one, A is the
    # older state the entry carries.
    T="$("$IPOKE" "$IMG" xattrblk "$FI" 2>/dev/null)"
    [ -n "$T" ] && [ "$T" != 0 ] || { fail "setup($ctl): f lost its xattr block"; return; }
    BSUM="$(blk "$T")"
    [ "$BSUM" != "$ASUM" ] || { fail "setup($ctl): the xattr block did not change (A = B)"; return; }

    ct_mount "$DEV" "$MNT"
    ct_param_set layout_refresh_hb_off 1
    gen0="$(info layout_gen)"
    ct_param_set grow_skip_local_publish 1
    out="$(ct_growfs "$DEV" -s 1400M -N 1300 2>&1)" || { fail "setup($ctl): the grow failed: $(tail -2 <<<"$out")"; return; }
    [ "$(cat /sys/module/cetrafs/parameters/grow_skip_local_publish)" = N ] ||
        { fail "setup($ctl): the grow did not consume grow_skip_local_publish"; return; }
    [ "$(info layout_gen)" = "$gen0" ] && [ "$(info inodes_count)" = 1024 ] ||
        { fail "setup($ctl): this node adopted the grow itself -- nothing lags"; return; }
    "$IPOKE" "$IMG" plantrec "$OWNER" 0100644 2>/dev/null || { fail "setup($ctl): no slot for ino $OWNER"; return; }
    "$IPOKE" "$IMG" xattrblk "$OWNER" "$T" >/dev/null 2>&1
    pass "setup($ctl): grow on the device, node at layout_gen $gen0 with 1024 inodes; ino $OWNER names block $T"

    ct_param_set journal_owner_known_only "$ctl"
    MARK="$(dmesg_mark)"
    "$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1 # REGISTERED, last_seen=0: stale at once
    cp "$A" "$A.pay"
    JOURNAL_POKE_OWNER="$OWNER" "$JPOKE" "$IMG" "$PEER" 0 "$T" "$A.pay" --guard-current >/dev/null 2>&1
    got="" refused=""
    for i in $(seq 1 40); do
        [ "$(blk "$T")" = "$ASUM" ] && got=1
        D="$(dmesg_since "$MARK")"
        grep -q "target block $T is no longer a block of its owner (ino $OWNER" <<<"$D" && refused=1
        [ -n "$got" ] || [ -n "$refused" ] && break
        sleep 1
    done
    ct_param_set journal_owner_known_only 0
    if [ "$ctl" = 0 ]; then
        [ -n "$got" ] && pass "1: the entry was redone (block $T holds A)" ||
            fail "1: block $T never received A -- the redo was lost"
        [ -z "$refused" ] && pass "2: never judged 'no longer a block of its owner'" ||
            fail "2: the owner in the new segment was taken as gone"
        [ "$(info layout_gen)" = "$((gen0 + 1))" ] && [ "$(info inodes_count)" = 1300 ] &&
            pass "3: the owner check brought this node to the grown layout" ||
            fail "3: layout_gen $(info layout_gen) (want $((gen0 + 1))), $(info inodes_count) inodes"
    else
        [ -n "$refused" ] && [ -z "$got" ] && [ "$(blk "$T")" = "$BSUM" ] &&
            pass "control: the old verdict drops the redo (block $T still at B)" ||
            fail "control: journal_owner_known_only did not drop the redo (refused='$refused' got='$got')"
    fi
    "$IPOKE" "$IMG" xattrblk "$OWNER" 0 >/dev/null 2>&1 # the stand-in owner gives T back
    ct_param_set layout_refresh_hb_off 0
    ct_umount "$MNT"
}

run 0
run 1
ct_exit
