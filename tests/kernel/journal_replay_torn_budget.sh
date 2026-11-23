#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replay of many torn targets shares one re-read budget and beats while it runs
#
# Replay re-reads a torn target with backoff before believing the tear
# -- a live writer's write in flight converges in milliseconds, a
# crash's tear never does -- about 2.5 s per target. That budget was
# per entry, and the entry loop never renewed this node's row: a crash
# that tore many targets of a large in-flight batch took minutes to
# replay at mount, before the heartbeat exists, long enough for the
# lease registration armed to run out (audit 2026-11-22 N-55).
#
# Now the torn waits of one replay share the 2.5 s -- each target past it
# still gets its first re-reads -- and the loop beats when one is due.
#
# Played on this node's own area, replayed at mount: K directory blocks,
# each with an entry written against its current image and then torn
# (a byte flipped inside the entries; the tail magic is still the
# block's kind).
#   1. the mount succeeds, in well under K times 2.5 s;
#   2. every torn target was redone from its entry, and reads back as it
#      was before the tear.
#
# DISCRIMINATION: journal_torn_unshared=1 (as before): each target waits
# its full 2.5 s and nothing beats -- K=16 takes ~40 s, past the
# mount's lease.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_torn_unshared ] || { skip "journal_torn_unshared is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
EXTENT="$(ct_helper pending_poke)"
IMG="$(ct_image 560 jrtb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrtb)"
ct_track mnt "$MNT"
K=16
ct_param_set journal_torn_unshared 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for i in $(seq 0 $((K - 1))); do
    mkdir "$MNT/d$i"
    : >"$MNT/d$i/f"
done
sync
INOS=()
for i in $(seq 0 $((K - 1))); do INOS+=("$(stat -c %i "$MNT/d$i")"); done
ct_umount "$MNT"
BLKS=()
SF=()
for i in $(seq 0 $((K - 1))); do
    b="$("$EXTENT" "$IMG" extent "${INOS[$i]}" | cut -d' ' -f1)"
    [ -n "$b" ] && [ "$b" -gt 0 ] || { fail "setup: no dirent block for d$i"; ct_exit; }
    BLKS+=("$b")
    SF+=("$(ct_tmp "jrtb-s$i")")
    dd if="$DEV" of="${SF[$i]}" bs=4096 skip="$b" count=1 iflag=direct status=none
done
blk_sum() { dd if="$DEV" bs=4096 skip="$1" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }

# stage: an entry per block, against its image now, then the block torn
stage() {
    local i b
    for i in $(seq 0 $((K - 1))); do
        b="${BLKS[$i]}"
        dd if="${SF[$i]}" of="$DEV" bs=4096 seek="$b" count=1 conv=notrunc oflag=direct status=none
        "$JPOKE" "$DEV" 0 "$i" "$b" "${SF[$i]}" --guard-current >/dev/null
        # one byte inside the first entry's name: torn, the tail intact
        printf '\x5a' | dd of="$DEV" bs=1 seek=$((b * 4096 + 20)) count=1 conv=notrunc status=none
    done
    sync
}

# <unshared 0|1> -> RES
round() {
    local mark t0 t1 rc=0 ok=0 i
    stage
    compress_timing
    echo "$1" >/sys/module/cetrafs/parameters/journal_torn_unshared
    mark="$(dmesg_mark)"
    t0="$(date +%s)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
    t1="$(date +%s)"
    echo 0 >/sys/module/cetrafs/parameters/journal_torn_unshared
    if [ "$rc" = 0 ]; then
        ct_umount "$MNT"
    fi
    reset_stale_window
    for i in $(seq 0 $((K - 1))); do
        [ "$(blk_sum "${BLKS[$i]}")" = "$(sha256sum <"${SF[$i]}" | cut -d' ' -f1)" ] && ok=$((ok + 1))
    done
    RES="mount=$rc secs=$((t1 - t0)) torn=$(dmesg_since "$mark" | grep -c 'is TORN' || true) repaired=$ok"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

round 0
R="$RES"
log "fixed: $R"
round 1
C="$RES"
log "control (per-entry budget, no beat): $C"
[ "$(get torn "$R")" -ge "$K" ] || [ "$(get torn "$C")" -ge 1 ] ||
    { fail "setup: replay never judged a target torn ($R / $C)"; ct_exit; }
[ "$(get mount "$R")" = 0 ] && [ "$(get secs "$R")" -lt 15 ] &&
    pass "1: $K torn targets replayed at mount in $(get secs "$R") s" || fail "1: $R"
[ "$(get torn "$R")" = "$K" ] && [ "$(get repaired "$R")" = "$K" ] &&
    pass "2: every torn target was redone from its entry" || fail "2: $R"
{ [ "$(get mount "$C")" != 0 ] || [ "$(get secs "$C")" -ge 30 ]; } &&
    pass "control: with a per-entry budget and no beat, the mount failed or took $(get secs "$C") s" ||
    fail "control: the old replay was not slow -- the suite does not reach the waits: $C"
ct_exit
