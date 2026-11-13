#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ct-timeout: 3600
# a power cut at any write of an offline grow leaves a volume that mounts, fscks, and finishes on rerun
#
# A grow writes new Block Group headers, zeroed bitmaps and a table
# segment, fsyncs, then publishes with one superblock write. Every write
# before the publish is unreferenced bytes past the old filesystem, and
# every write after it is the new size. A cut in between must leave a
# volume that is still one of the two -- never a mix -- and re-running
# growfs must finish it. Nothing else in the tree cuts power during a
# grow: grow_live_crash.sh abandons the grow at a chosen write, and the
# offline growfs suites stop it before the publish.
#
# Mechanism, as the other crash suites: dm-log-writes records mkfs, a
# workload with an fsync'd file, and the grow, with a mark on each side
# of the grow. replay-log then replays the log onto a scratch device up
# to EVERY write between the marks (--limit-entries: a cut between two
# bios, not only at a barrier -- the grow's fsyncs are few, and the
# half-written states sit between them). The cut is never preceded by a
# flush of its own; the only barriers are the ones growfs issues.
#
# At every cut:
#   - fsck must exit 0 (an unpublished grow is unreferenced bytes, and a
#     half-linked table segment is noted, not damage);
#   - the volume must mount, and at the OLD size or the NEW size only;
#   - the file written before the grow must read back intact;
#   - re-running growfs to the NEW size must succeed, leave the NEW size,
#     and leave fsck clean.
#
# DISCRIMINATION: CETRAFS_GROWFS_TEST_SKIP_BG_HEADERS records a grow that
# publishes over Block Groups it never wrote. The control replays that
# recording to its end and requires fsck to refuse it -- so the fsck
# assertion above is not one that passes on any image.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm-log-writes 2>/dev/null || true
command -v dmsetup >/dev/null || { skip "dmsetup not found"; ct_exit; }

REPLAY="$CT_BUILD/replay-log"
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || { fail "replay-log build failed"; ct_exit; }
fi

# A replayed image is, to the mount, a crash of this machine: its
# growfs claim row is left in the REPAIR state, and the mount and growfs
# both wait out that row's stale window before they proceed. At the
# defaults that is minutes per cut. Shrink it, as crash_consistency.sh
# does; the guard itself is what runs, for less time.
ct_param_set hb_interval_secs 1
ct_param_set stale_secs 3
ct_param_set scrub 0
ct_param_set auto_defrag 0
# fsck and growfs both probe for a live peer before they answer, and a
# claim row a crashed grow left behind counts as one for its whole
# window -- minutes per cut at the default. Shrink the probe, as the
# repair-claim suites do; every cut still waits out the row.
export CETRAFS_PEER_PROBE_SECS=3

OLD_MB=600
NEW_MB=1200
SECT=$((NEW_MB * 2048))
MNT="$(ct_mnt growcrash)"
ct_track mnt "$MNT"
RDEV="$(ct_loop "$(ct_big_image "$NEW_MB" growcrash-replay)")"

# record <tag> [VAR=value ...]: mkfs, a workload, then the grow -- all
# through dm-log-writes, with a mark before and after the grow. Sets
# REC_LOG (the log device), REC_OLD (the old size in blocks, measured
# while it is mounted), REC_SUM (the checksum of the workload's file).
record() {
    local tag="$1" dm data log
    shift
    data="$(ct_loop "$(ct_big_image "$NEW_MB" "growcrash-$tag")")"
    log="$(ct_loop "$(ct_image 512 "growcrash-log-$tag")")"
    dm="growcrash_${tag}_$$"
    dmsetup create "$dm" --table "0 $SECT log-writes $data $log"
    ct_track dm "$dm"
    REC_LOG="$log"
    ct_mkfs "/dev/mapper/$dm" -s "${OLD_MB}M" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "/dev/mapper/$dm" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/keep" bs=4096 count=64 conv=fsync status=none
    REC_SUM="$(sha256sum <"$MNT/keep")"
    REC_OLD="$(stat -f -c %b "$MNT")"
    ct_umount "$MNT"

    dmsetup message "$dm" 0 mark grow_begin
    if ! env "$@" "$ROOT/userspace/growfs.cetra" "/dev/mapper/$dm" -s "${NEW_MB}M" >"$MNT.grow.out" 2>&1; then
        fail "$tag: setup: the recorded grow failed: $(tail -1 "$MNT.grow.out")"
        return 1
    fi
    dmsetup message "$dm" 0 mark grow_end
    dmsetup remove --retry "$dm"
    blockdev --flushbufs "$log"
    return 0
}

# replay_to <log> <entries>: the first <entries> log entries onto a zeroed
# RDEV -- the platter as a cut right after entry <entries> leaves it.
replay_to() {
    blkdiscard "$RDEV" 2>/dev/null || dd if=/dev/zero of="$RDEV" bs=1M status=none 2>/dev/null || true
    "$REPLAY" --log "$1" --replay "$RDEV" --limit-entries "$2" 2>/dev/null || return 1
    blockdev --flushbufs "$RDEV" 2>/dev/null || true
}

# cut <log> <entries>: replay to that cut and check the four properties.
# Prints one line per failed property; returns 0 when all four hold.
cut() {
    local log="$1" n="$2" out size keep rc=0
    replay_to "$log" "$n" || { echo "replay failed at entry $n"; return 1; }

    if ! out="$(ct_fsck "$RDEV" 2>&1)"; then
        echo "fsck: $(grep -m1 -E 'ERR|error|damage' <<<"$out" || echo 'nonzero exit')"
        rc=1
    fi
    if mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null; then
        size="$(stat -f -c %b "$MNT")"
        keep="$(sha256sum <"$MNT/keep" 2>/dev/null || echo missing)"
        umount "$MNT"
        if [ "$size" != "$REC_OLD" ] && [ "$size" != "$NEW_BLOCKS" ]; then
            echo "size: mounted at $size blocks, neither the old $REC_OLD nor the new $NEW_BLOCKS"
            rc=1
        fi
        [ "$keep" = "$REC_SUM" ] || { echo "data: the file written before the grow does not read back"; rc=1; }
    else
        echo "mount: the cut volume does not mount"
        rc=1
    fi
    if ! "$ROOT/userspace/growfs.cetra" "$RDEV" -s "${NEW_MB}M" >/dev/null 2>&1; then
        echo "finish: growfs refuses to finish the grow it was cut out of"
        rc=1
    else
        if ! out="$(ct_fsck "$RDEV" 2>&1)"; then
            echo "finish: fsck after the rerun: $(grep -m1 -E 'ERR|error|damage' <<<"$out" || echo 'nonzero exit')"
            rc=1
        fi
        mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null || { echo "finish: the finished grow does not mount"; rc=1; }
        if mountpoint -q "$MNT"; then
            [ "$(stat -f -c %b "$MNT")" = "$NEW_BLOCKS" ] || { echo "finish: the rerun did not reach the new size"; rc=1; }
            umount "$MNT"
        fi
    fi
    return "$rc"
}

# ---- the real recording
log "recording a grow of $OLD_MB MiB to $NEW_MB MiB through dm-log-writes"
record real || { ct_exit; }
B="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_begin 2>/dev/null || true)"
E="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_end 2>/dev/null || true)"
case "$B$E" in
"" | *[!0-9]*) fail "setup: the log does not carry both grow marks (begin='$B' end='$E')"; ct_exit ;;
esac
[ "$E" -gt "$B" ] || { fail "setup: the grow wrote nothing between its marks ($B..$E)"; ct_exit; }

# The completed grow fixes the NEW size, which every cut is compared to.
# Measured first, and asserted to differ from the old size: a cut that
# matched either would otherwise be measured against an unset value.
NEW_BLOCKS=0
replay_to "$REC_LOG" "$((E + 1))" || { fail "setup: the completed grow does not replay"; ct_exit; }
ct_fsck "$RDEV" >/dev/null 2>&1 || { fail "setup: the completed grow does not fsck clean"; ct_exit; }
mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null || { fail "setup: the completed grow does not mount"; ct_exit; }
require_cetrafs_mount "$MNT"
NEW_BLOCKS="$(stat -f -c %b "$MNT")"
umount "$MNT"
[ "$NEW_BLOCKS" != "$REC_OLD" ] || { fail "setup: the grow did not change the size ($REC_OLD blocks before and after)"; ct_exit; }
pass "setup: the grow is $((E - B)) writes long between the marks, and takes the volume from $REC_OLD to $NEW_BLOCKS blocks"

# ---- every cut
cuts=0
bad=0
for n in $(seq "$((B + 1))" "$((E + 1))"); do
    cuts=$((cuts + 1))
    if why="$(cut "$REC_LOG" "$n")"; then
        :
    else
        bad=$((bad + 1))
        [ "$bad" -le 5 ] && fail "cut after entry $n: $why"
    fi
done
[ "$cuts" -gt 1 ] && pass "$cuts cuts, one after every write of the grow, were replayed and checked"
[ "$bad" = 0 ] && pass "every cut fscks clean, mounts at the old or the new size, keeps its data, and finishes on rerun" ||
    fail "$bad of $cuts cuts failed a property"

# ---- the control: a grow that publishes over Block Groups it never wrote
record control CETRAFS_GROWFS_TEST_SKIP_BG_HEADERS=1 || { ct_exit; }
B2="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_begin 2>/dev/null || true)"
E2="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_end 2>/dev/null || true)"
blkdiscard "$RDEV" 2>/dev/null || dd if=/dev/zero of="$RDEV" bs=1M status=none 2>/dev/null || true
"$REPLAY" --log "$REC_LOG" --replay "$RDEV" --limit-entries "$((E2 + 1))" 2>/dev/null
blockdev --flushbufs "$RDEV" 2>/dev/null || true
if ct_fsck "$RDEV" >/dev/null 2>&1; then
    fail "control: fsck passed a grow whose new Block Groups were never written -- the cut check cannot discriminate"
else
    pass "control: fsck refuses the completed grow whose new Block Groups were never written"
fi

ct_exit
