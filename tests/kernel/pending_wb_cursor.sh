#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an old, unseen writeback error does not cost a later buffered write its data
#
# Buffered writes into preallocated space stay "reads as zeros" until
# fsync/close converts them, and a writeback error since the pending set
# began drops the whole set (its blocks keep reading as zeros; the error
# is reported). "Since" was sampled with errseq_sample(), which returns 0
# while an earlier error is still UNSEEN -- so an old error on another
# block of the file, one nobody had fsync'd yet, read as this set's, and
# a write that reached the device was thrown away (audit F8).
#
# Staged on a dm device: block 0 written and its writeback failed (no
# fsync, so the error stays unseen); the device healed; then a buffered
# write into a preallocated block and an fsync. That block must read
# back as written.
#
# DISCRIMINATION: the setup check requires the writeback of block 0 to
# have failed. The reverted-fix control (errseq_sample() restored in
# cetrafs_pending_add()) has not been run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_flakey 2>/dev/null || true
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_exit; }

DEV="$(ct_failable_dev 560 pwbc)"
[ -n "$DEV" ] || { skip "device-mapper unavailable"; ct_exit; }
NAME="$(basename "$DEV")"
read -r _ SECTORS _ LOOP _ < <(dmsetup table "$NAME")
MNT="$(ct_mnt pwbc)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

dd if=/dev/urandom of="$MNT/f" bs=4096 count=1 conv=fsync status=none
fallocate -o $((16 * 4096)) -l $((16 * 4096)) "$MNT/f"
sync
P0="$(filefrag -v -b4096 "$MNT/f" | awk -F: '$1 ~ /^ *0$/ { split($3, a, "[.]+"); print a[1] + 0 }')"
[ -n "$P0" ] && [ "$P0" -gt 0 ] || { fail "setup: no physical block for block 0"; ct_exit; }
X=$((P0 * 8))
log "block 0 is at fs block $P0 (sector $X)"

dm_set() {
    dmsetup suspend --noflush --nolockfs "$NAME"
    dmsetup load "$NAME" --table "$1"
    dmsetup resume "$NAME"
}
OUT="$(ct_tmp pwbc-out)"
GO="$(ct_tmp pwbc-go)"; rm -f "$GO"
READY="$(ct_tmp pwbc-ready)"; rm -f "$READY"
python3 - "$MNT/f" "$GO" "$READY" >"$OUT" 2>&1 <<'PY' &
import ctypes, os, sys, time
libc = ctypes.CDLL(None, use_errno=True)
f, go, ready = sys.argv[1:4]
fd = os.open(f, os.O_RDWR)
os.pwrite(fd, b"N" * 4096, 0)                      # block 0, overwrite
open(ready, "w").close()
while not os.path.exists(go):
    time.sleep(0.05)
# Write block 0 back while the device fails it; no fsync: the error
# stays unseen in the mapping's cursor.
# sync_file_range(WRITE) = 2: start the writeback and do NOT wait --
# waiting (or fsync) reports the error and marks it seen, and an error
# seen is exactly the case the old sampling already handled.
r = libc.sync_file_range(fd, ctypes.c_longlong(0), ctypes.c_longlong(4096), 2)
time.sleep(2)
print("SFR", "ok" if r == 0 else ctypes.get_errno(), flush=True)
open(ready + ".2", "w").close()
while not os.path.exists(go + ".2"):
    time.sleep(0.05)
os.pwrite(fd, b"P" * 4096, 16 * 4096)              # into preallocated space
try:
    os.fsync(fd)
    print("FSYNC ok")
except OSError as e:
    print("FSYNC", e.errno)
os.close(fd)
PY
PY_PID=$!
wait_for 10 '[ -e "$READY" ]' || { fail "setup: the writer never started"; ct_exit; }
dm_set "0 $X linear $LOOP 0
$X 8 flakey $LOOP $X 0 3600 1 error_writes
$((X + 8)) $((SECTORS - X - 8)) linear $LOOP $((X + 8))"
touch "$GO"
wait_for 20 '[ -e "$READY.2" ]' || { fail "setup: the writeback of block 0 never returned: $(cat "$OUT")"; ct_exit; }
dm_set "0 $SECTORS linear $LOOP 0"
touch "$GO.2"
wait "$PY_PID" || true
log "writer: $(tr '\n' ';' <"$OUT")"
# The old error must have stayed unseen until the fsync, which then
# reports it: an fsync that says ok means it was seen (or never there).
grep -q "^FSYNC 5" "$OUT" ||
    { fail "setup: the fsync did not report block 0's failed writeback ($(tr '\n' ' ' <"$OUT")) -- nothing was unseen"; ct_exit; }

echo 3 >/proc/sys/vm/drop_caches
B16="$(dd if="$MNT/f" bs=4096 skip=16 count=1 status=none | tr -d 'P' | wc -c)"
[ "$B16" = 0 ] && pass "the buffered write into preallocated space survived an older unseen error" ||
    fail "the block written after the old error reads back wrong ($B16 bytes not 'P') -- dropped as if the error were its own"

# B: the set's OWN write fails. Nothing in the set may be converted: the
# block keeps reading as zeros -- not as whatever the device held under
# it, which is planted as 'S' so a wrong conversion shows.
fallocate -o $((64 * 4096)) -l 4096 "$MNT/g"
sync
P64="$(filefrag -v -b4096 "$MNT/g" | awk -F: '$1 ~ /^ *0$/ { split($3, a, "[.]+"); print a[1] + 0 }')"
[ -n "$P64" ] && [ "$P64" -gt 0 ] || { fail "setup: no physical block for g's preallocated block"; ct_exit; }
head -c 4096 /dev/zero | tr '\0' S | dd of="$DEV" bs=4096 seek="$P64" count=1 conv=fsync status=none 2>/dev/null
Y=$((P64 * 8))
dm_set "0 $Y linear $LOOP 0
$Y 8 flakey $LOOP $Y 0 3600 1 error_writes
$((Y + 8)) $((SECTORS - Y - 8)) linear $LOOP $((Y + 8))"
RCB="$(python3 -c 'import os,sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b"Q" * 4096, 64 * 4096)
try:
    os.fsync(fd); print("ok")
except OSError as e:
    print(e.errno)
try:
    os.close(fd)
except OSError:
    pass' "$MNT/g")"
dm_set "0 $SECTORS linear $LOOP 0"
echo 3 >/proc/sys/vm/drop_caches
G="$(dd if="$MNT/g" bs=4096 skip=64 count=1 status=none | tr -d '\0' | head -c 8)"
log "B: fsync=$RCB; the block reads '${G:-<zeros>}'"
[ "$RCB" = 5 ] || { fail "setup: the set's own write did not fail (fsync $RCB)"; ct_exit; }
[ -z "$G" ] && pass "B: a set whose own write failed is not converted -- the block reads as zeros" ||
    fail "B: a set whose own write failed was converted: the block reads '$G'"
ct_umount "$MNT"
ct_exit
