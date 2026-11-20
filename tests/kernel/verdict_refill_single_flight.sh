#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock: an expired foreign-opener verdict is refilled once, and never fenced from the I/O path
#
# Under nofilelock every read and write asks "does a peer have this file
# open?", and the answer is cached for a second. When it expired, every
# task that asked read the device itself, all at once: a QD-32 reader paid
# one round trip per second per open image, in parallel (audit M-11). And
# the refill that found a stale peer's reader bit fenced that peer and
# cleared the bit from the I/O path, inside a read that had no business
# writing anything.
#
# Now the refill is single-flight, and a stale bit is counted as a reader
# and reclaimed by the heartbeat. Three phases, each with a control that
# puts the old behaviour back and must be caught:
#
#   1. single-flight: N readers meet one expired verdict while its refill
#      is stalled (verdict_fill_stall_ms). One refill, verdict_fills +1.
#      control: verdict_fill_unlocked=1 -- each reader refills, +N-ish.
#
#   2. no fence from the data path: a stale peer holds a reader bit on a
#      file this node reads. The read counts the bit and queues the
#      reclaim: reader_reclaims_deferred +1, verdict_fill_fences +0, and
#      the peer is not fenced by it.
#      control: verdict_fill_reclaims=1 -- the refill fences inline,
#      verdict_fill_fences +1.
#
#   3. the heartbeat finishes what the data path left: with the heartbeat's
#      reclaim running, the stale bit is cleared within a few ticks.
#
#   4. the default-mode reader's once-a-second file_seq check, the same
#      refill shape, is single-flight too: read_stamp_fills +1.
#      control: verdict_fill_unlocked=1 -- each reader refills.
#
# The bursts are BUFFERED reads of distinct, uncached pages: each is its
# own read_folio, which holds no inode lock. An O_DIRECT read cannot show
# the race -- blockdev_direct_IO's DIO_LOCKING holds the inode lock
# exclusively across a read's mapping, so one file's direct readers reach
# the verdict one at a time anyway.
#
# Node 1 and node 2 are staged as dead rows with a reader bit on the file
# (the way dead_reader_bit_awaits_replay.sh stages them). hb_replay_sweep_off
# holds the sweeps back, so only the reclaims under test can fence them.
#
# DISCRIMINATION: proven by the controls above. Phase 1 only fails when the
# refill is unsynchronised; phase 2 only fails when the refill fences.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in verdict_fill_stall_ms verdict_fill_unlocked verdict_fill_reclaims reader_reclaim_hb_off; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
LPOKE="$(ct_helper inode_lock_poke)"

MNT="$(ct_mnt vrsf)"
ct_track mnt "$MNT"
DEV="$(ct_dev 560 vrsf)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_param_set hb_interval_secs "$TEST_HB_SECS" # read at mount
ct_param_set auto_defrag 0
ct_param_set hb_replay_sweep_off 1
ct_param_set reader_reclaim_hb_off 1
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
for c in verdict_fills verdict_fill_fences reader_reclaims_deferred; do
    grep -q "^$c:" "$INFO" || { skip "no $c counter"; ct_exit; }
done
getc() { sed -n "s/^$1: //p" "$INFO"; }

# ---------------------------------------------------------------- phase 1
log "phase 1: single-flight refill"
dd if=/dev/urandom of="$MNT/a" bs=4096 count=8 conv=fsync status=none
OUT1="$(ct_tmp vrsf-p1)"
python3 - "$MNT/a" "$INFO" 6 >"$OUT1" 2>&1 <<'PY' || true
import mmap, os, sys, threading, time
path, info, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
STALL = "/sys/module/cetrafs/parameters/verdict_fill_stall_ms"

def counter(name):
    for line in open(info):
        if line.startswith(name + ":"):
            return int(line.split()[1])
    raise SystemExit("no %s counter" % name)

fd = os.open(path, os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_RANDOM)  # one read_folio per page, no readahead batch
def rd(off):
    os.pread(fd, 4096, off)
def drop():
    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
drop(); rd(0)                # setup: the verdict is now valid
time.sleep(1.3)                            # ...and a second old
a = counter("verdict_fills")
drop(); rd(0)
print("prime", counter("verdict_fills") - a, flush=True)
time.sleep(1.3)
open(STALL, "w").write("600")              # the first refill pauses after its device read
drop()
bar = threading.Barrier(n)
def reader(i):
    bar.wait()
    rd(i * 4096)
ts = [threading.Thread(target=reader, args=(i,)) for i in range(n)]
f0 = counter("verdict_fills")
t0 = time.monotonic()
for t in ts:
    t.start()
for t in ts:
    t.join()
print("fills", counter("verdict_fills") - f0, flush=True)
print("elapsed_ms", int((time.monotonic() - t0) * 1000), flush=True)
PY
log "$(tr '\n' ' ' <"$OUT1")"
PRIME="$(sed -n 's/^prime //p' "$OUT1")"
FILLS="$(sed -n 's/^fills //p' "$OUT1")"
ELAPSED="$(sed -n 's/^elapsed_ms //p' "$OUT1")"
[ "$PRIME" = 1 ] || { fail "setup: a read past the cache's second did not ask the device (fills +${PRIME:-?})"; ct_exit; }
[ -n "$ELAPSED" ] && [ "$ELAPSED" -ge 500 ] || { fail "setup: the stalled refill did not stall (elapsed ${ELAPSED:-?} ms)"; ct_exit; }
[ -n "$FILLS" ] || { fail "setup: the reader threads did not report"; ct_exit; }
[ "$FILLS" = 1 ] && pass "6 readers on one expired verdict made one refill (fills +1)" ||
    fail "6 readers on one expired verdict made $FILLS refills (the refill is not single-flight)"

# control: the unsynchronised refill, which every reader used to run
echo 1 >"$P/verdict_fill_unlocked"
sleep 1.3
OUT1C="$(ct_tmp vrsf-p1c)"
python3 - "$MNT/a" "$INFO" 6 >"$OUT1C" 2>&1 <<'PY' || true
import mmap, os, sys, threading, time
path, info, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
STALL = "/sys/module/cetrafs/parameters/verdict_fill_stall_ms"
def counter(name):
    for line in open(info):
        if line.startswith(name + ":"):
            return int(line.split()[1])
    raise SystemExit("no %s counter" % name)
fd = os.open(path, os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_RANDOM)  # one read_folio per page, no readahead batch
def rd(off):
    os.pread(fd, 4096, off)
def drop():
    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
open(STALL, "w").write("600")
drop()
bar = threading.Barrier(n)
def reader(i):
    bar.wait()
    rd(i * 4096)
ts = [threading.Thread(target=reader, args=(i,)) for i in range(n)]
f0 = counter("verdict_fills")
for t in ts:
    t.start()
for t in ts:
    t.join()
print("fills", counter("verdict_fills") - f0, flush=True)
PY
log "control (unsynchronised refill): $(tr '\n' ' ' <"$OUT1C")"
FILLS_C="$(sed -n 's/^fills //p' "$OUT1C")"
echo 0 >"$P/verdict_fill_unlocked"
[ -n "$FILLS_C" ] && [ "$FILLS_C" -ge 2 ] &&
    pass "control: with the refill unsynchronised the same readers refill $FILLS_C times -- the check discriminates" ||
    fail "control: the unsynchronised refill was not caught (fills ${FILLS_C:-?}); phase 1 proves nothing"
echo 0 >"$P/verdict_fill_stall_ms"

# ---------------------------------------------------------------- phase 2
log "phase 2: a verdict fill does not fence a stale peer"
dd if=/dev/urandom of="$MNT/b" bs=4096 count=4 conv=fsync status=none
B_INO="$(stat -c %i "$MNT/b")"
poke_dead_peer "$DEV" 1 aa
wait_out_stale_window
"$LPOKE" "$DEV" "$B_INO" --reader 1 >/dev/null
sync
sleep 1.3

# one direct read of block 0, past any cached verdict: asks the device for
# a verdict, which is where a stale bit is found
read_once() {
    python3 - "$1" <<'PY'
import mmap, os, sys
buf = mmap.mmap(-1, 4096)
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
os.preadv(fd, [buf], 0)
PY
}
F0="$(getc verdict_fills)"; D0="$(getc reader_reclaims_deferred)"; X0="$(getc verdict_fill_fences)"
read_once "$MNT/b"
F1="$(getc verdict_fills)"; D1="$(getc reader_reclaims_deferred)"; X1="$(getc verdict_fill_fences)"
log "read against a stale reader bit: fills +$((F1 - F0)), deferred +$((D1 - D0)), fences +$((X1 - X0))"
[ $((F1 - F0)) -ge 1 ] || { fail "setup: the read did not ask the device for a verdict"; ct_exit; }
[ $((D1 - D0)) -ge 1 ] || { fail "setup: the refill did not see node 1's stale bit (deferred +0)"; ct_exit; }
[ $((X1 - X0)) -eq 0 ] && pass "the I/O-path refill counted node 1's stale bit and fenced nothing (fences +0)" ||
    fail "the I/O-path refill fenced a stale peer (fences +$((X1 - X0)))"

# control: the refill fences inline, as it used to
echo 1 >"$P/verdict_fill_reclaims"
sleep 1.3
X0="$(getc verdict_fill_fences)"
read_once "$MNT/b"
X1="$(getc verdict_fill_fences)"
echo 0 >"$P/verdict_fill_reclaims"
[ $((X1 - X0)) -ge 1 ] && pass "control: with the inline reclaim the same read fences the peer (fences +$((X1 - X0))) -- the check discriminates" ||
    fail "control: the inline fence was not counted (fences +$((X1 - X0))); phase 2 proves nothing"

# ---------------------------------------------------------------- phase 3
log "phase 3: the heartbeat finishes the deferred reclaim"
echo 0 >"$P/reader_reclaim_hb_off"
dd if=/dev/urandom of="$MNT/c" bs=4096 count=4 conv=fsync status=none
C_INO="$(stat -c %i "$MNT/c")"
poke_dead_peer "$DEV" 2 bb
wait_out_stale_window
"$LPOKE" "$DEV" "$C_INO" --reader 2 >/dev/null
sync
sleep 1.3
D0="$(getc reader_reclaims_deferred)"
read_once "$MNT/c"
D1="$(getc reader_reclaims_deferred)"
[ $((D1 - D0)) -ge 1 ] || { fail "setup: the read did not queue node 2's stale bit (deferred +$((D1 - D0)))"; ct_exit; }
CLEARED=no
for _ in $(seq 1 30); do
    if "$LPOKE" "$DEV" "$C_INO" | grep -q 'readers=0x0$'; then
        CLEARED=yes
        break
    fi
    sleep 1
done
[ "$CLEARED" = yes ] && pass "the heartbeat fenced node 2 and cleared its reader bit" ||
    fail "node 2's reader bit was still set 30 s after the deferred reclaim was queued"

ct_param_set reader_reclaim_hb_off 0
ct_param_set verdict_fill_stall_ms 0
reset_stale_window
ct_umount "$MNT"

# ---------------------------------------------------------------- phase 4
# The same refill shape on the default-mode reader's file_seq check
# (cetrafs_inode_read_stamp_check()): once a second every reader without a
# local writer re-read the record, all at once.
log "phase 4: the reader's file_seq check is single-flight too"
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
grep -q "^read_stamp_fills:" "$INFO" || { skip "no read_stamp_fills counter"; ct_umount "$MNT"; ct_exit; }
dd if=/dev/urandom of="$MNT/d" bs=4096 count=8 conv=fsync status=none
# <unlocked 0|1> -> "fills N" "elapsed_ms N"
burst4() {
    echo "$1" >"$P/verdict_fill_unlocked"
    python3 - "$MNT/d" "$INFO" 6 <<'PY' || true
import mmap, os, sys, threading, time
path, info, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
STALL = "/sys/module/cetrafs/parameters/verdict_fill_stall_ms"
def counter(name):
    for line in open(info):
        if line.startswith(name + ":"):
            return int(line.split()[1])
    raise SystemExit("no %s counter" % name)
fd = os.open(path, os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_RANDOM)  # one read_folio per page, no readahead batch
def rd(off):
    os.pread(fd, 4096, off)
def drop():
    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
drop(); rd(0)
time.sleep(1.3)
open(STALL, "w").write("600")
drop()
bar = threading.Barrier(n)
def reader(i):
    bar.wait()
    rd(i * 4096)
ts = [threading.Thread(target=reader, args=(i,)) for i in range(n)]
f0 = counter("read_stamp_fills")
t0 = time.monotonic()
for t in ts:
    t.start()
for t in ts:
    t.join()
print("fills", counter("read_stamp_fills") - f0, flush=True)
print("elapsed_ms", int((time.monotonic() - t0) * 1000), flush=True)
PY
    echo 0 >"$P/verdict_fill_unlocked"
    echo 0 >"$P/verdict_fill_stall_ms"
}
R4="$(burst4 0)"
log "default mode: $(tr '\n' ' ' <<<"$R4")"
C4="$(burst4 1)"
log "control (unsynchronised): $(tr '\n' ' ' <<<"$C4")"
F4="$(sed -n 's/^fills //p' <<<"$R4")"
E4="$(sed -n 's/^elapsed_ms //p' <<<"$R4")"
FC4="$(sed -n 's/^fills //p' <<<"$C4")"
[ -n "$F4" ] && [ "$F4" -ge 1 ] && [ -n "$E4" ] && [ "$E4" -ge 500 ] ||
    { fail "setup: the readers' file_seq check did not refill, or did not stall ($R4)"; ct_umount "$MNT"; ct_exit; }
[ "$F4" = 1 ] && pass "6 readers on one expired file_seq check made one refill" ||
    fail "6 readers on one expired file_seq check made $F4 refills (not single-flight)"
[ -n "$FC4" ] && [ "$FC4" -ge 2 ] &&
    pass "control: unsynchronised, the same readers refill $FC4 times -- the check discriminates" ||
    fail "control: the unsynchronised file_seq refill was not caught (${FC4:-?}); phase 4 proves nothing"
ct_umount "$MNT"
ct_exit
