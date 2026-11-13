#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ct-timeout: 7200
# a power cut at any write of a LIVE grow, with the kernel publishing, leaves a volume that mounts, fscks, and finishes
#
# growfs_crash.sh cuts an OFFLINE grow after every write. A live grow is
# different in exactly the place a cut is most likely to matter: growfs
# writes the new Block Groups and the table segment itself, then the
# KERNEL credits the pool shards, links the segment from the old tail
# (a second or later grow only) and publishes the superblock
# (CETRAFS_IOC_GROW, kmod/grow.c). Those are compare-and-swaps issued by a
# mounted node whose heartbeat and registry writes are in flight around
# them. grow_live_crash.sh abandons the grow after the first two by a test
# knob; this suite does not abandon anything. It records the whole live
# grow through dm-log-writes on a mounted volume and cuts between every
# write of it.
#
# Two windows are recorded, because the link is written only on a second
# grow:
#   first   a grow of a fresh volume: credits, then publish;
#   second  a grow of a volume that a live grow already took to the
#           intermediate size: credits, link, then publish.
#
# Mechanism, as growfs_crash.sh: a volume with a file written before the
# grow is mounted on the logged device; a mark, the live grow, a mark, an
# unmount. replay-log then replays the log onto a scratch device up to
# EVERY write between the two marks (--limit-entries: between bios, not
# only at barriers).
#
# The window starts from a clean boundary: the file's allocations leave
# Block Group free counts dirty in the node's memory until a durability
# boundary applies them (PERFORMANCE.md invariant 4), so a raw crash image
# there carries a count that lags its bitmap. That lag belongs to the file
# write, not to the grow, so the recording unmounts and remounts before
# the first mark, and the setup asserts that the state at the mark fscks
# clean. Inside the window nothing is flushed: every write the grow issues
# is cut without a barrier of the rig's own.
#
# At every cut:
#   - fsck either exits 0 (the link note of an unpublished segment is
#     fine), or names ONLY a live grow's pool credit that never published,
#     the state grow_live_crash.sh's step 1 documents and the mount takes
#     back (cetrafs_grow_heal_pool()). Anything else is damage;
#   - the volume mounts, at the OLD size or the NEW one only, and the
#     file written before the grow reads back intact;
#   - a live growfs run on that mount finishes the grow when the cut left
#     it at the old size, reaching the NEW size with the data intact;
#   - once unmounted, fsck is clean, and the volume mounts at the NEW size.
#
# DISCRIMINATION: CETRAFS_GROWFS_TEST_SKIP_BG_HEADERS makes growfs write
# none of the new Block Groups' headers, and grow_hdr_check_off lets the
# kernel publish over them anyway (the commit refuses them otherwise:
# cetrafs_grow_check_bg_header(), tests/kernel/grow_live_bg_header.sh --
# found by this control). The control
# records that and finds the publish entry itself (the one write in the
# window that changes block 0). The cut just before it must pass, and the
# cut at it must be refused -- so the checks above are not ones every
# image passes, and the failure is the publish.
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

# As growfs_crash.sh: a replayed image is a crash of this machine, its
# registry rows are stale, and the waits are shrunk to keep a cut cheap.
ct_param_set hb_interval_secs 1
ct_param_set stale_secs 3
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CETRAFS_PEER_PROBE_SECS=3

# A Block Group is 512 MiB, and growfs refuses to add less than one, so
# each grow here adds whole Block Groups: first 1 -> 2 (600 -> 1200 MiB),
# then 2 -> 3 (1200 -> 1800 MiB). The device holds the largest.
BIG_MB=1800
SECT=$((BIG_MB * 2048))
NEW_MB=0 # set per window
MNT="$(ct_mnt growlive)"
ct_track mnt "$MNT"
RDEV="$(ct_loop "$(ct_big_image "$BIG_MB" growlive-replay)")"

# record <tag> <old_mb> <pre_mb> [VAR=value ...]: mkfs at old_mb, mount, a
# file, then (when pre_mb is set) a live grow to pre_mb, a clean remount, a
# mark, the LIVE grow to NEW_MB, a mark, and an unmount. Sets REC_LOG (the
# log device), REC_OLD (the size the window starts from, in blocks,
# measured while mounted) and REC_SUM (the checksum of the file written
# before the grow).
record() {
    local tag="$1" old_mb="$2" pre_mb="$3" dm data log
    shift 3
    data="$(ct_loop "$(ct_big_image "$BIG_MB" "growlive-$tag")")"
    log="$(ct_loop "$(ct_image 512 "growlive-log-$tag")")"
    dm="growlive_${tag}_$$"
    dmsetup create "$dm" --table "0 $SECT log-writes $data $log"
    ct_track dm "$dm"
    REC_LOG="$log"
    ct_mkfs "/dev/mapper/$dm" -s "${old_mb}M" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "/dev/mapper/$dm" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/keep" bs=4096 count=64 conv=fsync status=none
    REC_SUM="$(sha256sum <"$MNT/keep")"
    if [ "$pre_mb" != 0 ]; then
        if ! ct_growfs "/dev/mapper/$dm" -s "${pre_mb}M" >"$MNT.pre.out" 2>&1; then
            fail "$tag: setup: the live grow to $pre_mb MiB that the window starts from failed: $(tail -1 "$MNT.pre.out")"
            ct_umount "$MNT" || true
            return 1
        fi
    fi
    # The clean boundary (see the header): unmount, then mount again.
    ct_umount "$MNT"
    ct_mount "/dev/mapper/$dm" "$MNT"
    require_cetrafs_mount "$MNT"
    REC_OLD="$(stat -f -c %b "$MNT")"

    dmsetup message "$dm" 0 mark grow_begin
    if ! env "$@" "$ROOT/userspace/growfs.cetra" "/dev/mapper/$dm" -s "${NEW_MB}M" >"$MNT.grow.out" 2>&1; then
        fail "$tag: setup: the recorded live grow failed: $(tail -1 "$MNT.grow.out")"
        ct_umount "$MNT" || true
        return 1
    fi
    grep -q 'completed live' "$MNT.grow.out" || { fail "$tag: setup: the recorded grow was not a live one: $(tail -1 "$MNT.grow.out")"; ct_umount "$MNT" || true; return 1; }
    dmsetup message "$dm" 0 mark grow_end
    ct_umount "$MNT"
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

# dead_credit_only <fsck output>: every ERR names a pool shard, and one of
# them is a live grow's credit that never published (grow_live_crash.sh).
dead_credit_only() {
    local errs other
    errs="$(grep '^ERR' <<<"$1" || true)"
    [ -n "$errs" ] || return 1
    grep -q 'never published' <<<"$errs" || return 1
    other="$(grep -v 'pool' <<<"$errs" || true)"
    [ -z "$other" ]
}

# cut <log> <entries>: replay to that cut and check the properties above.
# Prints one line per failed property; returns 0 when all of them hold.
# Appends one tally line per cut to $TALLY (a cut runs in a subshell, so
# the counts travel through the file).
cut() {
    local log="$1" n="$2" out size keep rc=0 pre="clean" link=""

    replay_to "$log" "$n" || { echo "replay failed at entry $n"; return 1; }

    if ! out="$(ct_fsck "$RDEV" 2>&1)"; then
        if dead_credit_only "$out"; then
            pre="dead-credit"
        else
            echo "fsck: $(grep -m1 -E 'ERR|error|damage' <<<"$out" || echo 'nonzero exit')"
            rc=1
        fi
    fi
    grep -q '^note: the Block Group table links' <<<"$out" && link="+link"

    if ! mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null; then
        echo "mount: the cut volume does not mount"
        echo "pre=$pre$link size=unmounted" >>"$TALLY"
        return 1
    fi
    size="$(stat -f -c %b "$MNT")"
    keep="$(sha256sum <"$MNT/keep" 2>/dev/null || echo missing)"
    if [ "$size" != "$REC_OLD" ] && [ "$size" != "$NEW_BLOCKS" ]; then
        echo "size: mounted at $size blocks, neither the old $REC_OLD nor the new $NEW_BLOCKS"
        rc=1
    fi
    [ "$keep" = "$REC_SUM" ] || { echo "data: the file written before the grow does not read back"; rc=1; }
    echo "pre=$pre$link size=$([ "$size" = "$NEW_BLOCKS" ] && echo new || echo old)" >>"$TALLY"

    # The kernel's publish is the live grow's last write: a cut left at
    # the old size is finished by growfs on that same mount, live.
    if [ "$size" = "$REC_OLD" ]; then
        if ! out="$(ct_growfs "$RDEV" -s "${NEW_MB}M" 2>&1)"; then
            echo "finish: the live growfs refuses to finish the grow it was cut out of: $(tail -1 <<<"$out")"
            rc=1
        fi
        size="$(stat -f -c %b "$MNT")"
        [ "$size" = "$NEW_BLOCKS" ] || { echo "finish: the rerun left the volume at $size blocks"; rc=1; }
        [ "$(sha256sum <"$MNT/keep" 2>/dev/null || echo missing)" = "$REC_SUM" ] ||
            { echo "finish: the file written before the grow does not read back after the rerun"; rc=1; }
    fi
    umount "$MNT" || { echo "finish: the volume does not unmount"; return 1; }

    if ! out="$(ct_fsck "$RDEV" 2>&1)"; then
        echo "finish: fsck after the finish: $(grep -m1 -E 'ERR|error|damage' <<<"$out" || echo 'nonzero exit')"
        rc=1
    fi
    if mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null; then
        [ "$(stat -f -c %b "$MNT")" = "$NEW_BLOCKS" ] || { echo "finish: the finished grow does not mount at the new size"; rc=1; }
        umount "$MNT"
    else
        echo "finish: the finished grow does not mount"
        rc=1
    fi
    return "$rc"
}

# new_size_of_completed: the NEW size in blocks, measured on the replay of
# the whole window (E + 1), so every cut is compared to a measured value.
new_size_of_completed() {
    replay_to "$REC_LOG" "$((E + 1))" || return 1
    ct_fsck "$RDEV" >/dev/null 2>&1 || return 1
    mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null || return 1
    require_cetrafs_mount "$MNT"
    stat -f -c %b "$MNT"
    umount "$MNT"
}

# window <tag> <old_mb> <pre_mb> <new_mb>: record one live grow, then cut
# between its marks. Sets the globals every cut is compared against.
window() {
    local tag="$1" old_mb="$2" pre_mb="$3" B E cuts=0 bad=0 n why TALLIED
    NEW_MB="$4"
    TALLY="$MNT.tally.$tag"
    rm -f "$TALLY"

    log "[$tag] recording a live grow to $NEW_MB MiB, mounted, through dm-log-writes, from $([ "$pre_mb" = 0 ] && echo "$old_mb" || echo "$pre_mb") MiB"
    record "$tag" "$old_mb" "$pre_mb" || return 1
    B="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_begin 2>/dev/null || true)"
    E="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_end 2>/dev/null || true)"
    case "$B$E" in
    "" | *[!0-9]*) fail "[$tag] setup: the log does not carry both grow marks (begin='$B' end='$E')"; return 1 ;;
    esac
    [ "$E" -gt "$B" ] || { fail "[$tag] setup: the grow wrote nothing between its marks ($B..$E)"; return 1; }

    # The window must start clean, or a failure inside it could be the file
    # write's count lag rather than anything the grow did (see the header).
    replay_to "$REC_LOG" "$B" || { fail "[$tag] setup: the state at the grow_begin mark does not replay"; return 1; }
    ct_fsck "$RDEV" >/dev/null 2>&1 || { fail "[$tag] setup: the state at the grow_begin mark does not fsck clean: $(ct_fsck "$RDEV" 2>&1 | grep -m1 ERR)"; return 1; }
    pass "[$tag] setup: the state the grow starts from fscks clean, at $REC_OLD blocks"

    # The completed grow fixes the NEW size, which every cut is compared to.
    NEW_BLOCKS="$(new_size_of_completed)" || { fail "[$tag] setup: the completed grow does not replay, fsck clean and mount"; return 1; }
    [ "$NEW_BLOCKS" != "$REC_OLD" ] || { fail "[$tag] setup: the grow did not change the size ($REC_OLD blocks before and after)"; return 1; }
    pass "[$tag] setup: the live grow is $((E - B)) writes long between the marks, and takes the volume from $REC_OLD to $NEW_BLOCKS blocks"

    for n in $(seq "$((B + 1))" "$((E + 1))"); do
        cuts=$((cuts + 1))
        if why="$(cut "$REC_LOG" "$n")"; then
            :
        else
            bad=$((bad + 1))
            [ "$bad" -le 5 ] && fail "[$tag] cut after entry $n: $why"
        fi
    done
    TALLIED="$(sort "$TALLY" | uniq -c | awk '{ printf "%s%s x%s", (NR > 1 ? ", " : ""), $2 " " $3, $1 }')"
    [ "$cuts" -gt 1 ] && pass "[$tag] $cuts cuts, one after every write of the live grow, were replayed and checked ($TALLIED)"
    [ "$bad" = 0 ] && pass "[$tag] every cut fscks clean (or names only a dead live grow's pool credit), mounts at the old or the new size, keeps its data, and finishes on a live rerun" ||
        fail "[$tag] $bad of $cuts cuts failed a property"
    if [ "$pre_mb" != 0 ]; then
        grep -q '+link' "$TALLY" && pass "[$tag] the window covers the link: a cut with the new segment linked and not published" ||
            fail "[$tag] no cut in the window has the new segment linked -- the second grow did not link from the tail"
    fi
    return 0
}

# ---- the windows
rm -f "$MNT".tally.*
window first 600 0 1200 || true
GOOD_1200="${NEW_BLOCKS:-}"
window second 600 1200 1800 || true

# ---- the control: a live grow that publishes over Block Groups nobody wrote.
# Its size is the first window's measured 1200 MiB grow (the same geometry).
NEW_MB=1200
NEW_BLOCKS="$GOOD_1200"
[ -n "$NEW_BLOCKS" ] || { fail "control: setup: the first window measured no new size"; ct_exit; }
TALLY="$MNT.tally.control"
rm -f "$TALLY"
ct_param_set grow_hdr_check_off 1
rec_ok=0
record control 600 0 CETRAFS_GROWFS_TEST_SKIP_BG_HEADERS=1 && rec_ok=1
ct_param_set grow_hdr_check_off 0
if [ "$rec_ok" = 1 ]; then
    B2="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_begin 2>/dev/null || true)"
    E2="$("$REPLAY" --log "$REC_LOG" --entry-of-mark grow_end 2>/dev/null || true)"
    case "$B2$E2" in
    "" | *[!0-9]*) fail "control: setup: the log does not carry both grow marks" ;;
    *)
        # The publish is the one write in the window that changes block 0:
        # find it by replaying one entry at a time and reading block 0
        # (no mount, no fsck). Cut just before it is a grow that never
        # published.
        PUB=""
        prev="$(replay_to "$REC_LOG" "$B2" && dd if="$RDEV" bs=4096 count=1 iflag=direct status=none | md5sum)"
        for n in $(seq "$((B2 + 1))" "$((E2 + 1))"); do
            cur="$(replay_to "$REC_LOG" "$n" && dd if="$RDEV" bs=4096 count=1 iflag=direct status=none | md5sum)"
            if [ "$cur" != "$prev" ]; then
                PUB="$n"
                break
            fi
            prev="$cur"
        done
        case "$PUB" in
        "" | *[!0-9]*) fail "control: no write in the window changes block 0 -- the publish was not recorded" ;;
        *)
            # NEW_BLOCKS is the second window's: the same geometry, so the
            # same size in blocks.
            if why="$(cut "$REC_LOG" "$((PUB - 1))")"; then
                pass "control: the cut just before the publish (entry $((PUB - 1))) passes -- a grow that never published"
            else
                fail "control: the cut before the publish fails ($why) -- the recording is not what the control says"
            fi
            if why="$(cut "$REC_LOG" "$PUB")"; then
                fail "control: the cut at the publish (entry $PUB) passes -- the cut check cannot discriminate"
            else
                pass "control: the cut at the publish (entry $PUB) is caught: $why"
            fi
            ;;
        esac
        ;;
    esac
else
    fail "control: the recording over unwritten Block Groups failed"
fi

ct_exit
