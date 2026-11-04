#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a shrinking truncate while a converting O_DIRECT write is in flight
#
# An O_DIRECT write into preallocated space converts what it wrote at
# completion, and takes mapping->invalidate_lock to do it, before its
# in-flight count drops (cetrafs_dio_end_io()). A truncate that shrinks
# has to wait for in-flight direct I/O before it frees blocks -- and it
# waited while already holding invalidate_lock: the truncate waited for
# the completion, the completion waited for the lock, both in D state,
# reboot required. Punch, defrag and the lock suspend had been reordered
# to drain first; truncate had not.
#
# The write is held in flight on a device that delays writes, and the
# truncate is issued from the same process right behind it
# (tests/helpers/dio_aio trunc). The setup asserts the write had NOT
# completed when the truncate started and that its completion converted
# blocks -- the completion that takes the lock.
#
# NO NEGATIVE CONTROL: with the old order the truncate and the
# completion both sleep uninterruptibly and the test box needs a reboot,
# as for the punch in dio_no_fallback.sh. What stands in for one: the
# setup assertions (the write WAS in flight and DID convert), and
# source_invariants.sh, which flags the old order by name. A hang is
# detected by deadline, because `timeout` cannot kill a task in D state.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dio_fill_holes ] || { skip "dio_fill_holes is missing"; ct_exit; }

AIO="$(ct_helper dio_aio)"
DEV="$(ct_delay_dev 560 0 diotrunc)"
[ -n "$DEV" ] || { skip "dm-delay is not available"; ct_exit; }
MNT="$(ct_mnt diotrunc)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
ctr() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$INFO"; }
ct_param_set auto_defrag 0
ct_param_set dio_fill_holes 1

# NEWMS=<ms> set_write_delay: delay writes only. Reads stay instant, so the
# truncate's own record reads do not stretch the run. The table reads
# "0 <sectors> delay <dev> <off> <ms> [<wdev> <woff> <wms>]".
NAME="$(basename "$DEV")"
set_write_delay() {
    local t
    t="$(dmsetup table "$NAME")"
    # shellcheck disable=SC2086 # split the table into its fields
    set -- $t
    dmsetup suspend --nolockfs "$NAME"
    dmsetup load "$NAME" --table "0 $2 delay $4 $5 0 $4 $5 $NEWMS"
    dmsetup resume "$NAME"
}

DELAY=1000
for round in 1 2 3; do
    F="$MNT/t$round"
    python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o644); os.posix_fallocate(fd,0,16<<20); os.fsync(fd); os.close(fd)' "$F"
    sync
    log "round $round: 64 KiB O_DIRECT write into preallocated space, held $DELAY ms; truncate 16 MiB -> 1 MiB behind it"
    C0="$(ctr dio_converts)"
    NEWMS=$DELAY set_write_delay
    OUTF="$(ct_tmp diotrunc-$round)"
    "$AIO" trunc "$F" $((4 << 20)) 65536 $((1 << 20)) >"$OUTF" 2>&1 &
    P=$!
    for _ in $(seq 1 600); do kill -0 "$P" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$P" 2>/dev/null; then
        fail "round $round: the truncate did not return in 60 s beside an in-flight direct write (left in D state): $(tr '\n' ' ' <"$OUTF")"
        ct_exit
    fi
    wait "$P" || true
    NEWMS=0 set_write_delay
    OUT="$(tr '\n' ' ' <"$OUTF")"
    C1="$(ctr dio_converts)"
    grep -q 'inflight=1' <<<"$OUT" && [ "$((C1 - C0))" -ge 1 ] ||
        { fail "round $round: setup: the write was not in flight converting when the truncate started: $OUT, $((C1 - C0)) conversion(s)"; continue; }
    grep -q 'trunc=0 write=65536' <<<"$OUT" &&
        pass "round $round: the truncate returned beside the in-flight write, and both succeeded ($OUT)" ||
        fail "round $round: $OUT"
    SZ="$(stat -c %s "$F")"
    [ "$SZ" = $((1 << 20)) ] || fail "round $round: size after the truncate is $SZ"
done

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
