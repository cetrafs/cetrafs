#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a verdict's time never reaches a lockless reader ahead of the verdict it dates
#
# The two once-a-second verdict caches -- the foreign-opener verdict that
# gates a nofilelock writer's cached tree, and the reader's stamp check --
# publish a word and the time of the fill as two stores. The fill stored
# the time first, so a lockless reader between the stores paired the
# PREVIOUS fill's word (its generation still current: a peer's open bumps
# nothing on this node) with the new time, and trusted an arbitrarily old
# "no foreign opener" as read this second (audit 2026-11-22, N-20). Now
# the word is stored first and the time is the release store, loaded
# first by the reader.
#
# Staged per cache: a second after the last fill, a buffered read of an
# uncached page (A) refills and stalls between the two stores
# (verdict_publish_stall_ms); 200 ms in, a read of another page (B) asks
# the same cache. A reader that
# sees the old time must wait for A's fill (single-flight); one that is
# served the old word returns at once.
#   1. nofilelock, the foreign-opener verdict;
#   2. the default lock, a read-only opener's stamp check.
# Each case with the control first: verdict_time_first=1 restores the old
# order, and B must come back inside the stall -- the hazard, reached.
#
# DISCRIMINATION: the controls above, in-suite.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in verdict_publish_stall_ms verdict_time_first; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set auto_defrag 0
ct_param_set dio_shared_overwrite 0
ct_param_set verdict_time_first 0
ct_param_set verdict_publish_stall_ms 0
MNT="$(ct_mnt vpo)"
ct_track mnt "$MNT"

# run <tag> <mount options> <fill counter> <time_first> -> "a_ms b_ms afills"
run() {
    local out
    out="$(ct_tmp "vpo-$1")"
    echo "$4" >"$P/verdict_time_first"
    python3 - "$MNT/vm.img" "$INFO" "$3" "$P/verdict_publish_stall_ms" >"$out" 2>&1 <<'PY' || true
import os, sys, threading, time
path, info, counter, stall = sys.argv[1:5]
def fills():
    for l in open(info):
        if l.startswith(counter + ":"):
            return int(l.split()[1])
# Buffered reads, one page each: a read_folio maps under invalidate_lock
# shared, so A and B can be in the mapping at once (an O_DIRECT read maps
# under inode_lock, and B would queue behind A whatever the order).
fd = os.open(path, os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_RANDOM)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
os.pread(fd, 4096, 0)
time.sleep(1.3)                       # the cached verdict is now too old
open(stall, "w").write("1000")
res = {}
def a():
    t = time.monotonic(); os.pread(fd, 4096, 1 << 20); res["a"] = time.monotonic() - t
f0 = fills()
th = threading.Thread(target=a)
th.start()
time.sleep(0.2)
t = time.monotonic(); os.pread(fd, 4096, 3 << 20); res["b"] = time.monotonic() - t
th.join()
print(int(res["a"] * 1000), int(res["b"] * 1000), fills() - f0, open(stall).read().strip())
PY
    cat "$out"
}

for mode in nofilelock default; do
    DEV="$(ct_dev 560 "vpo$mode")"
    ct_mkfs_small "$DEV" >/dev/null
    if [ "$mode" = nofilelock ]; then
        mount -t cetrafs -o nofilelock "$DEV" "$MNT"
        C=verdict_fills
    else
        mount -t cetrafs "$DEV" "$MNT"
        C=read_stamp_fills
    fi
    require_cetrafs_mount "$MNT"
    INFO="$(ct_procdir "$DEV")/info"
    grep -q "^$C:" "$INFO" || { skip "no $C counter"; ct_exit; }
    dd if=/dev/urandom of="$MNT/vm.img" bs=1M count=4 conv=fsync status=none
    for tf in 1 0; do
        R="$(run "$mode$tf" "$mode" "$C" "$tf")"
        log "$mode time_first=$tf: a_ms b_ms fills stall_left = $R"
        read -r A B F S <<<"$R" || true
        [ "${S:-x}" = 0 ] && [ "${A:-0}" -ge 900 ] && [ "${F:-0}" -ge 1 ] || {
            fail "$mode time_first=$tf setup: A did not take the stalled fill: $R"
            continue
        }
        if [ "$tf" = 1 ]; then
            [ "$B" -lt 300 ] &&
                pass "$mode control: with the time stored first, B was served the old verdict inside the stall (${B} ms)" ||
                fail "$mode control: B waited ${B} ms -- the hazard did not reproduce, the check cannot tell"
        else
            [ "$B" -ge 500 ] &&
                pass "$mode: B waited for the fill in flight (${B} ms) instead of trusting the old verdict" ||
                fail "$mode: B came back in ${B} ms, inside the stall: it trusted the previous fill's verdict"
        fi
    done
    echo 0 >"$P/verdict_time_first"
    ct_param_set verdict_publish_stall_ms 0
    ct_umount "$MNT"
done
ct_exit
