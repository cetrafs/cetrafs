#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an aligned O_DIRECT overwrite of written blocks runs under the SHARED inode_lock
#
# Every O_DIRECT write used to take inode_lock exclusively, and a
# synchronous writer (qemu aio=threads) then ran at queue depth 1 per
# image, whatever the array could do. ext4 and XFS take the shared lock for
# a block-aligned overwrite inside i_size of written blocks, and upgrade
# only for a hole, a preallocated block or an unaligned or extending write.
# cetrafs_dio_overwrite_write() does the same, and this suite proves four
# things about it:
#
#   classify   each case takes the shared path exactly when it should, by
#              the dio_overwrites counter (not by timing), and the data
#              reads back right either way;
#   gain       four writers over a 3 ms delay device run ~N times faster
#              shared than with dio_shared_overwrite=0 (the exclusive
#              control), with the same bytes on disk;
#   exclusion  a punch, a truncate or a defrag that starts while an
#              overwrite is inside its shared section completes only
#              AFTER the overwrite does, and the overwrite succeeds;
#   control    dio_overwrite_nolock=1 (the verdict taken with no lock) must
#              fail the exclusion check, for each of the three operations.
#              A check that passes with the lock removed proves nothing.
#
# The window is dio_overwrite_gap_ms: a TEST knob that pauses the overwrite
# after its mapping is checked, inside the shared section, so the other
# operation is certain to arrive while the lock is held.
#
# Why the shared lock is enough is argued at cetrafs_dio_overwrite_write()
# in kmod/file.c. In short: truncate, punch and the defrag mover all hold
# inode_lock exclusively, so none can run while the overwrite holds it. A
# block the shared path maps is written, and nothing that holds only
# invalidate_lock frees or remaps a written block.
#
# The classification counts only what is local. Under nofilelock a peer may
# change the file, which is a ctest matter (ctest/).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dio_shared_overwrite dio_overwrite_gap_ms dio_overwrite_nolock auto_defrag; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
[ -x "$ROOT/userspace/defrag.cetra" ] || { skip "defrag.cetra is not built"; ct_exit; }

ct_param_set auto_defrag 0
ct_param_set dio_overwrite_gap_ms 0
ct_param_set dio_overwrite_nolock 0
ct_param_set dio_shared_overwrite 1

DEV="$(ct_dev 560 dioshared)"
MNT="$(ct_mnt dioshared)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
[ -r "$INFO" ] || { fail "setup: no $INFO"; ct_exit; }

# ---- classify: the shared path is taken for exactly the eligible cases ----
#
# Each case is run with the shared path on (expect shared) and with it off
# (expect exclusive for all). The data is checked against a model the
# script keeps, read back buffered and through O_DIRECT.
CLASSIFY_PY='
import os, sys, mmap, ctypes, struct
MNT, INFO, shared_on = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
BS = 4096
def counter():
    for line in open(INFO):
        if line.startswith("dio_overwrites:"):
            return int(line.split(":")[1])
    raise SystemExit("setup: no dio_overwrites counter")
def abuf(n):
    b = mmap.mmap(-1, n + BS)
    return b, (-ctypes.addressof(ctypes.c_char.from_buffer(b))) % BS
def dwrite(path, data, off):
    fd = os.open(path, os.O_RDWR | os.O_DIRECT)
    b, o = abuf(len(data))
    b[o:o + len(data)] = data
    n = os.pwrite(fd, memoryview(b)[o:o + len(data)], off)
    os.close(fd)
    return n
def pat(tag, n):
    return (tag.encode() * (n // len(tag) + 1))[:n]
def readback(path, n, direct=False):
    fd = os.open(path, os.O_RDONLY | (os.O_DIRECT if direct else 0))
    b, o = abuf(max(n, BS))
    got = os.preadv(fd, [memoryview(b)[o:o + n]], 0)
    data = bytes(b[o:o + got])
    os.close(fd)
    return data
bad = []
def case(name, shared_expected, delta, ok):
    expect = shared_expected and shared_on
    got = delta
    if (got == 1) != expect or got not in (0, 1):
        bad.append("%s: expected %s, counter moved %d" % (name, "shared" if expect else "exclusive", got))
    if not ok:
        bad.append("%s: data does not read back" % name)
    print("case %s: %s counter+%d" % (name, "shared" if expect else "exclusive", got))

def prepare(name, nblk):
    p = os.path.join(MNT, name)
    if os.path.exists(p):
        os.unlink(p)
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
    os.write(fd, pat("W", nblk * BS))
    os.fsync(fd); os.close(fd)
    return p

# 1. aligned overwrite of written blocks, inside i_size: the shared case
p = prepare("aligned", 8)
want = bytearray(pat("W", 8 * BS))
c0 = counter(); data = pat("A", 4 * BS)
dwrite(p, data, 2 * BS); want[2 * BS:6 * BS] = data
d = counter() - c0
case("aligned_overwrite", True, d, readback(p, 8 * BS) == bytes(want) and readback(p, 8 * BS, True) == bytes(want))

# 2. unaligned overwrite (512-byte offset): exclusive, as before
p = prepare("unaligned", 8)
c0 = counter(); data = pat("U", 4096)
fd = os.open(p, os.O_RDWR | os.O_DIRECT); b, o = abuf(4096); b[o:o + 4096] = data
os.pwrite(fd, memoryview(b)[o:o + 4096], 512); os.close(fd)
want = bytearray(pat("W", 8 * BS)); want[512:512 + 4096] = data
d = counter() - c0
case("unaligned_overwrite", False, d, readback(p, 8 * BS) == bytes(want))

# 3. aligned write starting at EOF: an extension, exclusive
p = prepare("extend", 4)
c0 = counter(); data = pat("E", BS)
dwrite(p, data, 4 * BS)
d = counter() - c0
case("extending_write", False, d, readback(p, 5 * BS) == pat("W", 4 * BS) + data)

# 4. aligned overwrite of a preallocated (fallocate, never written) range
p = os.path.join(MNT, "uninit")
if os.path.exists(p): os.unlink(p)
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.posix_fallocate(fd, 0, 8 * BS); os.close(fd)
c0 = counter(); data = pat("P", 2 * BS)
dwrite(p, data, 2 * BS)
d = counter() - c0
want = bytearray(8 * BS); want[2 * BS:4 * BS] = data
case("preallocated_write", False, d, readback(p, 8 * BS) == bytes(want))

# 5. aligned write into a hole
p = os.path.join(MNT, "hole")
if os.path.exists(p): os.unlink(p)
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.ftruncate(fd, 8 * BS); os.pwrite(fd, pat("H", BS), 0); os.fsync(fd); os.close(fd)
c0 = counter(); data = pat("I", BS)
dwrite(p, data, 4 * BS)
d = counter() - c0
want = bytearray(8 * BS); want[0:BS] = pat("H", BS); want[4 * BS:5 * BS] = data
case("hole_write", False, d, readback(p, 8 * BS) == bytes(want))

# 6. aligned overwrite across written blocks and a hole
p = os.path.join(MNT, "mixed")
if os.path.exists(p): os.unlink(p)
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(fd, pat("M", 2 * BS), 0); os.ftruncate(fd, 8 * BS); os.fsync(fd); os.close(fd)
c0 = counter(); data = pat("X", 4 * BS)
dwrite(p, data, 0)
d = counter() - c0
want = bytearray(8 * BS); want[0:4 * BS] = data
case("written_then_hole", False, d, readback(p, 8 * BS) == bytes(want))

# 7. aligned overwrite of a block a buffered write left pending (no fsync)
p = os.path.join(MNT, "pending")
if os.path.exists(p): os.unlink(p)
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.posix_fallocate(fd, 0, 4 * BS)
os.pwrite(fd, pat("B", BS), BS)
# The buffered fd stays open: a close is a durability boundary that
# converts pending blocks, and the block must still be pending here.
c0 = counter(); data = pat("D", BS)
dwrite(p, data, BS)
d = counter() - c0
os.close(fd)
want = bytearray(4 * BS); want[BS:2 * BS] = data
case("pending_block", False, d, readback(p, 4 * BS) == bytes(want))

# 8. a write that would strip a security.capability xattr: exclusive, and
#    the strip still happens
p = prepare("caps", 4)
blob = struct.pack("<I4I", 0x02000000, 0, 0, 0, 0)  # vfs_cap_data, revision 2: 20 bytes
try:
    os.setxattr(p, "security.capability", blob)
    have_caps = True
except OSError as e:
    have_caps = False
    print("case capability_strip: skipped (%s)" % e.strerror)
if have_caps:
    c0 = counter(); data = pat("C", BS)
    dwrite(p, data, 0)
    d = counter() - c0
    stripped = True
    try:
        os.getxattr(p, "security.capability")
        stripped = False
    except OSError:
        pass
    case("capability_strip", False, d, readback(p, 4 * BS)[:BS] == data and stripped)
    if not stripped:
        bad.append("capability_strip: the security.capability xattr survived the write")

# 9. the same overwrite again, on a plain file: shared again
p = prepare("again", 8)
c0 = counter(); data = pat("Z", 2 * BS)
dwrite(p, data, 0)
d = counter() - c0
want = bytearray(pat("W", 8 * BS)); want[0:2 * BS] = data
case("plain_again", True, d, readback(p, 8 * BS) == bytes(want))

for b in bad:
    print("BAD " + b)
print("CLASSIFY_DONE bad=%d" % len(bad))
'
OUT="$(python3 -c "$CLASSIFY_PY" "$MNT" "$INFO" 1)" || true
log "classify (shared on): $(grep -c '^case' <<<"$OUT" || true) cases"
grep '^case' <<<"$OUT" || true
if grep -q '^CLASSIFY_DONE bad=0' <<<"$OUT"; then
    pass "classify: every case took the path it should, and every byte reads back"
else
    fail "classify: $(grep '^BAD' <<<"$OUT" | tr '\n' ';') $(grep -c '' <<<"$OUT" >/dev/null; grep '^CLASSIFY_DONE\|Traceback\|Error' <<<"$OUT" | tail -2 | tr '\n' ' ')"
fi
ct_param_set dio_shared_overwrite 0
OUT="$(python3 -c "$CLASSIFY_PY" "$MNT" "$INFO" 0)" || true
if grep -q '^CLASSIFY_DONE bad=0' <<<"$OUT"; then
    pass "control: with dio_shared_overwrite=0 every case is exclusive, and the data is the same"
else
    fail "control: $(grep '^BAD' <<<"$OUT" | tr '\n' ';') $(grep '^CLASSIFY_DONE\|Traceback\|Error' <<<"$OUT" | tail -2 | tr '\n' ' ')"
fi
ct_param_set dio_shared_overwrite 1

# ---- exclusion: punch / truncate / defrag vs an overwrite in its section ----
#
# The overwrite is held inside the shared section for 1500 ms. The other
# operation starts 400 ms in. Correct: it cannot run until the overwrite
# has finished, so its end comes after the overwrite's, and the overwrite
# succeeded. The nolock control removes the lock: the operation runs
# inside the window, and the overwrite either fails or the operation
# visibly finished first.
RACE_PY='
import os, sys, time, ctypes, subprocess, threading, mmap
MNT, INFO, op, defrag, gap_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
BS = 4096
A = b"A" * BS; B = b"B" * BS
def counter():
    for line in open(INFO):
        if line.startswith("dio_overwrites:"):
            return int(line.split(":")[1])
def abuf(n):
    b = mmap.mmap(-1, n + BS)
    return b, (-ctypes.addressof(ctypes.c_char.from_buffer(b))) % BS
p = os.path.join(MNT, "race_" + op)
if os.path.exists(p): os.unlink(p)
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
os.write(fd, A * 8); os.fsync(fd); os.close(fd)
res = {}
def overwrite():
    fd = os.open(p, os.O_RDWR | os.O_DIRECT)
    b, o = abuf(8 * BS)
    b[o:o + 8 * BS] = B * 8
    res["t0"] = time.monotonic()
    c0 = counter()
    try:
        res["rc"] = os.pwrite(fd, memoryview(b)[o:o + 8 * BS], 0)
    except OSError as e:
        res["rc"] = -e.errno
    # The end is when the write returned, before the counter read: the
    # operation may run the moment the section is left, and a read after
    # it put a correct order 1 ms the wrong way round.
    res["t1"] = time.monotonic()
    res["delta"] = counter() - c0
    os.close(fd)
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
def other():
    time.sleep(0.4)
    res["o0"] = time.monotonic()
    if op == "punch":
        fd = os.open(p, os.O_RDWR)
        rc = libc.fallocate(fd, 0x01 | 0x02, 0, 8 * BS)  # PUNCH_HOLE | KEEP_SIZE
        os.close(fd)
        res["oerr"] = 0 if rc == 0 else ctypes.get_errno()
    elif op == "truncate":
        os.truncate(p, 0)
        res["oerr"] = 0
    elif op == "defrag":
        r = subprocess.run([defrag, p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        res["oerr"] = r.returncode
    res["o1"] = time.monotonic()
w = threading.Thread(target=overwrite); o = threading.Thread(target=other)
w.start(); o.start(); w.join(); o.join()
print("RESULT rc=%d delta=%d overwrite_s=%.3f op_start_s=%.3f op_end_s=%.3f op_err=%d" % (
    res["rc"], res["delta"], res["t1"] - res["t0"], res["o0"] - res["t0"], res["o1"] - res["t0"], res["oerr"]))
fd = os.open(p, os.O_RDONLY)
size = os.fstat(fd).st_size
data = os.pread(fd, 8 * BS, 0) if size else b""
os.close(fd)
if op == "punch":
    want = b"\0" * (8 * BS)
elif op == "truncate":
    want = b""
else:
    want = B * 8
print("DATA %s size=%d" % ("ok" if data == want else "BAD", size))
print("RACE_DONE")
'
race() {
    local op="$1" gap="$2" OUT RC=0
    ct_param_set dio_overwrite_gap_ms "$gap"
    OUT="$(python3 -c "$RACE_PY" "$MNT" "$INFO" "$op" "$ROOT/userspace/defrag.cetra" 1.5)" || RC=$?
    ct_param_set dio_overwrite_gap_ms 0
    RACE_OUT="$OUT"
    RACE_RC=$RC
}
for op in punch truncate defrag; do
    race "$op" 1500
    RES="$(grep '^RESULT' <<<"$RACE_OUT" || true)"
    DATA="$(grep '^DATA' <<<"$RACE_OUT" || true)"
    # setup: the overwrite must have entered its section and sat there
    SETUP_OK=0
    case "$RES" in *"delta=1 "*) SETUP_OK=1 ;; esac
    OVW="$(sed -n 's/.*overwrite_s=\([0-9.]*\).*/\1/p' <<<"$RES")"
    if [ "$SETUP_OK" = 1 ] && awk -v s="${OVW:-0}" 'BEGIN { exit !(s >= 1.3) }'; then
        pass "race/$op setup: the overwrite took the shared path and held it for the window ($RES)"
    else
        fail "race/$op setup: the overwrite did not reach the shared section long enough -- $RES $DATA"
        ct_exit
    fi
    case "$RES" in
        *"rc=32768 "*) RCOK=1 ;; *) RCOK=0 ;;
    esac
    # Both times are from the overwrite's start: the operation must end
    # no earlier than the overwrite does.
    OPEND="$(sed -n 's/.*op_end_s=\([0-9.]*\).*/\1/p' <<<"$RES")"
    if [ "$RCOK" = 1 ] && awk -v op="${OPEND:-0}" -v ow="${OVW:-0}" 'BEGIN { exit !(op >= ow) }' && grep -q '^DATA ok' <<<"$DATA"; then
        pass "race/$op: the overwrite succeeded, $op finished after it, and the data is what the order says"
    else
        fail "race/$op: the operation ran inside the overwrite's section, or the data is wrong -- $RES $DATA"
    fi
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null && pass "race/$op: fsck clean" || fail "race/$op: fsck found faults"
    ct_mount "$DEV" "$MNT"
done

# Negative control: the same races with the lock removed. The operation
# must get inside the window -- finish before the overwrite does -- or the
# overwrite must fail. Either is the failure the lock exists to prevent.
ct_param_set dio_overwrite_nolock 1
for op in punch truncate defrag; do
    race "$op" 1500
    RES="$(grep '^RESULT' <<<"$RACE_OUT" || true)"
    OPEND="$(sed -n 's/.*op_end_s=\([0-9.]*\).*/\1/p' <<<"$RES")"
    OVW="$(sed -n 's/.*overwrite_s=\([0-9.]*\).*/\1/p' <<<"$RES")"
    RCBAD=0
    case "$RES" in *"rc=32768 "*) ;; *) RCBAD=1 ;; esac
    if [ "$RCBAD" = 1 ] || awk -v op="${OPEND:-0}" -v ow="${OVW:-0}" 'BEGIN { exit !(op < ow) }'; then
        pass "control/nolock/$op: with the lock removed the operation got inside the window and the check catches it ($RES)"
    else
        fail "control/nolock/$op: with the lock removed the check still passed -- it cannot discriminate ($RES)"
    fi
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
done
ct_param_set dio_overwrite_nolock 0

# ---- gain: N writers over a delay device, shared vs exclusive ----
#
# A 3 ms per-I/O delay stands in for a SAN. Four writers each overwrite
# their own blocks synchronously. Exclusive, the device sees one write at a
# time; shared, it sees four. The wall time ratio is the measurement, and
# the counter confirms which path ran.
GAIN_PY='
import os, sys, time, mmap, ctypes, multiprocessing as mp
MNT, INFO, shared_on, nproc, nblk, rounds = sys.argv[1], sys.argv[2], sys.argv[3] == "1", int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
BS = 4096
def counter():
    for line in open(INFO):
        if line.startswith("dio_overwrites:"):
            return int(line.split(":")[1])
def stamp(i, r, k):
    return (b"W%03d.%03d.%06d;" % (i, r, k)).ljust(BS, b"-")
def worker(args):
    i, path = args
    fd = os.open(path, os.O_RDWR | os.O_DIRECT)
    m = mmap.mmap(-1, BS + BS)
    o = (-ctypes.addressof(ctypes.c_char.from_buffer(m))) % BS
    for r in range(rounds):
        for k in range(nblk):
            m[o:o + BS] = stamp(i, r, k)
            n = os.pwrite(fd, memoryview(m)[o:o + BS], (i * nblk + k) * BS)
            if n != BS:
                os._exit(3)
    os.close(fd)
    return 0
if __name__ == "__main__":
    p = os.path.join(MNT, "gain")
    if os.path.exists(p): os.unlink(p)
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
    os.write(fd, b"\0" * (nproc * nblk * BS)); os.fsync(fd); os.close(fd)
    c0 = counter()
    t0 = time.monotonic()
    with mp.Pool(nproc) as pool:
        rcs = pool.map(worker, [(i, p) for i in range(nproc)])
    el = time.monotonic() - t0
    d = counter() - c0
    bad = 0
    fd = os.open(p, os.O_RDONLY)
    for i in range(nproc):
        for k in range(nblk):
            got = os.pread(fd, BS, (i * nblk + k) * BS)
            if got != stamp(i, rounds - 1, k):
                bad += 1
    os.close(fd)
    print("GAIN elapsed_s=%.3f delta=%d writes=%d bad=%d rcs=%s" % (el, d, nproc * nblk * rounds, bad, ",".join(map(str, rcs))))
'
if [ -z "${CT_NO_DELAY:-}" ] && command -v dmsetup >/dev/null 2>&1; then
    ct_umount "$MNT" >/dev/null 2>&1 || true
    DDEV="$(ct_delay_dev 560 3 dioshared)"
    if [ -z "$DDEV" ]; then
        skip "gain: dm-delay is not available"
    else
        DMNT="$(ct_mnt dioshared_gain)"
        ct_mkfs_small "$DDEV" >/dev/null
        ct_mount "$DDEV" "$DMNT"
        require_cetrafs_mount "$DMNT"
        DINFO="$(ct_procdir "$DDEV")/info"
        ct_param_set auto_defrag 0
        for mode in 1 0; do
            ct_param_set dio_shared_overwrite "$mode"
            OUT="$(python3 -c "$GAIN_PY" "$DMNT" "$DINFO" "$mode" 4 40 3)" || true
            if [ "$mode" = 1 ]; then SHARED_OUT="$OUT"; else EXCL_OUT="$OUT"; fi
        done
        ct_param_set dio_shared_overwrite 1
        S_EL="$(sed -n 's/^GAIN elapsed_s=\([0-9.]*\).*/\1/p' <<<"$SHARED_OUT")"
        E_EL="$(sed -n 's/^GAIN elapsed_s=\([0-9.]*\).*/\1/p' <<<"$EXCL_OUT")"
        S_D="$(sed -n 's/.*delta=\([0-9]*\).*/\1/p' <<<"$SHARED_OUT")"
        E_D="$(sed -n 's/.*delta=\([0-9]*\).*/\1/p' <<<"$EXCL_OUT")"
        S_BAD="$(sed -n 's/.*bad=\([0-9]*\).*/\1/p' <<<"$SHARED_OUT")"
        E_BAD="$(sed -n 's/.*bad=\([0-9]*\).*/\1/p' <<<"$EXCL_OUT")"
        log "gain: shared ${S_EL:-?}s (counter ${S_D:-?}), exclusive ${E_EL:-?}s (counter ${E_D:-?}), 4 writers x 40 x 3 rounds at 3 ms"
        if [ -n "$S_EL" ] && [ -n "$E_EL" ] && [ "${S_D:-x}" = 480 ] && [ "${E_D:-x}" = 0 ] && [ "${S_BAD:-x}" = 0 ] && [ "${E_BAD:-x}" = 0 ]; then
            pass "gain: the shared path carried all 480 writes and the exclusive control none, with every byte right"
        else
            fail "gain: counts or data wrong -- shared [$SHARED_OUT] exclusive [$EXCL_OUT]"
        fi
        if [ -n "$S_EL" ] && [ -n "$E_EL" ] && awk -v s="$S_EL" -v e="$E_EL" 'BEGIN { exit !(e / s >= 2.0) }'; then
            pass "gain: shared is $(awk -v s="$S_EL" -v e="$E_EL" 'BEGIN { printf "%.1f", e / s }')x the exclusive control"
        else
            fail "gain: shared ${S_EL:-?}s is not at least 2x faster than exclusive ${E_EL:-?}s"
        fi
        ct_umount "$DMNT" >/dev/null 2>&1 || true
    fi
fi

ct_exit
