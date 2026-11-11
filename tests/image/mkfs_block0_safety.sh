#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs -f over a cetrafs volume: interrupted while it probes, it puts the superblock back; a stale cached block 0 does not skip the probe
#
# mkfs retires the old superblock (zeroes block 0) BEFORE it probes the
# registry for a live node, so no mount can start meanwhile, and puts it
# back if it finds one. The probe can wait minutes. The old superblock
# lived only in mkfs's memory and the restore ran only on a normal
# return: a ^C or a SIGTERM during the wait left block 0 zero on a
# volume that may be live, with no backup superblock anywhere -- it never
# mounts again (audit 2026-11-11 M1). And both of mkfs's block-0 reads
# went through this machine's page cache: a block 0 cached while the LUN
# was blank read "not cetrafs" over a volume formatted since, and the
# probe never ran (M2).
#
#  1. SIGINT during the probe: block 0 is the old superblock again,
#     mkfs exits nonzero, nothing is formatted.
#  2. SIGTERM: the same.
#  3. SIGKILL (cannot be caught): the old superblock is in the file mkfs
#     named before the probe, and the dd it printed restores it.
#  4. CONTROL, no signal, the row dead: the volume is formatted and the
#     saved copy removed.
#  5. a stale cached block 0 ("blank") over a volume whose row beats:
#     mkfs reads the device, probes, and refuses.
#
# DISCRIMINATION (2026-11-11): with the save, the held signals and the
# DONTNEED reverted, 1 and 2 leave block 0 zero, 3 finds no copy, and 5
# formats the live volume.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper node_poke)"
MKFS="$ROOT/userspace/mkfs.cetra"

IMG="$(ct_image 560 mkb0)"
DEV="$(ct_loop "$IMG")"
SAVE="$(ct_tmp mkb0-dir)"
rm -f "$SAVE"; mkdir -p "$SAVE"
ERR="$(ct_tmp mkb0-err)"
export TMPDIR="$SAVE" CETRAFS_PEER_PROBE_SECS=10

blk0() { dd if="$IMG" bs=4096 count=1 status=none | sha256sum | cut -d' ' -f1; }
ZERO="$(head -c 4096 /dev/zero | sha256sum | cut -d' ' -f1)"

# stage: a cetrafs volume whose row 1 looks mounted (dead: it never beats).
# (-N 2048: a reformat below, with -N 1024, writes a different block 0.)
stage() {
    "$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null 2>&1
    "$POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    blockdev --flushbufs "$DEV"
    ORIG="$(blk0)"
}

# interrupt <signal>: mkfs -f, the signal once it is watching. Sets RC.
interrupt() {
    local p
    # A background job of a non-interactive shell starts with SIGINT
    # ignored; reset it, as a terminal's ^C would find it.
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
        "$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>"$ERR" &
    p=$!
    wait_for 20 "grep -q 'still heartbeating' '$ERR'" || { fail "setup: mkfs never started its probe: $(cat "$ERR")"; kill -9 "$p"; ct_exit; }
    kill -"$1" "$p"
    RC=0
    wait "$p" || RC=$?
}

for sig in INT TERM; do
    log "$sig during the probe"
    stage
    interrupt "$sig"
    [ "$(blk0)" = "$ORIG" ] && pass "$sig: block 0 is the old superblock again" ||
        { [ "$(blk0)" = "$ZERO" ] && fail "$sig: mkfs left block 0 ZERO -- the volume will never mount" ||
            fail "$sig: block 0 is neither the old superblock nor zero"; }
    [ "$RC" != 0 ] && pass "$sig: mkfs exited nonzero ($RC)" || fail "$sig: mkfs exited 0 after being interrupted"
    grep -q "interrupted -- nothing was formatted" "$ERR" && pass "$sig: and said nothing was formatted" ||
        fail "$sig: no interruption message: $(tail -2 "$ERR")"
    [ -z "$(ls "$SAVE")" ] && pass "$sig: the saved copy was removed once restored" || fail "$sig: left $(ls "$SAVE")"
done

log "KILL during the probe"
stage
interrupt KILL
COPY="$(ls "$SAVE"/mkfs.cetra-* 2>/dev/null | head -1 || true)"
[ -n "$COPY" ] && [ "$(sha256sum <"$COPY" | cut -d' ' -f1)" = "$ORIG" ] &&
    pass "KILL: the old superblock is in the copy mkfs named ($COPY)" ||
    fail "KILL: no copy of the old superblock survives the kill"
CMD="$(sed -n 's/^ *If mkfs is killed before it finishes: //p' "$ERR")"
[ -n "$CMD" ] && eval "$CMD" 2>/dev/null && blockdev --flushbufs "$DEV" && [ "$(blk0)" = "$ORIG" ] &&
    pass "KILL: and the command it printed puts it back" || fail "KILL: the printed restore did not work: ${CMD:-none}"
rm -f "$SAVE"/*

log "CONTROL: no signal, the row dead -- formatted"
stage
RC=0
"$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>"$ERR" || RC=$?
[ "$RC" = 0 ] && [ "$(blk0)" != "$ORIG" ] && [ "$(blk0)" != "$ZERO" ] && pass "CONTROL: formatted" ||
    fail "CONTROL: mkfs did not format a volume whose row is dead (rc $RC): $(tail -2 "$ERR")"
[ -z "$(ls "$SAVE")" ] && pass "CONTROL: and removed its copy" || fail "CONTROL: left $(ls "$SAVE")"

log "a stale cached 'blank' block 0 over a volume whose row beats"
stage
SB0="$(ct_tmp mkb0-sb0)"
dd if="$IMG" of="$SB0" bs=4096 count=1 status=none
# The device's cache holds block 0 as zero; the device (its backing
# file) holds the superblock.
# (The last close of a block device drops its cache: hold it open for
# the whole case, so what is staged is still there when mkfs looks.)
udevadm settle 2>/dev/null || true
exec 7<"$DEV"
dd if=/dev/zero of="$IMG" bs=4096 count=1 conv=notrunc status=none
blockdev --flushbufs "$DEV"
dd if="$DEV" bs=4096 count=1 status=none >/dev/null
dd if="$SB0" of="$IMG" bs=4096 count=1 conv=notrunc status=none
[ "$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum | cut -d' ' -f1)" = "$ZERO" ] ||
    { fail "setup: the device's cache does not hold the stale blank block 0 (dev $(dd if="$DEV" bs=4096 count=1 status=none | sha256sum | cut -c1-12), img $(blk0 | cut -c1-12), zero ${ZERO:0:12}, sb0 $(sha256sum <"$SB0" | cut -c1-12))"; ct_exit; }
# Row 1 beats, written to the backing file: a live node.
# (A separate shell, not a subshell: a subshell inherits the harness's
# cleanup, which would detach the loop device under the suite when the
# beater is killed.)
# NODE_POKE_SB: a mounted node beats off the geometry it read at mount,
# whatever mkfs does to block 0.
NODE_POKE_SB="$SB0" bash -c 'while :; do "$0" "$1" 1 --beat >/dev/null 2>&1; sleep 1; done' "$POKE" "$IMG" 7<&- &
BEATER=$!
RC=0
"$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>"$ERR" || RC=$?
kill "$BEATER" 2>/dev/null; wait "$BEATER" 2>/dev/null || true
exec 7<&-
[ "$RC" != 0 ] && grep -q "is mounted by another node" "$ERR" &&
    pass "stale cache: mkfs read the device, saw a live row, and refused" ||
    fail "stale cache: mkfs went by the cached blank block 0 (rc $RC) -- a live volume formatted: $(tail -2 "$ERR")"
[ "$(blk0)" = "$(sha256sum <"$SB0" | cut -d' ' -f1)" ] && pass "stale cache: and the superblock is in place" ||
    fail "stale cache: block 0 is not the volume's superblock afterwards"
ct_exit
