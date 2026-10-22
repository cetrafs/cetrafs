#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed mount must leave nothing behind -- locally or on the LUN
#
# fill_super() builds a mount out of a dozen subsystems and has nearly
# forty early returns, every one of which has to undo exactly what was
# built so far. On a clustered filesystem that is more than freeing
# memory: by the time most of those returns are reachable this node has
# claimed a Node Registry row on the shared LUN, and a peer that never
# sees it released waits out a full staleness window before it can
# reclaim anything that row owns.
#
# None of those paths had any coverage, and none of them can be reached
# by any input a test can supply -- they are ENOMEM and device-error
# paths. The mount_fail_at module param exists for exactly this: it
# fails the mount after a named stage so the unwind from that point can
# be observed.
#
# What is asserted after each one: the mount failed, the row is left
# saying "cleanly departed" (last_seen = 0, so a peer reclaims
# immediately instead of waiting out the window), no mount is left
# behind, the volume is still fsck-clean, and the very next ordinary
# mount succeeds and re-attaches to the same row.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"
ZG_POKE="$(ct_helper zg_poke)"
FAIL_PARAM=/sys/module/cetrafs/parameters/mount_fail_at

[ -w "$FAIL_PARAM" ] || {
    fail "mount_fail_at param is missing -- the unwind paths cannot be reached without it"
    ct_exit
}

IMG="$(ct_image 1200 unwind)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt unwind)"
ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

# One real mount first, so the row and a ZG claim exist and the unwind
# has something it could plausibly damage.
mount -t cetrafs "$DEV" "$MNT"
echo "payload" >"$MNT/file"
umount "$MNT"
BASE_ZG="$("$ZG_POKE" "$DEV" 0)"

row_field() { "$NODE_POKE" "$DEV" 0 | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }

describe() {
    case "$1" in
    1) echo "node registration" ;;
    2) echo "the no-CAW mount gate" ;;
    3) echo "journal attach/replay" ;;
    4) echo "the Zone Group claim" ;;
    5) echo "heartbeat start" ;;
    6) echo "defrag init" ;;
    7) echo "the root dentry" ;;
    8) echo "procfs publication" ;;
    esac
}

log "every unwind path leaves the cluster state clean"
for stage in 1 2 3 4 5 6 7 8; do
    what="$(describe "$stage")"
    echo "$stage" >"$FAIL_PARAM"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
        echo 0 >"$FAIL_PARAM"
        fail "stage $stage ($what): the mount succeeded -- the fail point was never reached"
        continue
    fi
    echo 0 >"$FAIL_PARAM"

    if mountpoint -q "$MNT"; then
        fail "stage $stage ($what): a mount was left behind after the failure"
        umount "$MNT" 2>/dev/null || true
    fi

    # The row is the shared-state half. mark-offline backdates last_seen
    # to 0, which cetrafs_node_is_stale() reads as "left deliberately" --
    # without it a peer sees a row that merely stopped beating and waits
    # out the whole staleness window before touching anything it owns.
    if [ "$(row_field last_seen)" = "0" ] && [ "$(row_field state)" = "1" ]; then
        pass "stage $stage ($what): the registry row is left REGISTERED but marked departed"
    else
        fail "stage $stage ($what): row reads $("$NODE_POKE" "$DEV" 0) -- a peer would wait out the stale window"
    fi
done

log "the volume is undamaged and still mountable after eight failed mounts"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck is clean after every unwind" ||
    fail "fsck reports damage after the failed mounts: $(ct_fsck "$DEV" 2>&1 | tail -3)"

[ "$("$ZG_POKE" "$DEV" 0)" = "$BASE_ZG" ] &&
    pass "ZG 0's ownership and free count are exactly as the failed mounts found them" ||
    fail "ZG 0 changed across the failed mounts: '$BASE_ZG' -> '$("$ZG_POKE" "$DEV" 0)'"

mount -t cetrafs "$DEV" "$MNT"
ct_track mnt "$MNT"
require_cetrafs_mount "$MNT"
pass "the next ordinary mount succeeds"
[ "$(cat "$MNT/file")" = "payload" ] && pass "the file written before the failed mounts is intact" ||
    fail "file content is '$(cat "$MNT/file")'"
# Re-attach, not a fresh claim: registering again on every failed attempt
# would burn a row per attempt and, with node_table_count rows, lock the
# node out of its own volume.
NODES="$(grep -c '^node ' /proc/fs/cetrafs/"$(basename "$DEV")"/cluster 2>/dev/null || echo 0)"
[ "$NODES" = "1" ] && pass "still exactly one registered node (every failed mount re-attached, none burned a row)" ||
    fail "the cluster now lists $NODES registered nodes after eight failed mounts"
umount "$MNT"

# ------------------------------------------------- ordering assertions
#
# procfs is published LAST, after s_maxbytes is computed. It used to be
# created before the heartbeat even started, so a reader could see a
# half-built mount reporting the VFS's own default max file size.
log "nothing is readable before everything it reads is final"
mount -t cetrafs "$DEV" "$MNT"
MAXB="$(sed -n 's/^max_file_size_bytes: //p' /proc/fs/cetrafs/"$(basename "$DEV")"/info)"
[ -n "$MAXB" ] && [ "$MAXB" -gt 0 ] &&
    pass "procfs reports a computed max_file_size_bytes ($MAXB), not a placeholder" ||
    fail "procfs reports max_file_size_bytes='$MAXB'"
umount "$MNT"

# ------------------------------------------------------------------
# The gate decides whether this node may touch the volume AT ALL, so it
# has to be asked before anything writes. It used to sit after the
# journal replay and the CAS self-test, so a mount about to be refused
# had already replayed entries into the data region of a volume a live
# peer owns.
#
# Reaching that needs three things at once: a volume with no atomic CAW
# (the loop device), a journal entry outstanding, and a foreign claim
# whose owner is actually alive -- a stale one is deliberately let
# through for reclaim.
log "the no-CAW gate is asked before anything writes"
GIMG="$(ct_image 560 gateorder)"
GDEV="$(ct_loop "$GIMG")"
GMNT="$(ct_mnt gateorder)"
JOURNAL_POKE="$(ct_helper journal_poke)"
ct_mkfs "$GDEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

mount -t cetrafs "$GDEV" "$GMNT"
GMARK="$(dmesg_mark)"
touch "$GMNT/newfile"
TARGET_LBA="$(dmesg_since "$GMARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
BACKUP="$(ct_tmp gatebackup)"
if [ -n "$TARGET_LBA" ]; then
    dd if="$GDEV" of="$BACKUP" bs=4096 skip="$TARGET_LBA" count=1 status=none
fi
umount "$GMNT"

if [ -z "$TARGET_LBA" ]; then
    fail "setup: creating a file logged no journal entry, so the ordering cannot be tested"
else
    dd if=/dev/zero of="$GDEV" bs=4096 seek="$TARGET_LBA" count=1 conv=notrunc status=none
    "$JOURNAL_POKE" "$GDEV" 0 0 "$TARGET_LBA" "$BACKUP" >/dev/null
    ZEROED="$(dd if="$GDEV" bs=4096 skip="$TARGET_LBA" count=1 status=none | md5sum)"

    # A peer that is alive: a REGISTERED row whose hb_seq keeps moving
    # while the gate watches it. "Alive" is observed progress, not a
    # recent-looking timestamp.
    set_stale_window "$TEST_STALE_SECS"
    "$(ct_helper node_poke)" "$GDEV" 1 1 bb "$(date +%s)" >/dev/null
    "$(ct_helper zg_poke)" "$GDEV" 0 1 >/dev/null
    (
        for _ in $(seq 1 $((TEST_STALE_SECS + 8))); do
            "$(ct_helper node_poke)" "$GDEV" 1 --beat >/dev/null 2>&1 || true
            sleep 1
        done
    ) &
    BEATER=$!
    sleep 1

    if mount -t cetrafs "$GDEV" "$GMNT" 2>/dev/null; then
        umount "$GMNT"
        fail "the gate let the mount through even though a live peer owns ZG 0"
    else
        pass "a live peer's claim refuses the mount on a volume with no atomic CAW"
    fi
    AFTER="$(dd if="$GDEV" bs=4096 skip="$TARGET_LBA" count=1 status=none | md5sum)"
    [ "$AFTER" = "$ZEROED" ] &&
        pass "the refused mount replayed nothing: it asked the gate before it wrote" ||
        fail "the refused mount replayed its journal into a volume it was then refused from"

    wait "$BEATER" 2>/dev/null || true
    wait_out_stale_window
    # Control: with the peer gone stale the gate lets us in, and the SAME
    # entry really is replayed -- so the assertion above measured the
    # ordering, not an entry that was never valid.
    mount -t cetrafs "$GDEV" "$GMNT"
    umount "$GMNT"
    REPAIRED="$(dd if="$GDEV" bs=4096 skip="$TARGET_LBA" count=1 status=none | md5sum)"
    [ "$REPAIRED" != "$ZEROED" ] &&
        pass "control: once the peer is stale the mount is admitted and the entry IS replayed" ||
        fail "control: the entry was never replayed at all"
    reset_stale_window
fi

ct_exit
