#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fdatasync publishes the record only when something it must make durable changed
#
# fsync and fdatasync both ended in the VFS metadata sync, which rewrote
# the whole inode record (one CAS) whenever the inode was dirty. A pure
# overwrite of written blocks dirties nothing but the mtime, and fdatasync
# does not promise the mtime: it was a full record publish per call for a
# change nothing needed. The datasync scope (file.c cetrafs_sync_inode_meta)
# now drops time-only dirt inside an fdatasync, and the inode is re-dirtied
# so the times are still published by writeback or the next full sync.
#
# Three things must hold, and each has a case:
#   1. A pure overwrite of written blocks: an fdatasync publishes NOTHING
#      (procfs record_writes), and the times it dropped are still
#      durable: a clean unmount and remount reads back the last mtime.
#      Setup must really have produced time-only dirt, every round.
#      Control datasync_full=1 publishes on every call -- the counter can
#      see the publish, so a zero is a zero.
#   2. A FALLOCATED file: the first write into a preallocated block changes
#      neither size nor blocks, but its extent must become written. Every
#      fdatasync must publish that conversion: the on-disk record (poke
#      "uninit") shows the new written blocks right after each call, and
#      the data reads back after a remount.
#   3. fsck is clean after both.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 fdso)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fdso)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
[ -r "$PROC" ] || { skip "no procfs info for the mount"; ct_exit; }

# phase <mode> <file> <ino-out>: the workload. Prints one line per round
# and the summary the assertions read. mode is "overwrite" or "fallocate".
phase() {
    python3 - "$MNT" "$PROC" "$POKE" "$IMG" "$1" "$2" <<'PY'
import os, random, subprocess, sys, time
mnt, proc, poke, img, mode, name = sys.argv[1:7]
path = os.path.join(mnt, name)

def rw():
    for line in open(proc):
        if line.startswith("record_writes: "):
            return int(line.split(": ")[1])
    raise SystemExit("no record_writes in procfs")

def pat(r, b):
    return (b"R%03dB%03d" % (r, b)) * 512          # 4096 bytes

def uninit(ino):
    return subprocess.run([poke, img, "uninit", str(ino)], capture_output=True, text=True).stdout.strip()

if mode == "overwrite":
    NB, ROUNDS = 64, 12
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    for b in range(NB):
        os.pwrite(fd, pat(0, b), b * 4096)
    os.fsync(fd)
    blocks0 = os.fstat(fd).st_blocks
    random.seed(7)
    moved = 0
    total = 0
    for r in range(1, ROUNDS + 1):
        # mtime is whole seconds in the record: wait for the next one so
        # every round's write is a time change the fdatasync must face.
        time.sleep(1.1)
        before = os.fstat(fd).st_mtime
        for b in random.sample(range(NB), 4):
            os.pwrite(fd, pat(r, b), b * 4096)
        if int(os.fstat(fd).st_mtime) != int(before):
            moved += 1
        w0 = rw()
        os.fdatasync(fd)
        d = rw() - w0
        total += d
        print("round %d publishes=%d" % (r, d))
    print("rounds=%d moved=%d total_publishes=%d blocks_stable=%d" %
          (ROUNDS, moved, total, int(os.fstat(fd).st_blocks == blocks0)))
    # The times the datasyncs dropped are still owed: a full fsync must
    # publish them. Without the re-dirty there is nothing dirty left and
    # this publishes nothing -- the negative control for that mechanism.
    w0 = rw()
    os.fsync(fd)
    print("owed_publishes=%d" % (rw() - w0))
    print("mtime_sec=%d" % int(os.fstat(fd).st_mtime))
    os.close(fd)
elif mode == "fallocate":
    NB = 64
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    os.posix_fallocate(fd, 0, NB * 4096)
    ino = os.fstat(fd).st_ino
    print("ino=%d" % ino)
    print("setup %s" % uninit(ino))
    # Four blocks, chosen so the record stays at depth 0 (four inline
    # slots): the head, the next block, the tail, the one before it.
    for k, b in enumerate([0, 1, 63, 62]):
        os.pwrite(fd, pat(1, b), b * 4096)
        w0 = rw()
        os.fdatasync(fd)
        d = rw() - w0
        print("convert %d block=%d publishes=%d on_disk=%s" % (k + 1, b, d, uninit(ino)))
    os.close(fd)
elif mode in ("check-ov", "check-pa"):
    NB = 64
    fd = os.open(path, os.O_RDONLY)
    bad = []
    for b in range(NB):
        got = os.pread(fd, 4096, b * 4096)
        if mode == "check-ov":
            # Every block holds the last round that overwrote it: any
            # round 0..12, never anything else.
            ok = any(got == pat(r, b) for r in range(13))
        else:
            want = pat(1, b) if b in (0, 1, 62, 63) else b"\0" * 4096
            ok = got == want
        if not ok:
            bad.append(b)
    print("bad_blocks=%s" % (",".join(map(str, bad)) if bad else "none"))
    print("size=%d" % os.fstat(fd).st_size)
    print("mtime_sec=%d" % int(os.fstat(fd).st_mtime))
    os.close(fd)
PY
}

get() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# ---- 1. pure overwrite, datasync scope on (the shipped behaviour) ----
log "a pure overwrite of written blocks: fdatasync publishes nothing"
ct_param_set datasync_full 0
OV="$(phase overwrite ov)"
echo "$OV" | sed 's/^/    /'
[ "$(get rounds "$OV")" = 12 ] && [ "$(get moved "$OV")" = 12 ] &&
    pass "setup: every round's write moved the mtime, so each fdatasync faced time-only dirt" ||
    fail "setup: the mtime moved in $(get moved "$OV") of $(get rounds "$OV") rounds -- the suite is not testing time-only dirt"
[ "$(get blocks_stable "$OV")" = 1 ] &&
    pass "setup: the overwrites changed no block count (written blocks, not allocation)" ||
    fail "setup: the block count changed -- these were not overwrites of written blocks"
[ "$(get total_publishes "$OV")" = 0 ] &&
    pass "12 fdatasyncs of time-only dirt published 0 records" ||
    fail "fdatasync published $(get total_publishes "$OV") records for time-only dirt"
OV_MTIME="$(get mtime_sec "$OV")"

# ---- 2. control: the old behaviour publishes on every call ----
log "control: datasync_full=1 publishes the record on every fdatasync"
ct_param_set datasync_full 1
OVC="$(phase overwrite ovc)"
echo "$OVC" | sed 's/^/    /'
[ "$(get total_publishes "$OVC")" -ge 12 ] &&
    pass "control: the same 12 fdatasyncs published $(get total_publishes "$OVC") records" ||
    fail "control: only $(get total_publishes "$OVC") publishes -- the counter cannot see the publish this suite relies on"
ct_param_set datasync_full 0

# ---- 3. the dropped times are still owed ----
log "the times the fdatasyncs dropped are published by the next full sync"
[ "$(get owed_publishes "$OV")" -ge 1 ] &&
    pass "the full fsync after the datasyncs published the owed times ($(get owed_publishes "$OV") record)" ||
    fail "the full fsync after the datasyncs published nothing: the times dropped by fdatasync are lost"
# The file was closed by the workload, and a close publishes the record,
# so this is the end state rather than a second proof of the above.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CHK="$(phase check-ov ov)"
echo "$CHK" | sed 's/^/    /'
[ "$(get mtime_sec "$CHK")" = "$OV_MTIME" ] &&
    pass "after a remount the mtime is the last write's ($OV_MTIME)" ||
    fail "mtime after remount is $(get mtime_sec "$CHK"), last write was $OV_MTIME"

# ---- 4. fallocated file: the conversion must be published ----
log "a fallocated file: each fdatasync publishes the uninit-to-written conversion"
FA="$(phase fallocate pa)"
echo "$FA" | sed 's/^/    /'
INO="$(get ino "$FA")"
SETUP="$(sed -n 's/^setup //p' <<<"$FA")"
case "$SETUP" in
"depth=0 written_blocks=0 uninit_blocks=64 uninit_entries=1") pass "setup: the file is one preallocated extent of 64 blocks, nothing written" ;;
*) fail "setup: the record reads '$SETUP', expected one uninit extent of 64 blocks" ;;
esac
n=0
fa_ok=1
while IFS= read -r line; do
    case "$line" in convert*) ;; *) continue ;; esac
    n=$((n + 1))
    pub="$(sed -n 's/.*publishes=\([0-9]*\).*/\1/p' <<<"$line")"
    disk="$(sed -n 's/.*on_disk=//p' <<<"$line")"
    [ "$pub" -ge 1 ] || { fa_ok=0; echo "    conversion $n published nothing"; }
    case "$disk" in
    "depth=0 written_blocks=$n "*) ;;
    *) fa_ok=0; echo "    after conversion $n the on-disk record reads '$disk'" ;;
    esac
done <<<"$FA"
[ "$n" = 4 ] && [ "$fa_ok" = 1 ] &&
    pass "every fdatasync published its conversion, and the on-disk record shows the written blocks at each step" ||
    fail "a conversion did not reach the device at its fdatasync (conversions seen: $n)"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
FCHK="$(phase check-pa pa)"
echo "$FCHK" | sed 's/^/    /'
[ "$(get bad_blocks "$FCHK")" = none ] && [ "$(get size "$FCHK")" = "$((64 * 4096))" ] &&
    pass "after a remount the four written blocks read back as written, the rest read as zeros" ||
    fail "after a remount: bad blocks $(get bad_blocks "$FCHK"), size $(get size "$FCHK")"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
