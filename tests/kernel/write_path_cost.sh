#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The COST of the write path, not just its correctness.
#
# Every bug this guards against was a performance collapse that passed
# every functional test in the suite. A VM went from 480 MB/s to 5, and
# nothing was "wrong" -- the data was correct, fsck was clean, dmesg was
# silent. The only way to catch that class is to assert on counters that
# say how much work a write costs, so each check below is a ratio or a
# delta, never "did it succeed".
#
# Guards, in commit order:
#   62e245f  an uninit convert must not journal the leaf per 4 KiB write
#   bdf0bee  a freshly allocated block must not be journalled at all
#   97c64fa  "which BG holds this LBA" must be O(1), not a table scan
#   82df5bb  reading procfs info must not re-sweep every BG descriptor
#   d1a6192  pending frees must drain on demand, not only per heartbeat
#   0107654  a split with one free slot must grow the tree, not free blocks
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 2200 wpcost)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt wpcost)"
PD="$(basename "$DEV")"
# Small Block Groups on purpose: bg_geom_reads can only tell an O(1)
# lookup from a table scan if there are many BGs to scan.
ct_mkfs "$DEV" -z 4 -J 4 -M 4 -N 2048 -f >/dev/null
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

c() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }

prealloc() { # $1 path  $2 bytes
    python3 -c 'import os,ctypes,sys
l=ctypes.CDLL("libc.so.6",use_errno=True)
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o644)
sys.exit(0 if l.fallocate(fd,0,ctypes.c_long(0),ctypes.c_long(int(sys.argv[2])))==0 else 3)' "$1" "$2"
}

# ---------------------------------------------------------------- 1
# A write into preallocated space converts an uninit extent. Journalling
# that leaf costs three device cache flushes and two synchronous writes
# EACH TIME: on the deployment SAN it was 6.8 IOPS and 147 ms per 4 KiB
# write. The leaf is a regular file's, so it belongs to the next
# durability boundary, not to the journal.
log "an uninit convert must not journal the leaf on every write"
P="$MNT/prealloc.bin"
prealloc "$P" $((96 * 1024 * 1024)) || { log "fallocate unsupported here"; ct_umount "$MNT"; ct_exit; }
# The file must reach DEPTH >= 1 (external leaf blocks) or this measures
# nothing: a single preallocated extent stays inline in the record, the
# convert never touches a leaf buffer, and there is nothing to journal.
# The first version of this check wrote sequentially into one extent and
# passed even with the old per-write journalling restored -- a test that
# could not fail. Every other block, so each write SPLITS.
J0="$(c journal_writes)"; T0="$(c tree_blocks)"
python3 - "$P" <<'PY2'
import os, sys, ctypes
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a); mv[:] = b"z" * 4096
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
for i in range(2000):
    os.pwrite(fd, mv, i * 8192)
os.fsync(fd); os.close(fd)
PY2
sync
J1="$(c journal_writes)"
JD=$((J1 - J0))
# filefrag COALESCES, so it cannot tell you whether the tree spilled
# out of the record's 4 inline slots. tree_blocks counts external
# leaf/interior blocks actually written, which is the real question.
TD=$(( $(c tree_blocks) - T0 ))
[ "$TD" -gt 0 ] &&
    pass "cost: the file wrote $TD external tree block(s), so leaves are in play" ||
    fail "cost: no external tree blocks -- still inline, this measures nothing"
[ "$JD" -lt 200 ] &&
    pass "cost: 2000 splitting writes cost $JD journal entries (<200)" ||
    fail "cost: 2000 splitting writes cost $JD journal entries -- journalling per write"

# ---------------------------------------------------------------- 2
# A brand-new leaf/index block is unreferenced at crash time, so replay
# SKIPS its entry (F_FRESH) -- writing one is pure cost. This was 1891
# of 1907 cache flushes for twenty 4 KiB writes.
log "growing a file must not journal its freshly allocated blocks"
J0="$(c journal_writes)"
dd if=/dev/zero of="$MNT/grow.bin" bs=1M count=200 oflag=direct status=none
sync
J1="$(c journal_writes)"
JD=$((J1 - J0))
[ "$JD" -lt 50 ] &&
    pass "cost: writing 200 MiB cost $JD journal entries (<50)" ||
    fail "cost: writing 200 MiB cost $JD journal entries -- fresh blocks are being journalled"

rm -f "$MNT/grow.bin"
sync

# ---------------------------------------------------------------- 4
# Every read of this file used to invalidate every foreign descriptor,
# so anything polling it (the Proxmox storage plugin) kept the whole
# volume cold. bg_desc_refreshed climbed 3840 -> 13440 in minutes.
log "reading procfs info repeatedly must not re-sweep the descriptors"
cat "/proc/fs/cetrafs/$PD/info" >/dev/null
R0="$(c bg_desc_refreshed)"
for _ in 1 2 3 4 5; do cat "/proc/fs/cetrafs/$PD/info" >/dev/null; done
R1="$(c bg_desc_refreshed)"
RD=$((R1 - R0))
[ "$RD" -eq 0 ] &&
    pass "cost: five further info reads re-swept $RD descriptors (rate limit holding)" ||
    fail "cost: five info reads re-swept $RD descriptors -- the sweep is unthrottled"

# ---------------------------------------------------------------- 5
# A peer's frees land in our queue and only we can apply them. Draining
# only on the heartbeat let a burst overflow and STAY overflowed, so
# every further free leaked at ~6.5 ms each. The allocation path drains
# on demand now; with the heartbeat pushed out of the way, any drain we
# see must have come from that path.
log "pending frees must drain from the allocation path, not only per heartbeat"
# Push the heartbeat out of the way so any drain we see came from the
# allocation path, and pin the rate limit rather than racing it: the
# first version of this test wrote 100 MiB in 0.2s and never left the
# 500 ms window, so it failed for timing reasons rather than for the
# behaviour it was meant to check.
ct_param_set hb_interval_secs 30
ct_param_set pf_drain_min_ms 0
D0="$(c pf_drains)"
dd if=/dev/zero of="$MNT/drain.bin" bs=1M count=100 oflag=direct status=none
sync
D1="$(c pf_drains)"
DD=$((D1 - D0))
[ "$DD" -gt 0 ] &&
    pass "cost: allocating drove $DD drain pass(es) without waiting for a heartbeat" ||
    fail "cost: no drain ran while allocating -- the hook is not on the allocation path"

# Negative control: with the rate limit pinned high, the same workload
# must drive NONE. Without this the check above would pass against code
# that drained unconditionally from somewhere else entirely.
ct_param_set pf_drain_min_ms 600000
D0="$(c pf_drains)"
dd if=/dev/zero of="$MNT/drain2.bin" bs=1M count=100 oflag=direct status=none
sync
D1="$(c pf_drains)"
ct_param_set pf_drain_min_ms 500
ct_param_set hb_interval_secs 15
DD2=$((D1 - D0))
[ "$DD2" -eq 0 ] &&
    pass "cost: negative control -- rate limit pinned high drove $DD2 drains" ||
    fail "cost: rate limit ignored: $DD2 drains with the gap pinned to 10 minutes"

# ---------------------------------------------------------------- 6
# A middle split needs two free slots. With one, the code released the
# tail -- up to 193 single-block frees per write, ~55 ms each -- and it
# could never stop, because giving the tail back does not free the SLOT
# the next split needs. It must put the tail in the slot and grow the
# tree instead.
log "splitting preallocated extents must grow the tree, not release blocks"
B0="$(c giveback_blocks)"
F="$MNT/frag.bin"
prealloc "$F" $((96 * 1024 * 1024))
python3 - "$F" <<'PY'
import os, sys, ctypes
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a); mv[:] = b"z" * 4096
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
# Every other block, so each write splits an extent in the MIDDLE --
# the shape that wants two slots and used to give the tail back.
for i in range(3000):
    os.pwrite(fd, mv, i * 8192)
os.fsync(fd); os.close(fd)
PY
B1="$(c giveback_blocks)"
BD=$((B1 - B0))
[ "$BD" -lt 500 ] &&
    pass "cost: 3000 middle splits released $BD preallocated block(s) (<500)" ||
    fail "cost: 3000 middle splits released $BD preallocated block(s) -- the tree is not growing"

# ------------------------------------------------- 8
# A lookup must not scale with the file's fragmentation.
#
# The extent arrays are append-only and unordered, so a depth-2 lookup
# used to read EVERY leaf until it hit. On a 32 GiB VM image fragmented
# to 28,659 extents -- ~113 leaves -- that is ~56 leaf reads per mapped
# BLOCK, and it is why the same file served 480 MB/s at 443 extents and
# 90 MB/s at 28k. cetrafs_extent_idx_t.ei_block_end bounds each child's
# logical range so the walk skips what cannot hold the block.
log "a lookup must not scale with the number of leaves"
FR="$MNT/lookupcost.bin"
prealloc "$FR" $((192 * 1024 * 1024))
python3 - "$FR" <<'PY3'
import os, sys, ctypes
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a); mv[:] = b"f" * 4096
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
# Every other block: each write splits, so the tree fragments hard and
# spills across many leaves -- the condition under test.
for i in range(12000):
    os.pwrite(fd, mv, i * 8192)
os.fsync(fd); os.close(fd)
PY3
sync
TB="$(c tree_blocks)"
# Now read single blocks scattered across the whole file and count how
# many tree blocks each lookup had to read.
echo 3 > /proc/sys/vm/drop_caches
R0="$(c tree_reads)"
python3 - "$FR" <<'PY3'
import os, sys, ctypes
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
for i in range(0, 12000, 120):          # 100 scattered reads
    os.preadv(fd, [mv], i * 8192)
os.close(fd)
PY3
R1="$(c tree_reads)"
RD=$((R1 - R0))
PER=$((RD / 100))
log "  ($TB external tree blocks exist; $RD tree reads for 100 scattered lookups)"
[ "$TB" -gt 8 ] &&
    pass "lookup cost: the file spans $TB external tree blocks, enough to expose a scan" ||
    fail "lookup cost: only $TB external tree blocks -- this measures nothing"
[ "$PER" -lt 8 ] &&
    pass "lookup cost: $PER tree block read(s) per lookup across $TB blocks" ||
    fail "lookup cost: $PER tree block reads per lookup across $TB blocks -- still scanning"

# Negative control: with the range bound ignored, the SAME lookups must
# read many more tree blocks. Without this the check above would pass
# against a build whose tree simply had few leaves.
ct_param_set idx_range_ignore 1
echo 3 > /proc/sys/vm/drop_caches
R0="$(c tree_reads)"
python3 - "$FR" <<'PY4'
import os, sys, ctypes
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
for i in range(0, 12000, 120):
    os.preadv(fd, [mv], i * 8192)
os.close(fd)
PY4
R1="$(c tree_reads)"
ct_param_set idx_range_ignore 0
SCAN=$(( (R1 - R0) / 100 ))
[ "$SCAN" -gt "$PER" ] &&
    pass "lookup cost: negative control scans $SCAN blocks per lookup against $PER with the bound" ||
    fail "lookup cost: negative control read $SCAN per lookup, not more than $PER -- the bound is not what is saving us"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "cost: fsck clean after the whole workload" ||
    fail "cost: fsck found damage"

# ---------------------------------------------------------------- 7
# "Which Block Group holds this LBA" used to scan the whole table,
# reading and CRC32C-ing every descriptor -- 2047 per call on the
# deployment LUN, 1.3-2.7 ms measured, on the FREE path. A loop image
# cannot hold enough Block Groups to tell a scan from O(1) (the minimum
# BG is 512 MiB), so this needs the sparse huge device.
log "a free must not scan the Block Group table (needs many BGs)"
HUGE="$(ct_huge_dev 1 wpbg)"
if [ -z "$HUGE" ]; then
    log "device-mapper unavailable -- cannot build a many-BG volume, skipping"
else
    HMNT="$(ct_mnt wpbg)"
    ct_mkfs "$HUGE" -z 16 -J 2 -M 4 -N 2048 -f >/dev/null
    mount -t cetrafs -o nofilelock "$HUGE" "$HMNT"
    HPD="$(basename "$(readlink -f "$HUGE")")"
    hc() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$HPD/info"; }
    HBGC="$(hc block_group_count)"
    [ "${HBGC:-0}" -ge 256 ] &&
        pass "cost: huge volume has $HBGC Block Groups, enough to expose a scan" ||
        fail "cost: only ${HBGC:-0} Block Groups -- a table scan would look O(1) here"
    dd if=/dev/zero of="$HMNT/f.bin" bs=1M count=8 oflag=direct status=none
    sync
    # Reading procfs info sums free space over EVERY Block Group, so a
    # counter read itself costs one geom read per BG. Measure that
    # baseline and subtract it, or the test just measures itself --
    # which is exactly what it did on the first run.
    BA="$(hc bg_geom_reads)"; BB="$(hc bg_geom_reads)"
    BASE=$((BB - BA))
    G0="$(hc bg_geom_reads)"
    rm -f "$HMNT/f.bin"
    sync
    G1="$(hc bg_geom_reads)"
    GD=$((G1 - G0 - BASE))
    [ "$GD" -lt 0 ] && GD=0
    log "  (one procfs read costs $BASE geom reads; subtracted)"
    # A scan is one read per BG per lookup; O(1) is a handful total.
    [ "$GD" -lt $((HBGC / 4)) ] &&
        pass "cost: freeing took $GD descriptor reads against a $HBGC-entry table" ||
        fail "cost: freeing took $GD descriptor reads against a $HBGC-entry table -- still scanning"
    ct_umount "$HMNT"
fi
ct_exit
