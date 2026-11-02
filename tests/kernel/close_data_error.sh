#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a data write that fails before close is reported by close(2), not swallowed
#
# The last writer's close flushes the file's dirty pages and then
# publishes its size and extents and releases the lock. A failed flush
# was only logged: the publish went ahead, the close returned 0, and the
# file's extents named blocks that never received the data -- they read
# back whatever was there before, possibly another file's. The data
# cannot be retried (a failed writeback leaves the pages clean), so the
# chosen behaviour is the ext4 default: publish, and REPORT -- close(2)
# returns the error, through ->flush, which is the only file operation
# whose return value close(2) passes on (->release runs after it).
#
# The fault is a real write error on exactly the blocks the file's data
# is going to: dm-flakey with error_writes over the range FIEMAP reports
# for the still-unwritten pages, nothing else.
#
# DISCRIMINATION (measured on the unfixed code): writeback fails (-EIO,
# logged by the close) and close() returns 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_flakey 2>/dev/null || true

DEV="$(ct_failable_dev 560 closeerr)"
[ -n "$DEV" ] || { skip "device-mapper unavailable"; ct_exit; }
NAME="$(basename "$DEV")"
read -r _ SECTORS _ LOOP _ < <(dmsetup table "$NAME")
MNT="$(ct_mnt closeerr)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

dm_set() { # <table>
    dmsetup suspend --noflush --nolockfs "$NAME"
    dmsetup load "$NAME" --table "$1"
    dmsetup resume "$NAME"
}
LINEAR="0 $SECTORS linear $LOOP 0"

# writer <path> <ready> <go>: write 256 KiB buffered, print the FIEMAP
# extents of the dirty, not yet written pages, touch <ready>, wait for
# <go>, close, and print what close() said.
WRITER="$(mktemp /tmp/cetrafs-closeerr-XXXXXX.py)"
ct_track file "$WRITER"
cat >"$WRITER" <<'PY'
import errno, fcntl, os, struct, sys, time
path, ready, go = sys.argv[1:4]
fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
data = os.urandom(256 * 1024)
os.write(fd, data)
with open(ready + ".data", "wb") as f:
    f.write(data[:4096])
# struct fiemap: start, length, flags, mapped, count, reserved; then 32 extents of 56 bytes
N = 32
buf = bytearray(struct.pack("QQIIII", 0, 0xFFFFFFFFFFFFFFFF, 0, 0, N, 0) + b"\0" * (56 * N))
fcntl.ioctl(fd, 0xC020660B, buf)
mapped = struct.unpack_from("I", buf, 20)[0]
for i in range(mapped):
    lg, ph, ln = struct.unpack_from("QQQ", buf, 32 + 56 * i)
    print("extent %d %d %d" % (lg, ph, ln))
sys.stdout.flush()
open(ready, "w").close()
while not os.path.exists(go):
    time.sleep(0.05)
try:
    os.close(fd)
    print("close=0")
except OSError as e:
    print("close=" + errno.errorcode.get(e.errno, str(e.errno)))
sys.stdout.flush()
PY

# run_writer <file> <arm: yes|no>: one write session; with "yes" the
# file's data range fails writes while it closes.
run_writer() {
    local file="$1" arm="$2" ready go out pid i ph ln
    ready="$(mktemp -u /tmp/cetrafs-closeerr-ready-XXXXXX)"
    go="$(mktemp -u /tmp/cetrafs-closeerr-go-XXXXXX)"
    out="$(mktemp /tmp/cetrafs-closeerr-out-XXXXXX)"
    ct_track file "$ready"
    ct_track file "$go"
    ct_track file "$out"
    ct_track file "$ready.data"
    python3 -I "$WRITER" "$MNT/$file" "$ready" "$go" >"$out" 2>&1 &
    pid=$!
    for i in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.1; done
    [ -e "$ready" ] || { cat "$out" >&2; fail "setup: the writer never got its data written"; ct_exit; }
    EXTENTS="$(grep -c '^extent ' "$out" || true)"
    if [ "$arm" = yes ]; then
        read -r _ _ ph ln < <(grep '^extent ' "$out" | head -1)
        [ -n "${ph:-}" ] && [ "$ph" -gt 0 ] || { fail "setup: FIEMAP gave no physical extent for the dirty data"; ct_exit; }
        local s=$((ph / 512)) n=$((ln / 512))
        log "failing writes to the data extent: sectors $s..$((s + n - 1))"
        dm_set "0 $s linear $LOOP 0
$s $n flakey $LOOP $s 0 3600 1 error_writes
$((s + n)) $((SECTORS - s - n)) linear $LOOP $((s + n))"
    fi
    : >"$go"
    wait "$pid" || true
    [ "$arm" = yes ] && dm_set "$LINEAR"
    CLOSE="$(sed -n 's/^close=//p' "$out")"
    # Did the first block of the data reach the device?
    LANDED=no
    read -r _ _ ph _ < <(grep '^extent ' "$out" | head -1)
    if [ -n "${ph:-}" ] && cmp -s "$ready.data" <(dd if="$DEV" bs=4096 skip=$((ph / 4096)) count=1 iflag=direct status=none); then
        LANDED=yes
    fi
}

log "control: a clean write session closes with 0"
run_writer clean no
[ "$EXTENTS" -ge 1 ] || fail "setup: FIEMAP reported no extent for the dirty data"
[ "$CLOSE" = 0 ] && pass "a clean close returns 0" || fail "a clean close returned $CLOSE"
[ "$LANDED" = yes ] && pass "control: the clean session's data is on the device (the probe sees it)" ||
    fail "control: the clean session's data is not where FIEMAP said -- the landing probe proves nothing"

log "the file's data blocks fail writes while it closes"
run_writer victim yes
if [ "$LANDED" = no ]; then
    pass "setup: the data never reached its block on the device"
else
    fail "setup: the data is on the device -- the fault never hit the writeback"
fi
if [ "$CLOSE" = EIO ]; then
    pass "close(2) reported the lost data write: EIO"
else
    fail "close(2) returned '$CLOSE' after the file's data failed to reach the device"
fi

# The file was published and the lock released (the chosen behaviour):
# a new write-open must not be refused.
if python3 -I -c "import os,sys; os.close(os.open(sys.argv[1], os.O_WRONLY))" "$MNT/victim" 2>/dev/null; then
    pass "the lock was released: the file opens for write again"
else
    fail "the file cannot be opened for write after the failed close"
fi

umount "$MNT"
ct_exit
