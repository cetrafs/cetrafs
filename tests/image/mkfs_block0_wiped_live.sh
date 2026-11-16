#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs -f refuses a live volume whose block 0 was overwritten
#
# With no cetrafs magic at block 0 mkfs took the device for "not a
# cetrafs volume: nobody can be mounting it", and -f formatted it with
# no registry probe at all -- so a live cluster whose block 0 took a
# stray write (a partition table, a wipe) was formatted under its running
# nodes (audit 2026-11-15 B-16). The copy of block 0 at block 2048
# (A-7) still places the registry, and mkfs probes it through the copy
# exactly as through block 0. (It used to search the first GiB for
# blocks that looked like registry rows.)
#
# A volume with row 1 beating (a node impersonated, every 0.3 s); block
# 0 zeroed:
#   1. mkfs -f refuses, says a node is heartbeating, and writes nothing
#      (block 0 still zero, the inode table untouched);
#   2. the beat stopped: mkfs -f formats, having probed through the copy;
#   3. without -f mkfs refuses, and does not just say "use -f";
#   4. block 0 zeroed, without -f: refused, naming the copy -- blocks
#      1..2047 are empty now, so the first-MiB "is it empty?" scan alone
#      read this volume as blank.
#
# DISCRIMINATION: CETRAFS_TEST_MKFS_NO_SB_COPY_PROBE=1 (block 0 alone,
# as before): 1 formats; 4 with the copy zeroed as well formats.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper node_poke)"
MKFS="$ROOT/userspace/mkfs.cetra"
IMG="$(ct_image 560 mkbw)"
DEV="$(ct_loop "$IMG")"
SB="$(ct_tmp mkbw-sb)"
ERR="$(ct_tmp mkbw-err)"
export CETRAFS_PEER_PROBE_SECS=3
blk() { dd if="$DEV" bs=4096 skip="$1" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }
ZERO="$(head -c 4096 /dev/zero | sha256sum | cut -d' ' -f1)"
BEATER=""
stop_beat() { [ -z "$BEATER" ] || { kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true; BEATER=""; }; }
trap stop_beat EXIT
# stage: a volume, row 1 registered and (with "beat") beating, block 0 zeroed
stage() {
    "$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null 2>&1
    dd if="$DEV" of="$SB" bs=4096 count=1 iflag=direct status=none
    "$POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    if [ "$1" = beat ]; then
        (while :; do NODE_POKE_SB="$SB" "$POKE" "$DEV" 1 --beat >/dev/null 2>&1; sleep 0.3; done) &
        BEATER=$!
    fi
    dd if=/dev/zero of="$DEV" bs=4096 count=1 oflag=direct conv=notrunc status=none
}
# fmt [env...] -> "rc=<n>"
fmt() {
    local rc=0
    env "$@" "$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>"$ERR" || rc=$?
    echo "rc=$rc"
}

stage beat
before="$(blk 1)"
R1="$(fmt)"
after0="$(blk 0)"
after1="$(blk 1)"
stop_beat
[ "$R1" != "rc=0" ] && grep -q "still heartbeating" "$ERR" &&
    pass "1: mkfs -f refused: a node is heartbeating on the volume" || fail "1: $R1: $(cat "$ERR")"
[ "$after0" = "$ZERO" ] && [ "$after1" = "$before" ] &&
    pass "1: nothing was written (block 0 still zero, block 1 unchanged)" || fail "1: mkfs wrote to the device"

stage dead
R2="$(fmt)"
[ "$R2" = "rc=0" ] && grep -q "but its copy at block 2048 does" "$ERR" &&
    pass "2: with no beat, mkfs -f probed through the copy and formatted" || fail "2: $R2: $(cat "$ERR")"

stage beat
C="$(fmt CETRAFS_TEST_MKFS_NO_SB_COPY_PROBE=1)"
stop_beat
[ "$C" = "rc=0" ] && pass "control: without the copy, mkfs -f formatted the live volume" ||
    fail "control: $C -- the suite does not reach the no-superblock path: $(cat "$ERR")"

stage dead
dd if=/dev/urandom of="$DEV" bs=4096 count=1 oflag=direct conv=notrunc status=none
rc=0
"$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 >/dev/null 2>"$ERR" || rc=$?
[ "$rc" != 0 ] && grep -q "block 0 was overwritten" "$ERR" &&
    pass "3: without -f: refused, naming a damaged volume as a possibility" || fail "3: rc=$rc: $(cat "$ERR")"

stage dead
rc=0
"$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 >/dev/null 2>"$ERR" || rc=$?
[ "$rc" != 0 ] && grep -q "its copy" "$ERR" && [ "$(blk 0)" = "$ZERO" ] &&
    pass "4: block 0 zeroed, without -f: refused, naming the copy" || fail "4: rc=$rc: $(cat "$ERR")"
dd if=/dev/zero of="$DEV" bs=4096 seek=2048 count=1 oflag=direct conv=notrunc status=none
rc=0
"$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 >/dev/null 2>"$ERR" || rc=$?
[ "$rc" = 0 ] && pass "4 control: with the copy zeroed too, the first MiB alone reads blank and mkfs formats" ||
    fail "4 control: rc=$rc -- something else refused: $(cat "$ERR")"
ct_exit
