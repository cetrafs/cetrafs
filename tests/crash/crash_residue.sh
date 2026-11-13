#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ct-timeout: 3600
# the residue a power cut leaves, counted by class at every barrier of an unsynced workload
#
# LIMITATIONS.md says to expect an offline `fsck.cetra -r` after an
# unclean shutdown, for two residue classes: an orphan inode (a record
# durable while its directory entry was mid-write) and a block
# referenced by an extent but marked FREE in its bitmap. The scrub
# reclaims orphans online; nothing online repairs the second -- and it
# is the dangerous one, since the allocator hands such a block out again
# and two files share it.
#
# This census answers whether the second class is still reachable now
# that cetrafs_alloc_flush_bitmaps() runs before every publish (rule 8).
# dm-log-writes records a workload of creates, writes, closes,
# truncates, punches, fallocates and unlinks with NO sync behind them --
# a real crash does not wait for one -- and a few fsyncs only to put
# barriers inside it. Every barrier between the workload's marks is a
# cut (--limit-fua: everything the device was told to make durable, and
# nothing after it -- what a volatile cache leaves at a power loss), and
# a sample of the writes between barriers too (--limit-entries). At each
# cut the volume is mounted (which replays the journal), unmounted, and
# fsck'd; the residue is counted by class.
#
# The assertions: no cut leaves a block referenced but free; no cut,
# once mounted, leaves a count behind its entries (a directory's size or
# link count, an unlinked inode's link count: the entry is durable before
# the release that publishes the count, and the re-attaching mount
# recounts what a stopped operation's lock still covers --
# cetrafs_ns_reconcile()); and no cut leaves any error outside the known
# residue. Reported, not asserted: orphans and leaked blocks (the scrub
# reclaims both online).
#
# DISCRIMINATION: the control round records the same workload with the
# boundary flush off (alloc_flush_skip=1) and mounts its cuts without the
# recount (lock_sweep_recount_off=1); some cut must then show a block
# referenced but free, and some a count behind, or this census cannot see
# the classes it exists to count.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for m in dm_log_writes; do modprobe "$m" 2>/dev/null || true; done
command -v dmsetup >/dev/null || { skip "dmsetup not found"; ct_exit; }
for k in alloc_flush_skip lock_sweep_recount_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

REPLAY="$CT_BUILD/replay-log"
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || { fail "replay-log build failed"; ct_exit; }
fi

# A replayed image is a crash of this machine: its registry row waits
# out the stale window at every mount. Shrunk, as the other crash suites
# shrink it; the guard still runs at every cut.
ct_param_set hb_interval_secs 1
ct_param_set stale_secs 3
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set alloc_flush_skip 0
ct_param_set lock_sweep_recount_off 0
export CETRAFS_PEER_PROBE_SECS=3

SZ_MB=600
SECT=$((SZ_MB * 2048))
ENTRY_SAMPLES="${RESIDUE_ENTRY_SAMPLES:-60}" # writes between barriers, sampled evenly
MNT="$(ct_mnt residue)"
ct_track mnt "$MNT"
RDEV="$(ct_loop "$(ct_image "$SZ_MB" residue-replay)")"

# The workload: every operation that publishes an extent or frees one.
workload() {
    python3 - "$MNT" <<'PY'
import os, sys, random, ctypes
m = sys.argv[1]
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
def falloc(fd, mode, off, ln):
    if libc.fallocate(fd, mode, off, ln):
        e = ctypes.get_errno(); raise OSError(e, os.strerror(e))
r = random.Random(7)
def wr(p, nblk, fs=False):
    fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o644)
    for b in range(nblk):
        os.pwrite(fd, bytes([r.randrange(256)]) * 4096, b * 4096)
    if fs:
        os.fsync(fd)
    os.close(fd)
os.mkdir(m + "/d")
for i in range(24):
    wr("%s/d/f%d" % (m, i), r.randrange(1, 24), fs=(i % 6 == 5))  # closes publish; a few fsyncs put barriers in
for i in range(0, 24, 3):
    os.truncate("%s/d/f%d" % (m, i), 4096)                          # truncate: publish, then free
for i in range(1, 24, 4):
    fd = os.open("%s/d/f%d" % (m, i), os.O_RDWR)
    falloc(fd, 3, 4096, 8192)                                 # PUNCH_HOLE|KEEP_SIZE
    os.close(fd)
fd = os.open(m + "/pre", os.O_CREAT | os.O_RDWR, 0o644)
falloc(fd, 0, 0, 64 * 4096)                                   # preallocate, then convert parts
for b in range(0, 64, 5):
    os.pwrite(fd, b"P" * 4096, b * 4096)
os.close(fd)
for i in range(2, 24, 5):
    os.unlink("%s/d/f%d" % (m, i))                                  # unlink: frees at evict
wr(m + "/bar", 1, fs=True)                                          # a barrier after the frees
for i in range(24, 36):
    wr("%s/d/f%d" % (m, i), r.randrange(1, 12))                     # reuse of freed space
wr(m + "/bar2", 1, fs=True)
PY
}

# record <tag>: mkfs, then the workload between marks, all through the logger.
record() {
    local tag="$1" dm data log
    data="$(ct_loop "$(ct_image "$SZ_MB" "residue-$tag")")"
    log="$(ct_loop "$(ct_image 512 "residue-log-$tag")")"
    dm="residue_${tag}_$$"
    dmsetup create "$dm" --table "0 $SECT log-writes $data $log"
    ct_track dm "$dm"
    REC_LOG="$log"
    ct_mkfs "/dev/mapper/$dm" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "/dev/mapper/$dm" "$MNT"
    require_cetrafs_mount "$MNT"
    dmsetup message "$dm" 0 mark work_begin
    workload
    dmsetup message "$dm" 0 mark work_end
    ct_umount "$MNT"
    dmsetup remove --retry "$dm"
    blockdev --flushbufs "$log"
}

# census <tag>: cut at every barrier inside the workload and at sampled
# writes; count residue by class. Sets REFD_FREE ORPHANS LEAKS OTHER CUTS.
census() {
    local log="$1" tag="$2" k b0 b1 e0 e1 n step out cut_arg
    REFD_FREE=0; ORPHANS=0; LEAKS=0; DIRLAG=0; OTHER=0; CUTS=0; BAD_MOUNT=0
    e0="$("$REPLAY" --log "$log" --entry-of-mark work_begin)"
    e1="$("$REPLAY" --log "$log" --entry-of-mark work_end)"
    b0="$("$REPLAY" --log "$log" --count-marks | awk '$2=="work_begin"{print $1; exit}')"
    k="$("$REPLAY" --log "$log" --count-fua)"
    b1="$("$REPLAY" --log "$log" --count-marks | awk '$2=="work_end"{print $1; exit}')"
    [ -n "$e0" ] && [ -n "$e1" ] && [ -n "$b0" ] && [ -n "$b1" ] && [ "$b1" -gt "$b0" ] ||
        { fail "$tag: setup: marks not found or no barrier inside the workload (barriers $b0..$b1, entries $e0..$e1)"; return 1; }
    log "$tag: barriers $b0..$b1 of $k, entries $e0..$e1"
    step=$(((e1 - e0) / ENTRY_SAMPLES)); [ "$step" -ge 1 ] || step=1
    {
        for ((n = b0; n <= b1; n++)); do echo "--limit-fua $n"; done
        for ((n = e0 + step; n < e1; n += step)); do echo "--limit-entries $n"; done
    } >"$MNT.cuts"
    while read -r cut_arg; do
        blkdiscard "$RDEV" 2>/dev/null || dd if=/dev/zero of="$RDEV" bs=1M status=none 2>/dev/null || true
        # shellcheck disable=SC2086
        "$REPLAY" --log "$log" --replay "$RDEV" $cut_arg 2>/dev/null || { echo "  $cut_arg: replay failed"; continue; }
        blockdev --flushbufs "$RDEV" 2>/dev/null || true
        CUTS=$((CUTS + 1))
        if mount -t cetrafs "$RDEV" "$MNT" 2>/dev/null; then
            umount "$MNT"
        else
            BAD_MOUNT=$((BAD_MOUNT + 1)); echo "  $cut_arg: the cut volume does not mount"
        fi
        blockdev --flushbufs "$RDEV" 2>/dev/null || true
        out="$("$ROOT/userspace/fsck.cetra" "$RDEV" 2>&1 || true)"
        grep -q "in use but marked free" <<<"$out" && { REFD_FREE=$((REFD_FREE + 1)); echo "  $cut_arg: $(grep -m1 'in use but marked free' <<<"$out")"; }
        grep -q "(orphan)" <<<"$out" && ORPHANS=$((ORPHANS + 1))
        grep -q "(leaked)" <<<"$out" && LEAKS=$((LEAKS + 1))
        # A directory whose size or link count lags its entries: an entry
        # made durable before the record that counts it. And its mirror:
        # an unlink whose entry removal is durable before the target's
        # link count, leaving an inode no name reaches. The mount above
        # recounts both (cetrafs_ns_reconcile()).
        LAG='^ERR: directory inode [0-9]+ has size [0-9]+ but holds|has nlink=[0-9]+ but contains|is allocated \(nlink=[0-9]+\) but NO directory entry names it'
        grep -qE "$LAG" <<<"$out" && { DIRLAG=$((DIRLAG + 1)); grep -E "$LAG" <<<"$out" | sed "s|^|  $cut_arg: |"; }
        # Any other error. The referenced-but-free class reports itself
        # twice (the count, then each block).
        KNOWN="in use but marked free|referenced by an inode but marked FREE|$LAG"
        if grep "^ERR" <<<"$out" | grep -vqE "$KNOWN"; then
            OTHER=$((OTHER + 1))
            grep '^ERR' <<<"$out" | grep -vE "$KNOWN" | sed "s|^|  $cut_arg: |"
        fi
    done <"$MNT.cuts"
    rm -f "$MNT.cuts"
    log "$tag: $CUTS cuts: referenced-but-free $REFD_FREE, orphan $ORPHANS, leaked $LEAKS, count lag (directory size, link count) $DIRLAG, other ERR $OTHER, unmountable $BAD_MOUNT"
}

# RESIDUE_SKIP_CONTROL=1 is for iterating on the main round only; a run
# without the control proves nothing about what the census can see.
if [ "${RESIDUE_SKIP_CONTROL:-0}" != 1 ]; then
    log "control: the workload recorded with the boundary bitmap flush OFF"
    ct_param_set alloc_flush_skip 1
    record ctl
    ct_param_set alloc_flush_skip 0
    ct_param_set lock_sweep_recount_off 1
    census "$REC_LOG" control || ct_exit
    ct_param_set lock_sweep_recount_off 0
    [ "$REFD_FREE" -gt 0 ] &&
        pass "control: without the flush $REFD_FREE of $CUTS cuts leave a block referenced but free -- the census sees the class" ||
        fail "control: without the flush no cut left a block referenced but free -- the census cannot see the class"
    [ "$DIRLAG" -gt 0 ] &&
        pass "control: without the recount $DIRLAG of $CUTS cuts leave a count behind its entries -- the census sees the class" ||
        fail "control: without the recount no cut left a count behind -- the census cannot see the class"
else
    fail "control skipped (RESIDUE_SKIP_CONTROL=1): this run cannot show the census sees the class"
fi

log "main: the same workload with the flush"
record main
census "$REC_LOG" main || ct_exit
[ "$CUTS" -gt 0 ] || fail "main: setup: no cut was examined"
[ "$REFD_FREE" = 0 ] && pass "main: no cut of $CUTS leaves a block referenced but free" ||
    fail "main: $REFD_FREE of $CUTS cuts leave a block referenced but free"
[ "$DIRLAG" = 0 ] && pass "main: no cut of $CUTS, once mounted, leaves a count behind its entries" ||
    fail "main: $DIRLAG of $CUTS cuts leave a count behind its entries after the mount"
[ "$OTHER" = 0 ] && [ "$BAD_MOUNT" = 0 ] && pass "main: every cut mounts and has no other fsck error" ||
    fail "main: $OTHER cut(s) with another fsck error, $BAD_MOUNT unmountable"
log "main residue (reported, not asserted): orphan at $ORPHANS cut(s), leaked blocks at $LEAKS"
ct_exit
