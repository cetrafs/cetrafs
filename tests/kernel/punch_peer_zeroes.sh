#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a punch or zero-range while a peer has the file open zeroes in place and succeeds
#
# A punch frees blocks, and freeing them while a peer has the file open
# is the hazard: its cached map may still name them (A-12). So a punch
# was refused EOPNOTSUPP there -- and qemu takes that as "this file
# cannot discard" and stops asking, for the rest of that qemu process: a
# guest's discards dropped and write-zeroes written as zeros through a
# migration, and for good on a VM a cancelled migration left on the
# source. ZERO_RANGE likewise.
#
# Now the range is zeroed in place (the device's WRITE ZEROES), and
# nothing is freed or allocated: zeroing blocks the file keeps is what
# write(2) does, which a peer in the file does not stop. Only where the
# device cannot zero in place is the punch still refused -- and that
# refusal now comes BEFORE the punch drains the file's direct I/O and
# takes its locks, which stalled every other I/O on the file per refused
# discard.
#
# Node 1 has "image" open (registered, beating, its read_open_nodes bit):
#   Z. punch 16 blocks, ZERO_RANGE 8 more: both succeed, both ranges read
#      zeros, every other block is unchanged, no block goes back to the
#      allocator, peer_zeroed moves by 2;
#   K. the peer HOLDS the file's lock (an exclusive claim, as a flock or
#      its mover's pin): refused EOPNOTSUPP as before, the data untouched;
#   E. no zeroing possible (zero_inplace_off): the punch is refused
#      EOPNOTSUPP at once -- under 1 s while an O_DIRECT overwrite holds
#      the file's lock 3 s (dio_overwrite_gap_ms) -- and
#      punch_early_refusals moves.
#
# DISCRIMINATION: peer_zero_refuse=1 (as before) -- Z's punch and
# ZERO_RANGE are refused EOPNOTSUPP and the data stays; punch_precheck_off
# =1 -- E's refusal waits out the held write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in peer_zero_refuse punch_precheck_off zero_inplace_off dio_overwrite_gap_ms lock_ignore_readers; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt ppz)"
ct_track mnt "$MNT"
ct_param_set peer_zero_refuse 0
ct_param_set punch_precheck_off 0
ct_param_set zero_inplace_off 0
ct_param_set dio_overwrite_gap_ms 0
ct_param_set lock_ignore_readers 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
counter() { sed -n "s/^$1: //p" "$INFO"; }

# fallocate <file> <mode> <first block> <blocks> -> "rc errno ms"
FALLOC="$(ct_tmp ppz-falloc)"
cat >"$FALLOC" <<'PY'
import ctypes, os, sys, time
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
t = time.monotonic()
r = libc.fallocate(f, int(sys.argv[2], 0), ctypes.c_long(int(sys.argv[3]) * 4096), ctypes.c_long(int(sys.argv[4]) * 4096))
e = ctypes.get_errno()
ms = int((time.monotonic() - t) * 1000)
os.close(f)
print("%d %d %d" % (r, e, ms))
PY
# blocks <file> -> one char per block of the first 64: z (zeros) or d (data)
BLOCKS="$(ct_tmp ppz-blocks)"
cat >"$BLOCKS" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print("".join("z" if d[i * 4096:(i + 1) * 4096] == b"\0" * 4096 else "d" for i in range(64)))
PY

# <tag> -> DEV, INFO, INO set; mounted, node 1 beating with the file open
setup() {
    local img
    img="$(ct_image 560 "ppz$1")"
    DEV="$(ct_loop "$img")"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    head -c $((64 * 4096)) /dev/urandom >"$MNT/image"
    sync
    INO="$(stat -c %i "$MNT/image")"
    ct_umount "$MNT"
    "$LOCK_POKE" "$DEV" "$INO" --reader 1 >/dev/null
    ct_mount "$DEV" "$MNT"
    INFO="$(ct_procdir "$DEV")/info"
    "$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    ct_beat_row "$DEV" 1
    # This node's own write-open past a live reader is the access rule's
    # (access_rule.sh); only the punch's check is under test here.
    echo 1 >$P/lock_ignore_readers
}
teardown() {
    echo 0 >$P/lock_ignore_readers
    ct_unbeat
    ct_umount "$MNT"
    "$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null
}

# <tag> <peer_zero_refuse 0|1> -> RES
zround() {
    local before after f0 f1 z0 p z sumrest0 sumrest1
    setup "$1"
    echo "$2" >$P/peer_zero_refuse
    before="$(python3 -I "$BLOCKS" "$MNT/image")"
    sumrest0="$(dd if="$MNT/image" bs=4096 skip=40 count=24 status=none | md5sum)"
    f0="$(counter free_data_blocks)"
    z0="$(counter peer_zeroed)"
    p="$(python3 -I "$FALLOC" "$MNT/image" 0x03 8 16)"  # PUNCH_HOLE|KEEP_SIZE
    z="$(python3 -I "$FALLOC" "$MNT/image" 0x11 28 8)"  # ZERO_RANGE|KEEP_SIZE
    echo 3 >/proc/sys/vm/drop_caches
    after="$(python3 -I "$BLOCKS" "$MNT/image")"
    sumrest1="$(dd if="$MNT/image" bs=4096 skip=40 count=24 status=none | md5sum)"
    f1="$(counter free_data_blocks)"
    echo 0 >$P/peer_zero_refuse
    RES="punch=${p// /,} zero=${z// /,} before=$before after=$after freed=$((f1 - f0)) zeroed=$(($(counter peer_zeroed) - z0))"
    RES="$RES rest=$([ "$sumrest0" = "$sumrest1" ] && echo same || echo changed)"
    teardown
}

# <tag> -> RES: the peer HOLDS the file's lock (its exclusive claim),
# planted after this node opened the file
kround() {
    local p
    setup "$1"
    p="$(python3 -I -c '
import ctypes, os, subprocess, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
subprocess.run([sys.argv[2], sys.argv[3], sys.argv[4], "1", "1"], check=True, stdout=subprocess.DEVNULL)
r = libc.fallocate(f, 3, ctypes.c_long(8 * 4096), ctypes.c_long(16 * 4096))
e = ctypes.get_errno()
os.close(f)
print("%d %d" % (r, e))' "$MNT/image" "$LOCK_POKE" "$DEV" "$INO")"
    "$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null # cleared first: a held lock refuses the read's open
    echo 3 >/proc/sys/vm/drop_caches
    RES="punch=${p// /,} after=$(python3 -I "$BLOCKS" "$MNT/image")"
    teardown
}

# <tag> <precheck_off 0|1> -> RES
eround() {
    local w e0 p
    setup "$1"
    echo 1 >$P/zero_inplace_off
    echo "$2" >$P/punch_precheck_off
    e0="$(counter punch_early_refusals)"
    echo 3000 >$P/dio_overwrite_gap_ms # the overwrite holds inode_lock (shared) 3 s
    # Both descriptors are opened BEFORE the write is held: an open
    # takes the file's lock too, and would hide the punch's wait.
    p="$(python3 -I -c '
import ctypes, mmap, os, sys, threading, time
libc = ctypes.CDLL("libc.so.6", use_errno=True)
w = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
f = os.open(sys.argv[1], os.O_RDWR)
b = mmap.mmap(-1, 4096); b.write(b"w" * 4096)
t = threading.Thread(target=lambda: os.pwritev(w, [b], 50 * 4096))
t.start()
time.sleep(0.5)
t0 = time.monotonic()
r = libc.fallocate(f, 3, ctypes.c_long(8 * 4096), ctypes.c_long(16 * 4096))
e = ctypes.get_errno()
ms = int((time.monotonic() - t0) * 1000)
t.join()
os.close(f); os.close(w)
print("%d %d %d" % (r, e, ms))' "$MNT/image")"
    echo 0 >$P/dio_overwrite_gap_ms
    echo 0 >$P/punch_precheck_off
    echo 0 >$P/zero_inplace_off
    RES="punch=${p// /,} early=$(($(counter punch_early_refusals) - e0))"
    teardown
}

zround z 0
Z="$RES"
log "Z (peer in the file): $Z"
zround r 1
R="$RES"
log "control (refused, as before): $R"
kround k
K="$RES"
log "K (the peer holds the file's lock): $K"
eround e 0
E="$RES"
log "E (no zeroing possible): $E"
eround l 1
L="$RES"
log "control (refused under the locks only, as before): $L"

# expected block maps: blocks 8..23 and 28..35 zero, the rest data
WANT="$(python3 -c 'print("".join("z" if 8 <= i < 24 or 28 <= i < 36 else "d" for i in range(64)))')"
[ "$(get before "$Z")" = "$(python3 -c 'print("d" * 64)')" ] ||
    { fail "setup: the image did not start as 64 blocks of data: $Z"; ct_exit; }
[ "$(get punch "$Z")" = "0,0,$(get punch "$Z" | cut -d, -f3)" ] && [ "$(get zero "$Z" | cut -d, -f1)" = 0 ] &&
    pass "Z: the punch and the zero-range succeeded with a peer in the file" ||
    fail "Z: punch/zero-range did not succeed: $Z"
[ "$(get after "$Z")" = "$WANT" ] && [ "$(get rest "$Z")" = same ] &&
    pass "Z: both ranges read zeros, every other block is unchanged" ||
    fail "Z: the image after: $(get after "$Z") (want $WANT), rest $(get rest "$Z")"
[ "$(get freed "$Z")" = 0 ] && [ "$(get zeroed "$Z")" = 2 ] &&
    pass "Z: nothing went back to the allocator; both answered by zeroing in place" ||
    fail "Z: freed=$(get freed "$Z") peer_zeroed=$(get zeroed "$Z") (want 0 and 2)"
[ "$(get punch "$R" | cut -d, -f2)" = 95 ] && [ "$(get zero "$R" | cut -d, -f2)" = 95 ] &&
    [ "$(get after "$R")" = "$(python3 -c 'print("d" * 64)')" ] && [ "$(get freed "$R")" = 0 ] &&
    pass "control: refused, both answered EOPNOTSUPP -- what qemu stops asking after" ||
    fail "control: the old refusal is not what the suite sees: $R"
[ "$(get punch "$K" | cut -d, -f2)" = 95 ] && [ "$(get after "$K")" = "$(python3 -c 'print("d" * 64)')" ] &&
    pass "K: a peer holding the file's lock still gets the refusal -- zeros under a move would be copied away" ||
    fail "K: with the peer's lock held: $K"
ems="$(get punch "$E" | cut -d, -f3)"
[ "$(get punch "$E" | cut -d, -f2)" = 95 ] && [ "$(get early "$E")" = 1 ] && [ "$ems" -lt 1000 ] &&
    pass "E: with no zeroing possible the punch is refused at once (${ems} ms, the file held 3 s by a write)" ||
    fail "E: $E"
lms="$(get punch "$L" | cut -d, -f3)"
[ "$(get punch "$L" | cut -d, -f2)" = 95 ] && [ "$(get early "$L")" = 0 ] && [ "$lms" -ge 2000 ] &&
    pass "control: refused under the locks only, the punch waited out the held write (${lms} ms)" ||
    fail "control: the refusal did not wait for the held write -- the suite does not reach the drain: $L"
ct_fsck "$DEV" >/dev/null && pass "fsck clean" || fail "fsck found faults"
ct_exit
