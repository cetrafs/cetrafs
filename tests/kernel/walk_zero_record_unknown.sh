#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a record that reads back as zeros is unknown to the freeing walks, not empty
#
# F-7 let the whole-table walks read an allocated number's all-zero record
# as naming nothing, for the never-written record an abandoned inode
# number left. A LIVE file's record read back as zeros -- a stray write, a
# rolled-back LUN, an array returning zeros for a lost block -- is the
# same bytes, and these walks free what nothing owns: the scrub freed the
# file's blocks as leaks, the namespace recount counted a directory's
# names away and published nlink 0 (review F-11). Such a record is now
# unknown: the scrub frees nothing that cycle, the recount publishes
# nothing. (The abandoned number is stamped dead instead:
# ibmap_cas_image_only.sh.)
#   S. a file's record zeroed behind the mount (the backing file); two
#      scrub cycles: none of its blocks freed -- the record put back,
#      fsck is clean; the cycles counted the unknown record;
#   N. the directory naming a file has its record zeroed behind the
#      mount, and the file's namespace lock is handed to a dead peer; an
#      fchmod through a held fd takes it over and recounts: the file
#      keeps nlink 1.
#
# DISCRIMINATION: walk_zero_owns_nothing=1 (F-7's walk): S frees the
# file's blocks (fsck ERR), N publishes nlink 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/walk_zero_owns_nothing ] || { skip "walk_zero_owns_nothing is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
SB_POKE="$(ct_helper sb_poke)"
MNT="$(ct_mnt wzru)"
ct_track mnt "$MNT"
ct_param_set walk_zero_owns_nothing 0
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 2
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
P=/sys/module/cetrafs/parameters

# --- S: the scrub ---------------------------------------------------------
# <owns-nothing 0|1> -> "cycles=<n> unknown=<n> freed=<n> fsck=<clean|ERR> why=<first ERR>"
scrub_round() {
    local img dev proc fi rec saved out why c0 c1 u0 u1 f0 f1 dl
    img="$(ct_image 560 "wzrs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=64 conv=fsync status=none
    fi="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    eval "$("$SB_POKE" "$img" | grep -E '^inode_table_start=')"
    rec=$((inode_table_start + fi - 1))
    saved="$(ct_tmp "wzrs-rec$1")"
    dd if="$img" of="$saved" bs=4096 skip="$rec" count=1 status=none
    dd if=/dev/zero of="$img" bs=4096 seek="$rec" count=1 conv=notrunc,fsync status=none
    echo "$1" >$P/walk_zero_owns_nothing
    echo 1 >$P/scrub
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    c0="$(sed -n 's/^scrub_cycles: //p' "$proc/info")"
    u0="$(sed -n 's/^scrub_unknown_records: //p' "$proc/info")"
    f0="$(sed -n 's/^scrub_free_calls: //p' "$proc/info")"
    dl=$((SECONDS + 90))
    # a cycle that met the unknown record stops before it counts as one
    while [ "$(sed -n 's/^scrub_cycles: //p' "$proc/info")" -lt $((c0 + 3)) ] &&
        [ "$(sed -n 's/^scrub_unknown_records: //p' "$proc/info")" -lt $((u0 + 3)) ] && [ "$SECONDS" -lt "$dl" ]; do
        sleep 1
    done
    c1="$(sed -n 's/^scrub_cycles: //p' "$proc/info")"
    u1="$(sed -n 's/^scrub_unknown_records: //p' "$proc/info")"
    f1="$(sed -n 's/^scrub_free_calls: //p' "$proc/info")"
    ct_umount "$MNT"
    echo 0 >$P/scrub
    echo 0 >$P/walk_zero_owns_nothing
    dd if="$saved" of="$img" bs=4096 seek="$rec" count=1 conv=notrunc,fsync status=none
    out="$(ct_fsck "$dev" 2>&1 || true)"
    why="$(grep -m1 '^ERR' <<<"$out" | tr ' ' '_' | cut -c1-120)"
    grep -qE '^ERR' <<<"$out" && out=ERR || out=clean
    echo "cycles=$((c1 - c0)) unknown=$((u1 - u0)) freed=$((f1 - f0)) fsck=$out why=${why:-none}"
}

# --- N: the namespace recount ----------------------------------------------
# <owns-nothing 0|1> -> "nlink=<n> setup=[...]"
recount_round() {
    local img dev t fi di rec nl setup
    img="$(ct_image 560 "wzrn$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    echo payload >"$MNT/d/F"
    fi="$(stat -c %i "$MNT/d/F")"
    di="$(stat -c %i "$MNT/d")"
    ct_umount "$MNT"
    eval "$("$SB_POKE" "$img" | grep -E '^inode_table_start=')"
    rec=$((inode_table_start + di - 1))
    echo "$1" >$P/walk_zero_owns_nothing
    ct_mount "$dev" "$MNT"
    t="$(ct_tmp "wzrn-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    python3 -I - "$MNT/d/F" "$t" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
open(os.path.join(sys.argv[2], "w"), "w").close()
while not os.path.exists(os.path.join(sys.argv[2], "go")):
    time.sleep(0.05)
try:
    os.fchmod(fd, 0o600)
except OSError as e:
    print("fchmod: %s" % e, file=sys.stderr)
os.close(fd)
PY
    local wpid=$!
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    dd if=/dev/zero of="$img" bs=4096 seek="$rec" count=1 conv=notrunc,fsync status=none
    "$LOCK_POKE" "$img" "$fi" --ns 1 >/dev/null
    poke_dead_peer "$dev" 1 bb
    setup="$("$LOCK_POKE" "$img" --rec "$fi") $("$LOCK_POKE" "$img" "$fi")"
    wait_out_stale_window
    touch "$t/go"
    wait "$wpid" || true
    nl="$("$LOCK_POKE" "$img" --rec "$fi" | sed -n 's/.*nlink=\([0-9]*\).*/\1/p')"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/walk_zero_owns_nothing
    echo "nlink=$nl setup=[$setup]"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

R="$(scrub_round 0)"
log "S fixed: $R"
C="$(scrub_round 1)"
log "S control (owns nothing): $C"
[ "$(($(get cycles "$R") + $(get unknown "$R")))" -ge 3 ] && [ "$(get cycles "$C")" -ge 3 ] ||
    { fail "S setup: the scrub did not run ($R | $C)"; ct_exit; }
[ "$(get unknown "$R")" -ge 3 ] && [ "$(get freed "$R")" = 0 ] && [ "$(get fsck "$R")" = clean ] &&
    pass "S: $(get unknown "$R") scrub cycles met the zeroed record and freed nothing; fsck clean" ||
    fail "S: over the zeroed record: $R"
[ "$(get fsck "$C")" = ERR ] && pass "S control: read as owning nothing, the file's blocks were freed ($(get why "$C"))" ||
    fail "S control: the old walk freed nothing ($C) -- the scrub did not reach the file's blocks"

R="$(recount_round 0)"
log "N fixed: $R"
C="$(recount_round 1)"
log "N control (owns nothing): $C"
grep -q 'nlink=1 ' <<<"${R#*setup=}" && grep -q 'ns_owner=1 ' <<<"${R#*setup=} " ||
    { fail "N setup: F was not at nlink 1 with the dead peer's lock ($R)"; ct_exit; }
[ "$(get nlink "$R")" = 1 ] && pass "N: the recount met the zeroed directory record and published nothing; nlink 1" ||
    fail "N: after the takeover nlink=$(get nlink "$R")"
[ "$(get nlink "$C")" = 0 ] && pass "N control: read as naming nothing, the recount published nlink 0 over a named file" ||
    fail "N control: the old walk kept nlink $(get nlink "$C") -- the suite does not reach the recount"
ct_exit
