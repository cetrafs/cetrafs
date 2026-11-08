#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a regular file's extent leaves reach the device only at a boundary, through the journal
#
# A regular file's leaf edits wait in core for close/fsync/sync. They used
# to wait as DIRTY buffers, and so (crash review 2026-11-08, C1, C2):
#   - the boundary wrote them in place, unjournaled: a leaf torn by a
#     power cut lost the old map with the new one, every read of the range
#     returned EIO, and fsck could not repair it -- an image that neither
#     restarts nor repairs;
#   - writeback could write them at any time, with no flush ahead of the
#     data and bits they name, and torn just the same;
#   - a leaf a truncate freed stayed dirty, and was written later over
#     whatever the block had become.
# Now they are held back, not dirty (kmod/leafdefer.c), written at the
# boundary in one journal batch, and dropped when freed.
#
#   (1) held back: writes that edit the leaf, writeback forced, and the
#       leaf on the device has not moved; fsync then writes it, through
#       the journal (journal_writes moves).
#   (2) the worst crash: journal_batch_crash_before_targets stops the
#       mount the moment the batch's entries are durable. The leaf on the
#       device is then TORN by hand (its first half new, its second half
#       old: the tail checksum fails, as a power cut mid-write leaves it). The remount
#       replays our own area, redoes the torn leaf (journal_replay_torn),
#       and every block written before the fsync reads back -- no EIO.
#   (3) freed while held back: a truncate frees a leaf with edits still in
#       core, sync and writeback run, and the freed block on the device
#       has not moved.
#
# NOT COVERED: C2's ORDER -- data and allocation bits durable before the
# entries that name them. A loop device completes every write durably and
# in order, so nothing here can show a reordering; the batch's first step
# (cetrafs_journal_write_deferred()) is asserted by reading, and the
# instrument is tests/crash's dm-log-writes rig (docs/internal/TODO.md).
#
# DISCRIMINATION: with the old dirty-buffer deferral, (1) fails (the leaf
# moves under writeback); with the batch writing in place without the
# journal, (2) fails (the torn leaf is not repaired and reads EIO); with
# the free not dropping the held-back block, (3) fails (sync writes it).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_batch_crash_before_targets ] ||
    { skip "journal_batch_crash_before_targets is missing"; ct_exit; }
LP="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 lbj)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lbj)"
# A journal: ct_mkfs_small makes none (-J 0), and the batch then writes
# in place -- the unjournaled path this suite exists to rule out.
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
PROC="$(ct_procdir "$DEV")"
ctr() { sed -n "s/^$1: //p" "$PROC/info"; }
dev_blk() { dd if="$IMG" bs=4096 skip="$1" count=1 status=none | sha1sum | cut -c1-16; } # the device
mem_blk() { dd if="$DEV" bs=4096 skip="$1" count=1 status=none | sha1sum | cut -c1-16; } # the cache

# Setup: the journal is attached. A directory entry is always journaled.
JW0="$(ctr journal_writes)"
mkdir "$MNT/jprobe" && sync
[ "$(ctr journal_writes)" -gt "$JW0" ] ||
    { fail "setup: no journal write for a directory entry -- the volume has no journal"; ct_exit; }

# Force the block device's writeback: what it can write, it writes now.
EXP0="$(cat /proc/sys/vm/dirty_expire_centisecs)"
WB0="$(cat /proc/sys/vm/dirty_writeback_centisecs)"
ct_track cmd "echo $EXP0 >/proc/sys/vm/dirty_expire_centisecs; echo $WB0 >/proc/sys/vm/dirty_writeback_centisecs"
writeback() {
    echo 50 >/proc/sys/vm/dirty_expire_centisecs
    echo 50 >/proc/sys/vm/dirty_writeback_centisecs
    sleep 4
    echo "$EXP0" >/proc/sys/vm/dirty_expire_centisecs
    echo "$WB0" >/proc/sys/vm/dirty_writeback_centisecs
}

# A preallocated image with every 4th block written: each write splits a
# preallocated extent, and past four extents the map lives in a leaf.
# write_every4 <fd> <from> <to>: blocks from*4 .. (to-1)*4, each filled
# with its own number.
write_every4() {
    python3 - "$1" "$2" "$3" <<'PY'
import os, sys
fd, a, b = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
for i in range(a, b):
    os.pwrite(fd, (b"%08d" % (i * 4)) * 512, i * 4 * 4096)
PY
}
F="$MNT/img"
python3 - "$F" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(4 << 20)) == 0
os.close(fd)
PY
exec 7<>"$F"
write_every4 7 0 24
python3 -c 'import os,sys; os.fsync(int(sys.argv[1]))' 7
INO="$(stat -c %i "$F")"
L="$("$LP" "$IMG" leaf "$INO" 2>/dev/null || true)"
[ -n "$L" ] && [ "$L" -gt 0 ] 2>/dev/null ||
    { fail "setup: the file has no external leaf after its fsync"; exec 7>&-; ct_exit; }
log "leaf of ino $INO at block $L"

# ------------------------------------------------------------------ (1)
H0="$(dev_blk "$L")"
write_every4 7 24 48
[ "$(mem_blk "$L")" != "$H0" ] && pass "(1) setup: the writes edited the leaf in core" ||
    { fail "(1) setup: the leaf did not change in core"; exec 7>&-; ct_exit; }
writeback
[ "$(dev_blk "$L")" = "$H0" ] && pass "(1) writeback left the held-back leaf alone" ||
    fail "(1) writeback wrote the leaf in place, before any boundary and unjournaled"
J0="$(ctr journal_writes)"
python3 -c 'import os,sys; os.fsync(int(sys.argv[1]))' 7
[ "$(dev_blk "$L")" = "$(mem_blk "$L")" ] && [ "$(dev_blk "$L")" != "$H0" ] &&
    pass "(1) fsync wrote the leaf" || fail "(1) fsync did not put the leaf on the device"
[ "$(ctr journal_writes)" -gt "$J0" ] && pass "(1) ...through the journal ($J0 -> $(ctr journal_writes))" ||
    fail "(1) fsync wrote the leaf without a journal entry"

# ------------------------------------------------------------------ (2)
H1="$(dev_blk "$L")"
write_every4 7 48 72
[ "$(mem_blk "$L")" != "$H1" ] || { fail "(2) setup: the writes did not edit the leaf"; exec 7>&-; ct_exit; }
ct_param_set journal_batch_crash_before_targets 1
MARK="$(dmesg_mark)"
python3 -c 'import os,sys; os.fsync(int(sys.argv[1]))' 7 2>/dev/null && FS=0 || FS=$?
ct_param_set journal_batch_crash_before_targets 0
exec 7>&-
dmesg_since "$MARK" | grep -q 'TEST stop after [0-9]* entries, before their targets' ||
    { fail "(2) setup: the batch did not stop between its entries and its targets (fsync rc $FS)"; ct_exit; }
[ "$(dev_blk "$L")" = "$H1" ] && pass "(2) setup: the mount stopped with the leaf's entry durable and the leaf untouched" ||
    { fail "(2) setup: the leaf reached the device before the stop"; ct_exit; }
T0="$(ctr journal_replay_torn)" # module-global: sampled while mounted
NEW="$(ct_tmp lbj-new)"
dd if="$DEV" of="$NEW" bs=4096 skip="$L" count=1 status=none # the edit, from the cache
ct_umount "$MNT"
# The power cut tore the leaf: its first half landed, its second half
# still holds the old image -- what a disk leaves, not zeroes. (Zeroes
# would wipe the tail's magic, and replay rightly refuses a block that is
# no longer of its entry's kind: freed and reused, as far as it can tell.)
dd if="$NEW" of="$IMG" bs=2048 count=1 seek=$((L * 2)) conv=notrunc status=none
[ "$(dev_blk "$L")" != "$H1" ] && [ "$(dev_blk "$L")" != "$(sha1sum <"$NEW" | cut -c1-16)" ] ||
    { fail "(2) setup: the leaf on the device is not torn"; ct_exit; }
ct_mount "$DEV" "$MNT"
PROC="$(ct_procdir "$DEV")"
[ "$(ctr journal_replay_torn)" -gt "$T0" ] &&
    pass "(2) the remount's replay redid the torn leaf ($T0 -> $(ctr journal_replay_torn))" ||
    fail "(2) no torn target was redone (journal_replay_torn $T0 -> $(ctr journal_replay_torn))"
BAD="$(python3 - "$F" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bad = []
for i in range(0, 72):
    b = i * 4
    try:
        d = os.pread(fd, 4096, b * 4096)
    except OSError as e:
        bad.append("%d:%s" % (b, e.strerror))
        continue
    if d != (b"%08d" % b) * 512:
        bad.append("%d:wrong" % b)
print(" ".join(bad[:8]))
PY
)"
[ -z "$BAD" ] && pass "(2) every block written before the fsync reads back -- the image restarts" ||
    fail "(2) blocks unreadable or wrong after the replay: $BAD"

# ------------------------------------------------------------------ (3)
G="$MNT/g"
python3 - "$G" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
assert libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(4 << 20)) == 0
os.close(fd)
PY
exec 8<>"$G"
write_every4 8 0 24
python3 -c 'import os,sys; os.fsync(int(sys.argv[1]))' 8
GI="$(stat -c %i "$G")"
LG="$("$LP" "$IMG" leaf "$GI" 2>/dev/null || true)"
[ -n "$LG" ] && [ "$LG" -gt 0 ] 2>/dev/null || { fail "(3) setup: no leaf for the second file"; exec 8>&-; ct_exit; }
HG="$(dev_blk "$LG")"
write_every4 8 24 48
[ "$(mem_blk "$LG")" != "$HG" ] || { fail "(3) setup: the writes did not edit the leaf"; exec 8>&-; ct_exit; }
truncate -s 0 "$G"
exec 8>&-
sync
writeback
[ "$("$LP" "$IMG" leaf "$GI" 2>/dev/null || true)" != "$LG" ] ||
    { fail "(3) setup: the truncate did not drop the leaf from the file's tree"; ct_exit; }
[ "$(dev_blk "$LG")" = "$HG" ] && pass "(3) a leaf freed while held back was never written" ||
    fail "(3) the freed leaf was written after its free -- over whatever the block is now"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
