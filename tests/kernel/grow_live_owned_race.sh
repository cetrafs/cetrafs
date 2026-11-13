#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group claim or release landing inside a layout publish leaves every Block Group marked right
#
# A node allocates only from Block Groups marked ours (owned_bgs), and
# the mark is derived from Zone Group ownership. Two things write it: a
# claim or release of a Zone Group re-derives the marks of that Zone
# Group's Block Groups from the layout it finds
# (cetrafs_sb_owned_bgs_derive()), and a live grow's publish marks the
# Block Groups it adds from the Zone Groups owned at that moment
# (cetrafs_layout_publish()). Both run under owned_lock, so whichever is
# second sees the other's work. Without it a derive can walk the OLD
# layout while the publish marks from ownership read BEFORE the change:
#  - a release leaves a just-added Block Group of the released Zone Group
#    marked ours ("stray") -- this node then allocates in a group it has
#    given away;
#  - a claim leaves one of the claimed Zone Group unmarked ("missing").
# The lock was argued, never measured; this measures it.
#
# One node, playing the peer itself (grow_live_refresh.sh): the grow is
# committed with grow_skip_local_publish, and its new Block Group is
# recorded as Zone Group 1's, as a peer that owned Zone Group 1 then
# would have claimed it. A read through the new space publishes the
# layout on demand, held inside owned_lock (layout_publish_hold_ms)
# after it has marked; the claim or release is made to land in the hold.
# owned_derive_overlaps proves it did; procfs owned_bgs_stray/missing
# (cetrafs_sb_owned_bgs_check()) is the verdict.
#
#  A. claim: Zone Group 0 full, Zone Group 1 not ours; a write in the
#     hold claims it. Control (owned_derive_unlocked=1) first, then the
#     real lock: the new Block Group is marked.
#  B. release: Zone Group 1 ours and emptied; the heartbeat's release
#     (held back with zg_release_hold until the hold began) gives it up
#     in the hold. Control first, then the lock: nothing stray.
#
# DISCRIMINATION: the controls are the lock removed, selected by the knob.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in layout_publish_hold_ms owned_derive_unlocked zg_release_hold grow_skip_local_publish zg_claim_layout_stale; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
PPOKE="$(ct_helper extent_phys_poke)"

IMG="$(ct_big_image 2400 ownrace)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ownrace)"
ct_track mnt "$MNT"
# Two-second beats, not fewer: the held publish blocks the heartbeat, and
# the lease is three beats -- at 1 s a 3 s hold self-fenced the node and
# every write after it was EIO. The holds stay under the 6 s lease.
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0
ct_param_set layout_past_end_no_refresh 0
ct_param_set layout_publish_hold_ms 0
ct_param_set owned_derive_unlocked 0
ct_param_set zg_release_hold 0
ct_param_set zg_claim_layout_stale 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
zg_owner() { grep -oP "^\s+zg $1: owner=\K\S+" "$(ct_procdir "$DEV")/info"; }
zg_free() { grep -oP "^\s+zg $1: .*free_data_blocks=\K[0-9]+" "$(ct_procdir "$DEV")/info"; }

# <claim|release>: a fresh volume up to the moment before the race.
# Leaves the grow on the device, this node behind it, Block Group NEWID
# recorded as Zone Group 1's, and v1's extent aimed into it.
stage() {
    ct_mkfs "$DEV" -s 1200M -b 512 -z 2 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/zero of="$MNT/v1" bs=4096 count=1 conv=fsync status=none
    INO1="$(stat -c %i "$MNT/v1")"
    ct_umount "$MNT"
    for bg in $(ct_bgs_of_zg "$DEV" 0); do "$BG_POKE" "$DEV" "$bg" 0 fill-bitmap >/dev/null; done
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    [ "$(zg_owner 1)" = none ] || { fail "$1: setup: Zone Group 1 is already owned at mount"; return 1; }
    if [ "$1" = release ]; then
        ct_param_set zg_release_hold 1
        dd if=/dev/zero of="$MNT/f" bs=4096 count=16 conv=fsync status=none # claims Zone Group 1
        [ "$(zg_owner 1)" = 0 ] || { fail "release: setup: the write did not claim Zone Group 1"; return 1; }
        local f0 f1 _
        f0="$(zg_free 1)"
        rm -f "$MNT/f"
        sync
        # A Block Group is handed back only once it reads empty. Wait for
        # the delete's 16 blocks to show in the aggregate, or the release
        # this round stages never comes at all.
        for _ in $(seq 1 60); do
            f1="$(zg_free 1)"
            [ "$f1" -ge $((f0 + 16)) ] && break
            sleep 0.5
        done
        [ "$f1" -ge $((f0 + 16)) ] ||
            { fail "release: setup: the deleted file's blocks never came back to Zone Group 1 ($f0 -> $f1)"; return 1; }
        # The release skips a Zone Group whose aggregate delta is not
        # flushed yet (cetrafs_sb_zg_delta_pending()); the delete just
        # left one. Let two beats flush it with the release still held, or
        # the release slips a beat and can fall past the hold.
        sleep 5
    fi
    ct_param_set layout_refresh_hb_off 1
    NEWID="$(info block_group_count)"
    ct_param_set grow_skip_local_publish 1
    out="$(ct_growfs "$DEV" -s 1800M 2>&1)" || { fail "$1: setup: the grow failed: $(tail -2 <<<"$out")"; return 1; }
    NEWBG="$(sed -n 's/.*new BG regions: LBA \([0-9][0-9]*\) .*/\1/p' <<<"$out")"
    [ -n "$NEWBG" ] && [ "$(info block_group_count)" = "$NEWID" ] ||
        { fail "$1: setup: no new Block Group, or this node switched to it on its own"; return 1; }
    "$BG_POKE" "$IMG" "$NEWID" --owner 1 >/dev/null || { fail "$1: setup: could not record BG$NEWID as Zone Group 1's"; return 1; }
    T1=$((NEWBG + 65536))
    printf 'MARKER-ONE\n' | dd of="$IMG" bs=4096 seek="$T1" conv=notrunc,sync status=none
    P1="$("$PPOKE" "$IMG" "$INO1" "$T1")" || { fail "$1: setup: could not aim v1: $P1"; return 1; }
    WAS1="$(sed -n 's/.*phys \([0-9][0-9]*\) ->.*/\1/p' <<<"$P1")"
    sync
    echo 3 >/proc/sys/vm/drop_caches
}

# Put v1 back where it was and check the volume -- only for the runs
# with the lock (a control leaves a group marked wrong and may have
# allocated in it).
finish() {
    ct_umount "$MNT"
    "$PPOKE" "$IMG" "$INO1" "$WAS1" >/dev/null
    if [ "$1" = A ]; then # the claim skipped its recount's catch-up (run_claim): the mount's recount
        ct_mount "$DEV" "$MNT"
        ct_umount "$MNT"
    fi
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$1: fsck clean" || fail "$1: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
}

# <tag> <unlocked 0|1>
run_claim() {
    local tag="$1" o0 r
    stage claim || return 0
    # A claim catches its layout up before it recounts, waiting out a
    # publish in progress (zg_claim_behind_grow.sh) -- so it can no longer
    # land inside the held publish, and owned_lock could not be measured.
    # Skip the catch-up here: this suite is about the marks; finish()
    # remounts so the mount's recount puts the aggregate right.
    ct_param_set zg_claim_layout_stale 1
    ct_param_set owned_derive_unlocked "$2"
    o0="$(info owned_derive_overlaps)"
    ct_param_set layout_publish_hold_ms 3000
    (head -c 10 "$MNT/v1" >"$MNT.read" 2>/dev/null || true) & # publishes, held
    r=$!
    sleep 0.5
    dd if=/dev/zero of="$MNT/w" bs=4096 count=16 conv=fsync status=none # claims Zone Group 1 in the hold
    wait "$r"
    ct_param_set owned_derive_unlocked 0
    ct_param_set zg_claim_layout_stale 0
    [ "$(info owned_derive_overlaps)" -gt "$o0" ] && [ "$(info block_group_count)" -gt "$NEWID" ] &&
        [ "$(zg_owner 1)" = 0 ] ||
        { fail "$tag: setup: the claim did not land in the held publish (overlaps $o0 -> $(info owned_derive_overlaps), BGs $(info block_group_count), ZG1 owner $(zg_owner 1))"; ct_umount "$MNT"; return 0; }
    pass "$tag: setup: Zone Group 1 was claimed while the publish adding BG$NEWID was held"
    MISSING="$(info owned_bgs_missing)"; STRAY="$(info owned_bgs_stray)"
    [ "$(cat "$MNT.read")" = MARKER-ONE ] || fail "$tag: the read that published got '$(cat "$MNT.read")'"
}

# <tag> <unlocked 0|1>
run_release() {
    local tag="$1" o0 r
    stage release || return 0
    ct_param_set owned_derive_unlocked "$2"
    o0="$(info owned_derive_overlaps)"
    ct_param_set layout_publish_hold_ms 4000
    (head -c 10 "$MNT/v1" >"$MNT.read" 2>/dev/null || true) &
    r=$!
    sleep 0.5
    ct_param_set zg_release_hold 0 # the next beat (2 s) releases Zone Group 1, in the hold
    wait "$r"
    for _ in $(seq 1 20); do [ "$(zg_owner 1)" = none ] && break; sleep 0.5; done
    ct_param_set owned_derive_unlocked 0
    [ "$(info owned_derive_overlaps)" -gt "$o0" ] && [ "$(info block_group_count)" -gt "$NEWID" ] &&
        [ "$(zg_owner 1)" = none ] ||
        { fail "$tag: setup: the release did not land in the held publish (overlaps $o0 -> $(info owned_derive_overlaps), BGs $(info block_group_count), ZG1 owner $(zg_owner 1))"; ct_umount "$MNT"; return 0; }
    pass "$tag: setup: Zone Group 1 was released while the publish adding BG$NEWID was held"
    MISSING="$(info owned_bgs_missing)"; STRAY="$(info owned_bgs_stray)"
    [ "$(cat "$MNT.read")" = MARKER-ONE ] || fail "$tag: the read that published got '$(cat "$MNT.read")'"
}

# ---------------------------------------------------------------- A
log "A: a claim inside a held publish"
run_claim "A control" 1
[ "${MISSING:-0}" -ge 1 ] && pass "A control: without the lock BG$NEWID of the claimed Zone Group is left unmarked ($MISSING missing)" ||
    fail "A control: without the lock nothing went missing (missing ${MISSING:-?}, stray ${STRAY:-?}) -- the suite cannot tell the lock from its absence"
mountpoint -q "$MNT" && ct_umount "$MNT"
MISSING=""; STRAY=""
run_claim "A" 0
[ "$MISSING" = 0 ] && [ "$STRAY" = 0 ] && pass "A: with the lock every Block Group is marked right (BG$NEWID ours)" ||
    fail "A: missing $MISSING, stray $STRAY after a claim inside the publish"
mountpoint -q "$MNT" && finish A

# ---------------------------------------------------------------- B
log "B: a release inside a held publish"
MISSING=""; STRAY=""
run_release "B control" 1
[ "${STRAY:-0}" -ge 1 ] && pass "B control: without the lock BG$NEWID of the released Zone Group stays marked ours ($STRAY stray)" ||
    fail "B control: without the lock nothing was left stray (stray ${STRAY:-?}, missing ${MISSING:-?}) -- the suite cannot tell the lock from its absence"
mountpoint -q "$MNT" && ct_umount "$MNT"
MISSING=""; STRAY=""
run_release "B" 0
[ "$STRAY" = 0 ] && [ "$MISSING" = 0 ] && pass "B: with the lock nothing is marked ours in the released Zone Group" ||
    fail "B: stray $STRAY, missing $MISSING after a release inside the publish"
mountpoint -q "$MNT" && finish B
rm -f "$MNT.read"
ct_exit
