#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a full Block Group never reads free while its count's flush is in flight
#
# The flush takes a Block Group's accrued delta out of memory, then
# CASes it into the descriptor, and only after the CAS does this node's
# cached descriptor carry it. For that one device round trip the delta
# was in neither place, and a full group read as free as its descriptor
# last said. The allocator picked it, found its bitmap full and
# recounted; on a SAN a heartbeat flush walking the owned groups stayed
# one step ahead of a 1 TiB fallocate, which spent every retry on those
# recounts and failed ENOSPC with half the volume free (UNMAP benchmark,
# 2026-11-12). Readers now take the count the flush is writing while it
# is in flight (cetrafs_bg_chunk.bg_flight_gen).
#
# Staged: two Block Groups, one per Zone Group; the node owns ZG 0. A
# writer fallocates all but one block of what Block Group 0 has free
# (the fallocate's publish flushes that count) and writes the last one,
# keeping the file open: that delta stays accrued, and the allocator's
# cursor stays on the now-full group. A sync's flush is held in flight on Block Group
# 0 (bg_flush_stall_ms) while a second file allocates one block.
#
#  1. the allocation finds no free space in Block Group 0: no recount
#     ("reported free space but its bitmap is full"), it claims ZG 1;
#  2. control (bg_flight_ignored=1, the old view): the full group reads
#     free in flight and the allocation recounts it.
# Both: the data reads back, fsck clean.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in bg_flush_stall_ms bg_flight_ignored; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"

IMG="$(ct_image 1200 bgflight)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgflight)"
READY="$(ct_tmp bgflight-ready)" # off the mount: its close would flush the counts
ct_track mnt "$MNT"
ct_param_set bg_flush_stall_ms 0
ct_param_set bg_flight_ignored 0
ct_param_set hb_interval_secs 30 # no tick flushes inside the stall
ct_param_set scrub 0
ct_param_set auto_defrag 0
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <tag>: sets RECOUNTS (recount lines), WROTE (the second write's rc)
run() {
    ct_mkfs "$DEV" -z 2 -b 512 -J 2 -N 1024 -f >/dev/null
    NBG="$("$MAP" "$DEV" | grep -c '^bg ' || true)"
    [ "$NBG" = 2 ] || { fail "$1: setup: want 2 Block Groups, got $NBG"; ct_exit; }
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    touch "$MNT/f"
    sync -f "$MNT"
    local total bg1 want
    total="$(info free_data_blocks)"
    bg1="$("$BG_POKE" "$DEV" 1 --dump | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
    want=$((total - bg1)) # what Block Group 0 has free
    [ "$want" -gt 1000 ] || { fail "$1: setup: Block Group 0 has $want blocks free"; ct_exit; }
    rm -f "$READY"
    python3 - "$MNT/f" "$want" "$READY" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
n = int(sys.argv[2])
os.posix_fallocate(fd, 4096, (n - 1) * 4096) # its publish flushes the count
os.pwrite(fd, b"F" * 4096, 0) # the last block: accrued, not flushed
open(sys.argv[3], "w").close()
time.sleep(30) # open: the delta stays accrued
PY
    local W=$!
    for _ in $(seq 1 300); do [ -e "$READY" ] && break; sleep 0.1; done
    [ -e "$READY" ] || { fail "$1: setup: the fallocate never finished"; kill "$W"; ct_exit; }
    [ "$(info free_data_blocks)" = "$bg1" ] ||
        { fail "$1: setup: Block Group 0 is not exactly full ($(info free_data_blocks) free, want $bg1)"; kill "$W"; ct_exit; }
    MARK="$(dmesg_mark)"
    ct_param_set bg_flush_stall_ms 3000
    sync -f "$MNT" &
    local S=$!
    for _ in $(seq 1 50); do dmesg_since "$MARK" | grep -q "BG 0: free-count flush of .* in flight" && break; sleep 0.1; done
    dmesg_since "$MARK" | grep -q "BG 0: free-count flush of .* in flight" ||
        { fail "$1: setup: no flush of Block Group 0 was held in flight: $(dmesg_since "$MARK" | tail -5 | tr '\n' '|')"; kill "$W" "$S"; ct_exit; }
    WROTE=0
    python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.pwrite(fd, b"G" * 4096, 0)
os.fsync(fd)
' "$MNT/g" || WROTE=$?
    wait "$S" || true
    kill "$W" 2>/dev/null || true
    wait "$W" 2>/dev/null || true
    RECOUNTS="$(dmesg_since "$MARK" | grep -c "BG 0 reported free space but its bitmap is full" || true)"
    [ "$(head -c 4096 "$MNT/g" | tr -d G | wc -c)" = 0 ] && [ "$(head -c 4096 "$MNT/f" | tr -d F | wc -c)" = 0 ] ||
        fail "$1: the data does not read back"
    ct_umount "$MNT"
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$1: fsck clean" || fail "$1: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
    log "$1: second write rc $WROTE, $RECOUNTS recount(s) of Block Group 0"
}

# ------------------------------------------------------------------ 2
log "2: control -- the old view ignores the flush in flight"
ct_param_set bg_flight_ignored 1
run control
ct_param_set bg_flight_ignored 0
[ "$RECOUNTS" -ge 1 ] && pass "control: the full group read free in flight and was recounted" ||
    fail "control: no recount -- the suite cannot tell the two apart"

# ------------------------------------------------------------------ 1
log "1: a full group's count in flight"
run fix
[ "$WROTE" = 0 ] && pass "1: the write succeeded" || fail "1: the write failed ($WROTE)"
[ "$RECOUNTS" = 0 ] && pass "1: the full group never read free -- no recount" ||
    fail "1: the full group read free in flight ($RECOUNTS recount(s))"
ct_exit
