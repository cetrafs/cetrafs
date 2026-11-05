#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mapping that races the conversion of a buffered write still reads the data
#
# A buffered write into preallocated space leaves its block unwritten in
# the tree and pending in a per-inode set until fsync/close converts it
# (tests/kernel/buffered_pending_reads.sh). Conversion marks the block
# written, then drops it from the set. A mapping that read the tree
# FIRST and the set SECOND could see "unwritten" and then "not pending"
# when a conversion fell between the two, and serve zeros over written
# data. get_block now looks again after such a miss.
#
# The window is forced with the TEST ONLY knob pending_race_delay_ms,
# which stalls a mapping between the tree read and the set lookup. Each
# reader kind runs with an fsync started inside the stall: an O_DIRECT
# read, a buffered read of an evicted page, and a read fault through a
# mapping. Each must return the data.
#
# DISCRIMINATION: none for the re-lookup, and said so. Every reader here
# is serialised against conversion (O_DIRECT reads hold i_rwsem through
# DIO_LOCKING, buffered reads and faults hold invalidate_lock shared), so
# the fsync waits out the stall and nothing overlaps: with the re-lookup
# removed the suite passes the same. It is recorded per reader as
# raced=0/1; a raced=1 line means a reader stopped serialising, and from
# then on these assertions are what catch a missing re-lookup.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/pending_race_delay_ms ] || { skip "pending_race_delay_ms is missing"; ct_exit; }

IMG="$(ct_image 560 bprace)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bprace)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

OUT="$(ct_tmp bprace-out)"
python3 - "$MNT" >"$OUT" 2>&1 <<'PY' || true
import ctypes, mmap, os, sys, threading, time
libc = ctypes.CDLL(None, use_errno=True)
BS = 4096
mnt = sys.argv[1]
KNOB = "/sys/module/cetrafs/parameters/pending_race_delay_ms"

def knob(v):
    with open(KNOB, "w") as f:
        f.write(str(v))

def evict(fd):
    if libc.sync_file_range(fd, ctypes.c_longlong(0), ctypes.c_longlong(0), 7) != 0:
        print("SETUP sync_file_range failed", ctypes.get_errno()); sys.stdout.flush(); os._exit(0)
    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)

def read_direct(p, blk):
    fd = os.open(p, os.O_RDONLY | os.O_DIRECT)
    buf = mmap.mmap(-1, BS)
    os.preadv(fd, [buf], blk * BS)
    os.close(fd)
    return bytes(buf)

def read_buffered(p, blk):
    fd = os.open(p, os.O_RDONLY)
    b = os.pread(fd, BS, blk * BS)
    os.close(fd)
    return b

def read_fault(p, blk):
    fd = os.open(p, os.O_RDONLY)
    m = mmap.mmap(fd, 8 * BS, prot=mmap.PROT_READ)
    b = m[blk * BS:(blk + 1) * BS]
    m.close()
    os.close(fd)
    return b

for name, reader in (("direct", read_direct), ("buffered", read_buffered), ("fault", read_fault)):
    p = os.path.join(mnt, "f-" + name)
    fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o644)
    os.posix_fallocate(fd, 0, 8 * BS)
    os.fsync(fd)
    os.pwrite(fd, b"P" * BS, 5 * BS)
    evict(fd)
    got = {}
    t0 = time.monotonic()
    knob(1500)
    th = threading.Thread(target=lambda: got.setdefault("b", reader(p, 5)))
    th.start()
    time.sleep(0.4)                 # the reader is inside the stall
    os.fsync(fd)                    # converts block 5
    t_sync = time.monotonic() - t0
    th.join()
    knob(0)
    t_read = time.monotonic() - t0
    os.close(fd)
    b = got.get("b", b"")
    raced = t_sync < 1.2            # the fsync did not wait for the reader
    verdict = "data" if b == b"P" * BS else ("zeros" if b == bytes(BS) else "other")
    print("RESULT %s %s raced=%d sync=%.2f read=%.2f" % (name, verdict, raced, t_sync, t_read))
    sys.stdout.flush()
print("DONE")
PY
ct_param_set pending_race_delay_ms 0
log "$(tr '\n' ';' <"$OUT")"
grep -q '^SETUP' "$OUT" && { fail "setup: $(grep '^SETUP' "$OUT")"; ct_exit; }
grep -q '^DONE' "$OUT" || { fail "the workload did not finish: $(tail -3 "$OUT")"; ct_exit; }
while read -r _ name verdict raced _; do
    [ "$verdict" = data ] && pass "$name read during a conversion returns the data ($raced)" ||
        fail "$name read during a conversion returned $verdict ($raced) -- a converted block read as unwritten"
done < <(grep '^RESULT ' "$OUT")
grep -q '^RESULT .* raced=1' "$OUT" ||
    log "NOTE: no reader kind overlapped the conversion -- each held a lock the conversion waits for"

ct_umount "$MNT"
OUT2="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT2" && fail "fsck: $(grep '^ERR' <<<"$OUT2" | head -3)" || pass "fsck clean"
ct_exit
