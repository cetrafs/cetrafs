#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Crash consistency: cut power at every durability boundary and prove
# cetrafs still mounts, fscks clean, and kept what it acknowledged.
#
# This is the one correctness property nothing else here exercises. The
# journal (journal.c), publish-before-free (truncate/punch/defrag),
# block-valid-before-reachable (dir growth) and fsync durability are
# all reasoned and reviewed but never faced an actual crash -- only
# journal_poke simulating a single hand-built state.
#
# Mechanism (the xfstests dm-log-writes method): stack
#   loop(data) -> dm-log-writes(records every bio + FLUSH/FUA) -> cetrafs
# mkfs and run a workload THROUGH it so every write, in order, with its
# barriers, lands in a log device. Then replay the log onto a scratch
# device up to a chosen point -- the scratch is then byte-for-byte what
# the platter would hold had power been cut right there -- mount cetrafs
# (which replays its own journal), fsck, and verify. tests/crash/replay-log
# is the small replayer; the log format is reconstructed in its header.
#
# Five phases:
#   1. recoverability -- replay to EVERY FLUSH/FUA after mkfs, mount, fsck
#      ERR-free. Many barriers land mid-journal-operation, so this is the
#      real test of journal replay.
#   2. durability -- replay to each named checkpoint (a completed fsync)
#      and verify every byte acknowledged up to it is present and correct.
#   3. dm-flakey -- the cheap complement: drop all writes from an instant
#      on (power loss), remount, fsck, and the pre-crash fsync'd data is
#      intact.
#   4. ordering flushes emitted -- a journaled op must advance the barrier
#      count by >= 2 (its two blkdev_issue_flush ordering barriers).
#   5. reorder-replay -- model a volatile-cache power cut: drop the crash
#      window's journal, tear its journaled target block, and the journal
#      (durable in an earlier window, thanks to the flush) must restore it.
#
# Opt-in, loop-backed, slower than `make check` -- not part of it. Needs
# dm-log-writes and dm-flakey (modprobe'd below).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm-log-writes 2>/dev/null || true
modprobe dm-flakey 2>/dev/null || true
command -v dmsetup >/dev/null || fail "dmsetup not found"

REPLAY="$CT_BUILD/replay-log"
RESTAMP="$CT_BUILD/fuzz_restamp"   # reused only to read the SB geometry (phase 5)
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || fail "replay-log build failed"
fi
if [ ! -x "$RESTAMP" ] || [ "$ROOT/tests/fuzz/fuzz_restamp.c" -nt "$RESTAMP" ] || [ "$ROOT/include/cetrafs.h" -nt "$RESTAMP" ]; then
    cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
        -o "$RESTAMP" "$ROOT/tests/fuzz/fuzz_restamp.c" || fail "fuzz_restamp build failed"
fi

SZ_MB=560
SECTORS=$((SZ_MB * 1024 * 1024 / 512))
MKFS_ARGS="-z 1 -b 512 -J 4 -M 4 -N 1024 -f"

DATA_IMG="$(ct_image "$SZ_MB" crashdata)"
LOG_IMG="$(ct_image 512 crashlog)"
REPLAY_IMG="$(ct_image "$SZ_MB" crashreplay)"
DATA="$(ct_loop "$DATA_IMG")"
LOG="$(ct_loop "$LOG_IMG")"
RLOOP="$(ct_loop "$REPLAY_IMG")"
DM="crashlw_$$"
dmsetup create "$DM" --table "0 $SECTORS log-writes $DATA $LOG"
ct_track dm "$DM"
LW="/dev/mapper/$DM"
MNT="$(ct_mnt crash)"

mark() { dmsetup message "$DM" 0 mark "$1"; }
zero_replay() { blkdiscard "$RLOOP" 2>/dev/null || dd if=/dev/zero of="$RLOOP" bs=1M status=none; }

# Verify helpers (heredoc python -- no nested-quote fragility). Each is run
# against a freshly recovered mount at $MNT and exits 0 iff the checkpoint's
# acknowledged state is present.
v_cp_file() { python3 - "$MNT" <<'PY'
import os,sys
m=sys.argv[1]; p=m+"/f1"
ok = os.path.exists(p) and os.path.getsize(p)==8192 and os.pread(os.open(p,os.O_RDONLY),8192,0)==b"A"*8192
sys.exit(0 if ok else 1)
PY
}
v_cp_dirgrow() { c=$(ls "$MNT"/dir_* 2>/dev/null | wc -l); [ "$c" = 120 ]; }
v_cp_deep() { python3 - "$MNT" <<'PY'
import os,sys
fd=os.open(sys.argv[1]+"/deep",os.O_RDONLY)
ok=all(os.pread(fd,4096,i*2*4096)==bytes([i&255])*4096 for i in range(12))
os.close(fd); sys.exit(0 if ok else 1)
PY
}
v_cp_trunc() { python3 - "$MNT" <<'PY'
import os,sys; sys.exit(0 if os.path.getsize(sys.argv[1]+"/f1")==4096 else 1)
PY
}
v_cp_rename() { [ -e "$MNT/deep2" ] && [ ! -e "$MNT/deep" ]; }
v_cp_xattr() { python3 - "$MNT" <<'PY'
import os,sys
sys.exit(0 if os.getxattr(sys.argv[1]+"/f1","user.k")==b"v"*64 else 1)
PY
}

# ---- workload: mkfs + mount + fsync'd checkpoints THROUGH the logger ----
log "recording a workload through dm-log-writes"
ct_mkfs "$LW" $MKFS_ARGS >/dev/null
ct_mount "$LW" "$MNT"
mark ready   # everything before this is mid-mkfs; mount is only expected to work after it

# A durability boundary with NO `sync` behind it.
#
# Every other checkpoint here runs `sync` before its mark, which writes
# back EVERY dirty buffer -- including the data bitmap -- so the only
# crash points this rig ever examined were ones where everything had
# just been flushed. A real crash does not wait for `sync`.
#
# fsync+close is the boundary that matters: it makes the inode record
# durable (the close stamps it, and on a CAW device that goes straight
# to the platter) while the allocation bits backing its extents are
# still only in this node's buffer cache. Crash there and the blocks
# come back referenced by an inode but reading FREE -- the allocator
# hands them out again and two files share them. That is the bug this
# rig could not see until this checkpoint existed.
python3 - "$MNT" <<'PY2'
import os, sys
m = sys.argv[1]
# f_nosync: written and CLOSED, never fsync'd. The close is the
# durability boundary -- it stamps the inode record, which reaches the
# device -- while the allocation bits behind its extents are still only
# dirty buffers.
a = os.open(m + "/f_nosync", os.O_CREAT | os.O_RDWR, 0o644)
os.pwrite(a, b'N' * 65536, 0)    # 16 blocks: losing their bits is unmistakable
os.close(a)
# f_barrier: fsync'd, purely to emit a FLUSH *inside* that window. Without
# it the next barrier only arrives with the following `sync`, by which
# time ordinary writeback has flushed the bitmap too and the gap has
# closed -- which is exactly why this rig could not see the bug before.
b = os.open(m + "/f_barrier", os.O_CREAT | os.O_RDWR, 0o644)
os.pwrite(b, b'B' * 4096, 0)
os.fsync(b)
os.close(b)
PY2
mark cp_nosync

python3 -c "import os;fd=os.open('$MNT/f1',os.O_CREAT|os.O_RDWR,0o644);os.pwrite(fd,b'A'*8192,0);os.fsync(fd);os.close(fd)"
sync; mark cp_file

for i in $(seq 1 120); do echo "d$i" > "$MNT/dir_$i"; done
python3 -c "import os;d=os.open('$MNT',os.O_RDONLY);os.fsync(d);os.close(d)"
sync; mark cp_dirgrow

python3 - "$MNT" <<'PY'
import os,sys
fd=os.open(sys.argv[1]+"/deep",os.O_CREAT|os.O_RDWR,0o644)
for i in range(12): os.pwrite(fd,bytes([i&255])*4096,i*2*4096)
os.fsync(fd); os.close(fd)
PY
sync; mark cp_deep

python3 -c "import os;fd=os.open('$MNT/f1',os.O_RDWR);os.ftruncate(fd,4096);os.fsync(fd);os.close(fd)"
sync; mark cp_trunc

mv "$MNT/deep" "$MNT/deep2"
python3 -c "import os;d=os.open('$MNT',os.O_RDONLY);os.fsync(d);os.close(d)"
sync; mark cp_rename

python3 -c "import os;os.setxattr('$MNT/f1','user.k',b'v'*64);fd=os.open('$MNT/f1',os.O_RDONLY);os.fsync(fd);os.close(fd)"
sync; mark cp_xattr

umount "$MNT"
dmsetup remove "$DM"           # finalizes the log super
blockdev --flushbufs "$LOG"

K="$($REPLAY --log "$LOG" --count-fua)"
READY_BARRIER="$($REPLAY --log "$LOG" --count-marks | awk '$2=="ready"{print $1; exit}')"
[ -n "$K" ] && [ "$K" -gt 0 ] || fail "no barriers recorded in the log"
[ -n "$READY_BARRIER" ] || fail "the 'ready' mark was not found in the log"
log "log has $K FLUSH/FUA barriers; mkfs+mount completes by barrier $READY_BARRIER"

# ---- Phase 1: recoverability at every post-mkfs barrier ----
log "PHASE 1: replay to each post-mkfs barrier ($((READY_BARRIER)) .. $K); mount+fsck must survive each"
p1_fail=0; tested=0
i="$READY_BARRIER"
while [ "$i" -le "$K" ]; do
    zero_replay
    "$REPLAY" --log "$LOG" --replay "$RLOOP" --limit-fua "$i" 2>/dev/null
    blockdev --flushbufs "$RLOOP"
    tested=$((tested + 1))
    if ! mount -t cetrafs "$RLOOP" "$MNT" 2>/dev/null; then
        echo "  barrier $i: MOUNT FAILED (crash state unrecoverable)"; p1_fail=1; i=$((i + 1)); continue
    fi
    umount "$MNT"; blockdev --flushbufs "$RLOOP"
    if "$ROOT/userspace/fsck.cetra" "$RLOOP" 2>&1 | grep -q "^ERR"; then
        echo "  barrier $i: fsck ERR after recovery:"; "$ROOT/userspace/fsck.cetra" "$RLOOP" 2>&1 | grep "^ERR" | head -3
        p1_fail=1
    fi
    i=$((i + 1))
done
[ "$p1_fail" = 0 ] &&
    pass "phase 1: cetrafs mounted and fsck'd ERR-free at all $tested post-mkfs crash barriers" ||
    fail "phase 1: a crash barrier left cetrafs unmountable or fsck-dirty"

# ---- Phase 2: durability -- each checkpoint's acknowledged data survives ----
log "PHASE 2: replay to each checkpoint; data fsync'd up to it must be present and correct"
p2_fail=0
# --end-mark stops just BEFORE the named mark, i.e. after all of that
# checkpoint's work + its fsync + sync -- exactly the checkpoint's state.
verify_at() { # verify_at <mark> <verify-fn>
    zero_replay
    "$REPLAY" --log "$LOG" --replay "$RLOOP" --end-mark "$1" 2>/dev/null
    blockdev --flushbufs "$RLOOP"
    if ! mount -t cetrafs "$RLOOP" "$MNT" 2>/dev/null; then
        echo "  $1: mount failed"; p2_fail=1; return
    fi
    "$2" || { echo "  $1: acknowledged data missing/wrong"; p2_fail=1; }
    umount "$MNT"; blockdev --flushbufs "$RLOOP"
}
verify_at cp_file    v_cp_file
verify_at cp_dirgrow v_cp_dirgrow
verify_at cp_deep    v_cp_deep
verify_at cp_trunc   v_cp_trunc
verify_at cp_rename  v_cp_rename
verify_at cp_xattr   v_cp_xattr
[ "$p2_fail" = 0 ] &&
    pass "phase 2: every checkpoint's fsync'd data was present and correct after a crash replayed to it" ||
    fail "phase 2: acknowledged data was lost or wrong after a crash"

# done with the log-writes stack; free the log loop before phase 3
losetup -d "$LOG" 2>/dev/null || true

# ---- Phase 3: dm-flakey drop-writes crash ----
log "PHASE 3: drop all writes from an instant on (power loss), remount, fsck, durable data intact"
FDM="crashfk_$$"
dmsetup create "$FDM" --table "0 $SECTORS flakey $DATA 0 1 0"   # up=1 down=0 -> always pass through
ct_track dm "$FDM"
FK="/dev/mapper/$FDM"
ct_mkfs "$FK" $MKFS_ARGS >/dev/null
mount -t cetrafs "$FK" "$MNT"
python3 -c "import os;fd=os.open('$MNT/durable',os.O_CREAT|os.O_RDWR,0o644);os.pwrite(fd,b'D'*8192,0);os.fsync(fd);os.close(fd)"
for i in $(seq 1 60); do echo "x" > "$MNT/pre_$i"; done
sync   # everything so far is genuinely on disk
# the crash: every further write is silently dropped
dmsetup suspend "$FDM"
dmsetup reload "$FDM" --table "0 $SECTORS flakey $DATA 0 0 60 1 drop_writes"
dmsetup resume "$FDM"
# a write acknowledged to the app but never persisted -- must be allowed to vanish, not corrupt
python3 -c "import os
try:
 fd=os.open('$MNT/lost',os.O_CREAT|os.O_RDWR,0o644);os.pwrite(fd,b'L'*8192,0);os.fsync(fd);os.close(fd)
except OSError: pass" 2>/dev/null || true
umount "$MNT" 2>/dev/null || true    # umount writes are dropped too -- this IS the power cut
# restore a clean pass-through path and remount the crash state
dmsetup suspend "$FDM"
dmsetup reload "$FDM" --table "0 $SECTORS flakey $DATA 0 1 0"
dmsetup resume "$FDM"
blockdev --flushbufs "$FK" 2>/dev/null || true
p3_fail=0
if mount -t cetrafs "$FK" "$MNT" 2>/dev/null; then
    python3 -c "import os,sys;sys.exit(0 if os.path.exists('$MNT/durable') and os.pread(os.open('$MNT/durable',os.O_RDONLY),8192,0)==b'D'*8192 else 1)" ||
        { echo "  phase3: durable fsync'd data lost"; p3_fail=1; }
    c=$(ls "$MNT"/pre_* 2>/dev/null | wc -l); [ "$c" = 60 ] || { echo "  phase3: only $c/60 pre-crash files survived"; p3_fail=1; }
    umount "$MNT"; blockdev --flushbufs "$FK" 2>/dev/null || true
else
    echo "  phase3: remount of the crash state failed"; p3_fail=1
fi
if "$ROOT/userspace/fsck.cetra" "$FK" 2>&1 | grep -q "^ERR"; then
    echo "  phase3: fsck ERR after crash:"; "$ROOT/userspace/fsck.cetra" "$FK" 2>&1 | grep "^ERR" | head
    p3_fail=1
fi
[ "$p3_fail" = 0 ] &&
    pass "phase 3: dm-flakey power loss -- remounted, fsck clean, all pre-crash fsync'd data intact" ||
    fail "phase 3: data loss or corruption after a dm-flakey power loss"

# ---- Phase 4: the journal issues its ordering flushes ----
# Phases 1-3 replay writes IN LOG ORDER, so they confirm ordered-power-cut
# recovery but cannot catch a volatile cache REORDERING the journal entry
# after the in-place write. The defence against that is the two
# blkdev_issue_flush() barriers in cetrafs_journal_write_block() (journal
# durable before the target write; target durable before the entry is
# consumed). dm-log-writes records those as FLUSH barriers, so a single
# journaled create must advance the barrier count by >= 2 -- and does NOT
# without the flushes (measured: delta 2 with, 0 without). This is the
# discriminating proof the fix is actually emitted; the deployment LUN
# reports a write-back (volatile) cache, so it is load-bearing there.
log "PHASE 4: a journaled op emits its crash-ordering flushes (volatile-cache safety)"
P4DATA="$(ct_loop "$(ct_image "$SZ_MB" crashp4d)")"
P4LOG="$(ct_loop "$(ct_image 256 crashp4l)")"
P4DM="crashp4_$$"
dmsetup create "$P4DM" --table "0 $SECTORS log-writes $P4DATA $P4LOG"
ct_track dm "$P4DM"
ct_mkfs "/dev/mapper/$P4DM" $MKFS_ARGS >/dev/null
mount -t cetrafs "/dev/mapper/$P4DM" "$MNT"
sync; dmsetup message "$P4DM" 0 mark a
echo journaled-create > "$MNT/onefile"      # one create -> one journaled dirent block
dmsetup message "$P4DM" 0 mark b
umount "$MNT"; dmsetup remove "$P4DM"; blockdev --flushbufs "$P4LOG"
A_BAR="$($REPLAY --log "$P4LOG" --count-marks | awk '$2=="a"{print $1; exit}')"
B_BAR="$($REPLAY --log "$P4LOG" --count-marks | awk '$2=="b"{print $1; exit}')"
DELTA=$((B_BAR - A_BAR))
[ "$DELTA" -ge 2 ] &&
    pass "phase 4: a journaled create emitted $DELTA FLUSH barriers (its two ordering flushes)" ||
    fail "phase 4: a journaled create emitted only $DELTA FLUSH barriers -- the journal's ordering flushes are missing (volatile-cache crash hole)"

# ---- Phase 5: reorder-replay -- a torn journaled block recovers ----
# Phase 4 proves the ordering flushes are EMITTED; this proves they WORK.
# replay-log --reorder-after-fua models a volatile-cache power cut: everything
# through barrier N durable, then the next window with its JOURNAL-AREA writes
# dropped (the commit lost in the cache) and its last journaled TARGET block
# (dirent/leaf/xattr, found by tail magic) TORN to half. A torn target with no
# journal is unrecoverable UNLESS the journal commit sits in an earlier, durable
# window -- which is exactly what the flush between commit and target guarantees.
#
# The workload is deliberately a no-GROWTH one: create one file, allocate its
# xattr block once, then rewrite that same block 30x. Each rewrite journals the
# block with NO new allocation, so ordered replay stays clean and the torn-target
# recovery is the only variable (a growth workload instead leaves pre-existing
# referenced-but-free / orphan states at mid-op crash points that swamp the
# signal -- that cost real debugging). Verified to discriminate: on this build
# every torn block recovers; reverting the two journal flushes turns every torn
# window into "xattr block failed its tail checksum" (measured 30/30).
log "PHASE 5: reorder-replay -- drop the journal + tear its target block; the journal must restore it"
P5DATA="$(ct_loop "$(ct_image "$SZ_MB" crashp5d)")"
P5LOG="$(ct_loop "$(ct_image 256 crashp5l)")"
P5RL="$(ct_loop "$(ct_image "$SZ_MB" crashp5r)")"
P5DM="crashp5_$$"
dmsetup create "$P5DM" --table "0 $SECTORS log-writes $P5DATA $P5LOG"
ct_track dm "$P5DM"
ct_mkfs "/dev/mapper/$P5DM" $MKFS_ARGS >/dev/null
mount -t cetrafs "/dev/mapper/$P5DM" "$MNT"
: > "$MNT/anchor"
python3 -c "import os;os.setxattr('$MNT/anchor','user.k',b'x'*32)"   # allocate the xattr block ONCE
python3 -c "import os;d=os.open('$MNT',os.O_RDONLY);os.fsync(d);os.close(d)"; sync
dmsetup message "$P5DM" 0 mark ready
for i in $(seq 1 30); do   # 30 no-allocation journaled rewrites of the same block
    python3 -c "import os;os.setxattr('$MNT/anchor','user.k',bytes([$i%256])*32);fd=os.open('$MNT/anchor',os.O_RDONLY);os.fsync(fd);os.close(fd)"
done
umount "$MNT"; dmsetup remove "$P5DM"; blockdev --flushbufs "$P5LOG"

# SB geometry: journal area to drop, data-region boundary, both in 4 KiB blocks
bg_regions_start=0 node_journal_start=0 node_journal_blocks=0 node_table_count=0  # set -u defaults
eval "$("$RESTAMP" "$P5DATA" info | awk -F= '/^(bg_regions_start|node_journal_start|node_journal_blocks|node_table_count)=/{print $1"="$2}')"
P5_JBLK=$((node_table_count * node_journal_blocks))
P5K="$($REPLAY --log "$P5LOG" --count-fua)"
P5READY="$($REPLAY --log "$P5LOG" --count-marks | awk '$2=="ready"{print $1; exit}')"
[ -n "$P5K" ] && [ -n "$P5READY" ] && [ -n "$bg_regions_start" ] && [ "$P5_JBLK" -gt 0 ] ||
    fail "phase 5: could not read log barriers / SB geometry"

p5_corrupt=0; p5_mountfail=0; p5_tore=0; p5_win=0; p5_first_torn=""
N="$P5READY"
while [ "$N" -le "$P5K" ]; do
    p5_win=$((p5_win + 1))
    blkdiscard "$P5RL" 2>/dev/null || dd if=/dev/zero of="$P5RL" bs=1M status=none
    "$REPLAY" --log "$P5LOG" --replay "$P5RL" --reorder-after-fua "$N" \
        --data-start "$bg_regions_start" --journal-start "$node_journal_start" \
        --journal-blocks "$P5_JBLK" 2>"$CT_BUILD/p5.err"
    if grep -q "1 torn" "$CT_BUILD/p5.err"; then
        p5_tore=$((p5_tore + 1))
        [ -n "$p5_first_torn" ] || p5_first_torn="$N"
    fi
    blockdev --flushbufs "$P5RL"
    if ! mount -t cetrafs "$P5RL" "$MNT" 2>/dev/null; then
        echo "  N=$N: MOUNT FAILED"; p5_mountfail=$((p5_mountfail + 1)); N=$((N + 1)); continue
    fi
    # the xattr block must be READABLE (not a persistent torn-checksum -EIO)
    if ! python3 -c "import os;os.getxattr('$MNT/anchor','user.k')" 2>/dev/null; then
        echo "  N=$N: xattr block unreadable after recovery (torn, journal did not restore)"; p5_corrupt=$((p5_corrupt + 1))
    fi
    umount "$MNT"; blockdev --flushbufs "$P5RL"
    # Capture first, then grep -- fsck exits nonzero when it finds the fault, so
    # `fsck | grep -q` under pipefail would hide the very match we look for (the
    # trap CLAUDE.md names). Plain grep, output discarded, reads to EOF.
    p5_fo="$("$ROOT/userspace/fsck.cetra" "$P5RL" 2>&1 || true)"
    if printf '%s\n' "$p5_fo" | grep -E "tail checksum|overlap|marked FREE|two files|EUCLEAN" >/dev/null; then
        echo "  N=$N: fsck corruption: $(printf '%s\n' "$p5_fo" | grep -E "tail checksum|overlap|marked FREE|two files" | head -1)"
        p5_corrupt=$((p5_corrupt + 1))
    fi
    N=$((N + 1))
done
log "phase 5: $p5_win crash windows, $p5_tore tore a journaled target block"
# Honesty gate: a run that tore nothing proves nothing about recovery.
if [ "$p5_tore" -lt 10 ]; then
    fail "phase 5: only $p5_tore windows tore a journaled target -- the test did not exercise recovery (vacuous)"
elif [ "$p5_corrupt" = 0 ] && [ "$p5_mountfail" = 0 ]; then
    pass "phase 5: every one of $p5_tore torn journaled blocks was restored by journal replay (no corruption across $p5_win windows)"
else
    fail "phase 5: $p5_corrupt torn blocks were NOT recovered + $p5_mountfail mount failures -- the journal's ordering flushes are not protecting the target"
fi

# Negative control for the phase above.
#
# "No corruption across 91 windows" is only evidence if the damage was
# real and something specific repaired it. Redo ONE window that actually
# tore, with the torn branch of journal replay disabled -- which is
# exactly how 0.7.3 behaved: a block caught mid-write matches neither the
# entry's before-image nor its after-image, so the prev_checksum guard
# read it as "a peer rewrote this" and refused to redo it, leaving the
# block unreadable forever. With that branch off the damage MUST survive.
# If it does not, the pass above is attributable to something this suite
# does not name, and is worth nothing.
if [ -n "$p5_first_torn" ]; then
    ct_param_set journal_ignore_torn 1
    blkdiscard "$P5RL" 2>/dev/null || dd if=/dev/zero of="$P5RL" bs=1M status=none
    "$REPLAY" --log "$P5LOG" --replay "$P5RL" --reorder-after-fua "$p5_first_torn" \
        --data-start "$bg_regions_start" --journal-start "$node_journal_start" \
        --journal-blocks "$P5_JBLK" 2>/dev/null
    blockdev --flushbufs "$P5RL"
    p5_nc_broke=0
    if ! mount -t cetrafs "$P5RL" "$MNT" 2>/dev/null; then
        p5_nc_broke=1
    else
        python3 -c "import os;os.getxattr('$MNT/anchor','user.k')" 2>/dev/null || p5_nc_broke=1
        umount "$MNT"; blockdev --flushbufs "$P5RL"
        p5_nc_fo="$("$ROOT/userspace/fsck.cetra" "$P5RL" 2>&1 || true)"
        printf '%s\n' "$p5_nc_fo" | grep -E "tail checksum|EUCLEAN" >/dev/null && p5_nc_broke=1
    fi
    ct_param_set journal_ignore_torn 0
    if [ "$p5_nc_broke" = 1 ]; then
        pass "phase 5 negative control: with the torn branch disabled, window $p5_first_torn stays corrupt -- the recovery above is that branch's doing"
    else
        fail "phase 5 negative control: window $p5_first_torn recovered even with the torn branch disabled -- phase 5 proves nothing about it"
    fi
else
    fail "phase 5 negative control: no window tore, nothing to control against"
fi

# ---- Phase 5b: tear at SECTOR granularity, and across several blocks ---
#
# Phase 5 tears one block to its first HALF of sectors. That is the easy
# point in the space: the tail (last 8 bytes of the last sector) keeps its
# old image, so "a torn block fails its own tail checksum" -- the single
# claim the replay decision rests on -- is trivially true there.
#
# The edges are what test it. K=7 of 8 sectors lands everything but the
# tail: all-new data under an OLD tail. K=1 lands only the first sector:
# one new sector in an otherwise old block. If any K produced a block that
# still passed its own tail checksum, replay would read it as "a peer
# rewrote this" and refuse to repair it -- silently, and forever.
#
# Then the same window with three blocks torn at once, because a power
# loss does not politely land every block but the last.
#
# This is the gap tests/crash/README.md records as (1).
if [ -n "$p5_first_torn" ]; then
    p5b_cases=0; p5b_bad=0
    for K in 1 2 3 4 5 6 7 half3; do
        if [ "$K" = half3 ]; then
            TEAR_ARGS="--tear-blocks 3"; label="3 blocks, half each"
        else
            TEAR_ARGS="--tear-sectors $K"; label="1 block, first $K of 8 sectors"
        fi
        blkdiscard "$P5RL" 2>/dev/null || dd if=/dev/zero of="$P5RL" bs=1M status=none
        # shellcheck disable=SC2086
        "$REPLAY" --log "$P5LOG" --replay "$P5RL" --reorder-after-fua "$p5_first_torn" \
            --data-start "$bg_regions_start" --journal-start "$node_journal_start" \
            --journal-blocks "$P5_JBLK" $TEAR_ARGS 2>"$CT_BUILD/p5b.err"
        # Honesty gate per case: a case that tore nothing proves nothing.
        if ! grep -qE "\([1-9][0-9]* torn\)" "$CT_BUILD/p5b.err"; then
            echo "  $label: NOTHING TORN -- case is vacuous"; p5b_bad=$((p5b_bad + 1)); continue
        fi
        p5b_cases=$((p5b_cases + 1)); p5b_case_bad=0
        blockdev --flushbufs "$P5RL"
        if ! mount -t cetrafs "$P5RL" "$MNT" 2>/dev/null; then
            echo "  $label: MOUNT FAILED"; p5b_bad=$((p5b_bad + 1)); continue
        fi
        if ! python3 -c "import os;os.getxattr('$MNT/anchor','user.k')" 2>/dev/null; then
            echo "  $label: xattr block unreadable after recovery"; p5b_case_bad=1
        fi
        umount "$MNT"; blockdev --flushbufs "$P5RL"
        p5b_fo="$("$ROOT/userspace/fsck.cetra" "$P5RL" 2>&1 || true)"
        if printf '%s\n' "$p5b_fo" | grep -E "tail checksum|overlap|marked FREE|two files|EUCLEAN" >/dev/null; then
            echo "  $label: fsck: $(printf '%s\n' "$p5b_fo" | grep -E "tail checksum|overlap|marked FREE|two files" | head -1)"
            p5b_case_bad=1
        fi
        p5b_bad=$((p5b_bad + p5b_case_bad))
    done
    log "phase 5b: $p5b_cases tear shapes exercised on window $p5_first_torn"
    if [ "$p5b_cases" -lt 8 ]; then
        fail "phase 5b: only $p5b_cases of 8 tear shapes actually tore anything -- the sweep is vacuous"
    elif [ "$p5b_bad" = 0 ]; then
        pass "phase 5b: every tear shape recovered -- sector-granularity and multi-block tears all read as torn, none passed its tail checksum by accident"
    else
        fail "phase 5b: $p5b_bad of $p5b_cases tear shapes did NOT recover -- a tear is producing a block replay cannot classify"
    fi
fi

# ---- Phase 6: a power cut that does NOT flush first --------------------
#
# Every phase above cuts power at a moment when the filesystem has just
# been flushed -- phase 3 runs `sync` by design, and `dmsetup suspend`
# flushes the device unless told not to (it sync_blockdev()s the mapped
# device, writing back every dirty buffer). So "power loss" here always
# meant "power loss immediately after a full writeback", which is the one
# instant a real power loss is least likely to pick.
#
# This phase cuts without flushing. The state it catches: a DURABILITY
# BOUNDARY has published a reference -- close(2) stamps the inode record,
# which reaches the device -- while the data-bitmap bits backing that
# file's extents are still only dirty buffers. Recover from that and the
# blocks come back referenced by an inode but reading FREE: the allocator
# hands them out again and two files share them.
#
# Found on the cluster via ctest replay-race, where a node
# is killed outright and never gets to flush anything. It reproduces here
# in one shot once the cut stops being polite.
log "PHASE 6: power cut with NO flush -- allocations dirty at the instant of the cut"
P6DATA="$(ct_loop "$(ct_image "$SZ_MB" crashp6d)")"
P6DM="crashp6_$$"
P6SECT="$(blockdev --getsz "$P6DATA")"
dmsetup create "$P6DM" --table "0 $P6SECT flakey $P6DATA 0 1 0"
ct_track dm "$P6DM"
P6FK="/dev/mapper/$P6DM"
ct_mkfs "$P6FK" $MKFS_ARGS >/dev/null
mount -t cetrafs "$P6FK" "$MNT"

# Written and CLOSED. No fsync, no sync: the close is the only boundary,
# and it is enough to make the record durable.
python3 - "$MNT" <<'PY6'
import os, sys
fd = os.open(sys.argv[1] + "/unflushed", os.O_CREAT | os.O_RDWR, 0o644)
os.pwrite(fd, b'U' * 65536, 0)   # 16 blocks
os.close(fd)
PY6

# The cut. --noflush --nolockfs is the whole point: without them dm
# writes back the page cache first and the window closes before the
# "crash", which is why this bug survived every earlier run of this rig.
dmsetup suspend --noflush --nolockfs "$P6DM"
dmsetup reload "$P6DM" --table "0 $P6SECT flakey $P6DATA 0 0 60 1 drop_writes"
dmsetup resume "$P6DM"
umount -f "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true

dmsetup suspend --noflush --nolockfs "$P6DM"
dmsetup reload "$P6DM" --table "0 $P6SECT flakey $P6DATA 0 1 0"
dmsetup resume "$P6DM"
blockdev --flushbufs "$P6FK" 2>/dev/null || true

P6OUT="$("$ROOT/userspace/fsck.cetra" "$P6FK" 2>&1 || true)"
if echo "$P6OUT" | grep -q "marked FREE"; then
    echo "$P6OUT" | grep "marked FREE" | head -3
    fail "phase 6: blocks came back referenced by an inode but marked FREE -- an allocation was published before it was durable"
elif echo "$P6OUT" | grep -q "^ERR"; then
    echo "$P6OUT" | grep "^ERR" | head -3
    fail "phase 6: fsck reported errors after an unflushed power cut"
else
    pass "phase 6: an unflushed power cut left no block referenced-but-free (allocations durable before their references)"
fi

ct_exit
