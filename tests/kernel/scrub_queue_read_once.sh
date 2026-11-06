#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub reads each Zone Group's pending-free queue once per pass, not once per Block Group
#
# Building its reference set, the scrub marks every block with a free
# already queued against it, reading the queue of each Zone Group its
# targets belong to. It skipped a ZG equal to the previous target's --
# right when targets came ZG-major, wrong under round-robin ownership
# (BG b belongs to ZG b % Z): consecutive targets alternate Zone Groups,
# so every owned BG paid a whole queue read (audit 2026-11-06 L26).
#
# Staged: 2 Zone Groups, 4 Block Groups; the first ZG filled so this
# node claims the second and owns BGs of both, interleaved. A kprobe on
# cetrafs_zg_pending_free_for_each() counts queue reads per scrub cycle;
# the suite skips where kprobes are unavailable. A cycle builds its
# reference set twice (cached, then fresh); each build must read each
# queue once.
#
# DISCRIMINATION: deduplicating against the last target only, a cycle
# reads each queue twice.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
MAP="$(ct_helper bg_map)"

DEV="$(ct_dev 2400 scrubq)"
MNT="$(ct_mnt scrubq)"
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NBG="$("$MAP" "$DEV" | grep -c '^bg ')"
log "$NBG Block Groups: $("$MAP" "$DEV" | awk '/^bg /{printf "%s:%s ", $2, $3}')"
[ "$NBG" -ge 4 ] || { fail "setup: only $NBG Block Groups"; ct_umount "$MNT"; ct_exit; }
cycles() { sed -n 's/^scrub_cycles: //p' "$(ct_procdir "$DEV")/info"; }
# A node claims the fewest Zone Groups it can; filling the first one's
# Block Groups makes it claim the second, so it owns BGs of both,
# interleaved.
ct_param_set auto_defrag 0
dd if=/dev/zero of="$MNT/fill" bs=1M count=1100 conv=fsync status=none 2>/dev/null || true
sync

T=/sys/kernel/tracing
EV=cetrafs_scrq_$$
kp_off() {
    echo 0 >"$T/events/kprobes/$EV/enable" 2>/dev/null || true
    echo "-:kprobes/$EV" >>"$T/kprobe_events" 2>/dev/null || true
}
echo "p:kprobes/$EV cetrafs:cetrafs_zg_pending_free_for_each zg=\$arg2:u32" >>"$T/kprobe_events" 2>/dev/null ||
    { skip "cannot place a kprobe on cetrafs_zg_pending_free_for_each"; ct_umount "$MNT"; ct_exit; }
: >"$T/trace"
echo 1 >"$T/events/kprobes/$EV/enable"
C0="$(cycles)"
ct_param_set scrub 1
for _ in $(seq 1 40); do [ "$(( $(cycles) - C0 ))" -ge 2 ] && break; sleep 0.5; done
ct_param_set scrub 0
sleep 1
C1="$(cycles)"
READS="$(grep -c "$EV:" "$T/trace" || true)"
ZGS="$(grep -o "zg=[0-9]*" "$T/trace" | sort -u | wc -l)"
kp_off
N=$((C1 - C0))
log "$N scrub cycle(s), $READS queue read(s) of $ZGS distinct Zone Group(s)"
[ "$N" -ge 1 ] && [ "$ZGS" = 2 ] ||
    { fail "setup: need scrub cycles over two owned Zone Groups ($N cycles, $ZGS ZGs read)"; ct_umount "$MNT"; ct_exit; }
pass "setup: $N scrub cycle(s) over the Block Groups of $ZGS Zone Groups"
# Two reference-set passes per cycle (cached, then fresh), each reading
# every owned Zone Group's queue once.
[ "$READS" -le $((2 * N * ZGS)) ] && pass "each pass read each queue once ($READS reads, at most $((2 * N * ZGS)))" ||
    fail "$READS queue reads in $N cycle(s) of $ZGS Zone Groups, more than $((2 * N * ZGS)) -- a queue re-read per Block Group"
ct_umount "$MNT"
ct_exit
