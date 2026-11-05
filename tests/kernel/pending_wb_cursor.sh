#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a buffered write into preallocated space is judged by its own writeback, not another's
#
# Buffered writes into preallocated space stay "reads as zeros" until
# fsync/close converts them; a writeback error since the pending set
# began drops the set (its blocks keep reading as zeros; the error is
# reported). "Since" has two wrong answers, one each way:
#  - errseq_sample() is 0 while an older error on the file is UNSEEN,
#    so that old error read as the set's own and good data was dropped
#    (audit F8);
#  - the raw value: errseq_set() moves the counter only after the old
#    error was seen, so the set's own failure with the same errno left
#    the value unchanged, read as clean, and the set was CONVERTED over
#    blocks whose data never landed -- they read back whatever the
#    device held (audit F11).
# The set now consumes the unseen state into its cursor at its start.
#
# Each case on a fresh file, with an unseen EIO on its block 0 first
# (a writeback started and never waited on):
#  A:  the device heals, then the set's write lands: it must read back.
#  A2: the device still fails the set's block too: it must read as
#      zeros, not as the 'S' planted under it.
#  B:  no older error; the set's own write fails: zeros, not 'S'.
#
# Every write that is meant to fail is started (sync_file_range) and
# left to fail, then the device heals BEFORE fsync and close: dm-flakey
# fails the empty FLUSH bio too, and a failed flush in the conversion
# drops the set on its own, so only a healed device leaves the verdict
# to the cursor.
#
# DISCRIMINATION: A fails with errseq_sample() as the cursor (block
# dropped); A2 fails with the raw value as the cursor (the 'S' is read).
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

dm_set() {
    dmsetup suspend --noflush --nolockfs "$NAME"
    dmsetup load "$NAME" --table "$1"
    dmsetup resume "$NAME"
}
heal() { dm_set "0 $SECTORS linear $LOOP 0"; }
# fail_blocks <fs block>...: writes to those 4 KiB blocks fail.
fail_blocks() {
    local t="" at=0 b x
    for b in $(printf '%s\n' "$@" | sort -n); do
        x=$((b * 8))
        [ "$x" -gt "$at" ] && t="$t$at $((x - at)) linear $LOOP $at
"
        t="$t$x 8 flakey $LOOP $x 0 3600 1 error_writes
"
        at=$((x + 8))
    done
    t="$t$at $((SECTORS - at)) linear $LOOP $at"
    dm_set "$t"
}
phys() { filefrag -v -b4096 "$1" | awk -F: -v l="$2" '$1 ~ /^ *[0-9]+$/ { split($2, a, "[.]+"); split($3, p, "[.]+"); if (l >= a[1] && l <= a[2]) print p[1] + l - a[1] }'; }

# run_case <name> <old error: 0|1> <set fails: 0|1>: prints what block 16 reads as.
run_case() {
    local f="$MNT/$1" p0 p16 out go ready
    if [ "$2" = 1 ]; then dd if=/dev/urandom of="$f" bs=4096 count=1 conv=fsync status=none; fi
    fallocate -o $((16 * 4096)) -l 4096 "$f"
    sync
    p16="$(phys "$f" 16)"
    [ -n "$p16" ] || { echo "SETUP no physical block for block 16"; return; }
    head -c 4096 /dev/zero | tr '\0' S | dd of="$DEV" bs=4096 seek="$p16" count=1 conv=fsync status=none
    p0=""
    [ "$2" = 1 ] && p0="$(phys "$f" 0)"
    out="$(ct_tmp pwbc-out)"; go="$(ct_tmp pwbc-go)"; ready="$(ct_tmp pwbc-ready)"
    rm -f "$go" "$ready"
    python3 - "$f" "$go" "$ready" "$2" "$3" >"$out" 2>&1 <<'PY' &
import ctypes, os, sys, time
libc = ctypes.CDLL(None, use_errno=True)
f, go, ready, old, setfail = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5] == "1"
def wait(p):
    while not os.path.exists(p):
        time.sleep(0.05)
fd = os.open(f, os.O_RDWR)
if old:
    os.pwrite(fd, b"N" * 4096, 0)
open(ready, "w").close(); wait(go)
if old:
    # sync_file_range(WRITE) = 2: start it, never wait -- the error
    # stays UNSEEN (a wait or an fsync would report and mark it).
    libc.sync_file_range(fd, ctypes.c_longlong(0), ctypes.c_longlong(4096), 2)
    time.sleep(2)
open(ready + "1", "w").close(); wait(go + "1")
os.pwrite(fd, b"P" * 4096, 16 * 4096)          # the set begins here
if setfail:
    # The set's own writeback, failed while the device still fails it,
    # and NOT waited on -- as block 0's above. The folio ends writeback
    # clean on the error, so the fsync below has nothing left to send.
    libc.sync_file_range(fd, ctypes.c_longlong(16 * 4096), ctypes.c_longlong(4096), 2)
    time.sleep(2)
# The device heals before anything converts: dm-flakey fails the empty
# FLUSH bio too, and a conversion whose cache flush fails drops the set
# by itself -- which would decide the case instead of the cursor,
# wherever the conversion runs (fsync or close).
open(ready + "2", "w").close(); wait(go + "2")
try:
    os.fsync(fd); print("FSYNC ok")
except OSError as e:
    print("FSYNC", e.errno)
try:
    os.close(fd)
except OSError:
    pass
PY
    local py=$!
    ct_track file "$go"1; ct_track file "$ready"1; ct_track file "$go"2; ct_track file "$ready"2
    wait_for 10 '[ -e "$ready" ]' || { echo "SETUP writer did not start"; kill -9 $py; return; }
    if [ "$2" = 1 ] && [ "$3" = 1 ]; then fail_blocks "$p0" "$p16"
    elif [ "$2" = 1 ]; then fail_blocks "$p0"
    else fail_blocks "$p16"; fi
    touch "$go"
    wait_for 20 '[ -e "${ready}1" ]' || { echo "SETUP no return from the writeback"; kill -9 $py; heal; return; }
    [ "$3" = 1 ] || heal
    touch "$go"1
    wait_for 20 '[ -e "${ready}2" ]' || { echo "SETUP the set's writeback never returned"; kill -9 $py; heal; return; }
    heal
    touch "$go"2
    wait "$py" || true
    echo 3 >/proc/sys/vm/drop_caches
    echo "WRITER $(tr '\n' ' ' <"$out")"
    echo "READS $(dd if="$f" bs=4096 skip=16 count=1 status=none | tr -d '\0' | head -c 1)"
}

judge() { # <name> <output> <expect: P|zeros>
    local w r
    grep -q '^SETUP' <<<"$2" && { fail "setup ($1): $(grep '^SETUP' <<<"$2")"; return; }
    w="$(sed -n 's/^WRITER //p' <<<"$2")"
    r="$(sed -n 's/^READS //p' <<<"$2")"
    log "$1: writer: $w; block 16 reads '${r:-<zeros>}'"
    case "$1" in A*) grep -q "FSYNC 5" <<<"$w" ||
        { fail "setup ($1): fsync did not report the older unseen error -- nothing was unseen ($w)"; return; } ;; esac
    if [ "$3" = P ]; then
        [ "$r" = P ] && pass "$1: the set's write landed and reads back, an older unseen error notwithstanding" ||
            fail "$1: a write that reached the device was dropped (reads '${r:-<zeros>}')"
    else
        [ -z "$r" ] && pass "$1: the set's own write failed, and its block reads as zeros" ||
            fail "$1: the set was converted over a block whose write failed -- it reads '$r'"
    fi
}

judge A "$(run_case fa 1 0)" P
judge A2 "$(run_case fb 1 1)" zeros
judge B "$(run_case fc 0 1)" zeros
ct_umount "$MNT"
ct_exit
