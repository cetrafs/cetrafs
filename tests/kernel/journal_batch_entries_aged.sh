#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a completed tree batch's journal entries are spent within a heartbeat
#
# A held-back tree batch's entries stay live after the batch completed,
# until the next batch's first flush retires them -- or a sync(wait), or
# the unmount. After the last batch of a burst nothing came, and they
# stayed replayable for as long as the node ran; replay redoes an entry
# whenever its target reads as the entry's before-image again, so the
# guard against a redo over a newer block rested on an extent block's
# random generation alone, for an unbounded time (audit 2026-11-22 N-54).
# The heartbeat now spends entries left a beat old, as a sync does --
# flush, then zero (cetrafs_journal_drain_aged()).
#
# Staged on one node with the journal on: a fragmented file written and
# fsync'd, which writes its tree as a batch whose entries stay live;
# nothing else writes. hb_interval_secs=5.
#   setup: live entries in this node's area right after the fsync;
#   1. a few beats later none is live, and journal_aged_drains counted it;
#   2. the file reads back; fsck clean.
#
# DISCRIMINATION: the control, in-suite -- journal_aged_drain_off=1: the
# entries are still live after the same wait.
# ct-timeout: 240
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_aged_drain_off zg_release_hold bg_release_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
MNT="$(ct_mnt jbea)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set bg_release_off 1
ct_param_set zg_release_hold 1
ct_param_set journal_aged_drain_off 0

# round <off 0|1> -> "<live after fsync> <live after the wait> <aged drains> <read ok> <fsck>"
round() {
    local dev proc me l0 l1 d0 d1 ok=no out
    dev="$(ct_loop "$(ct_image 800 "jbea$1")")"
    ct_mkfs "$dev" -J 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    me="$(sed -n 's/^this_node_id: //p' "$proc/info")"
    echo "hb_interval_secs=5" >"$proc/controls"
    echo "$1" >/sys/module/cetrafs/parameters/journal_aged_drain_off
    d0="$(sed -n 's/^journal_aged_drains: //p' "$proc/info")"
    python3 - "$MNT/f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(1500):
    os.pwrite(fd, i.to_bytes(4, "little") * 1024, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
    l0="$("$JPOKE" "$dev" "$me" --live | grep -c . || true)"
    sleep 17
    l1="$("$JPOKE" "$dev" "$me" --live | grep -c . || true)"
    d1="$(sed -n 's/^journal_aged_drains: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/journal_aged_drain_off
    python3 - "$MNT/f" <<'PY' && ok=yes
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
for i in range(1500):
    if os.pread(fd, 4096, 2 * i * 4096) != i.to_bytes(4, "little") * 1024:
        sys.exit(1)
PY
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" >/dev/null 2>&1 && echo clean || echo ERR)"
    echo "$l0 $l1 $((d1 - d0)) $ok $out"
}

read -r CL0 CL1 CD CO CF <<<"$(round 1)"
log "control (aged drain off): live $CL0 after the fsync, $CL1 after the wait; drains $CD"
read -r L0 L1 D O F <<<"$(round 0)"
log "fixed: live $L0 after the fsync, $L1 after the wait; drains $D; read $O; fsck $F"
[ "$L0" -gt 0 ] && [ "$CL0" -gt 0 ] ||
    { fail "setup: no live entry after the fsync ($L0, $CL0) -- no batch was left to age"; ct_exit; }
pass "setup: the fsync's batch left $L0 live entries"
[ "$CL1" -gt 0 ] && pass "control: with the aged drain off, $CL1 entries are still live after the wait" ||
    fail "control: $CL1 live after the wait -- something else spent them; the test does not discriminate"
[ "$L1" = 0 ] && [ "$D" -ge 1 ] && pass "1: a few beats later none is live (spent by $D aged drain(s))" ||
    fail "1: $L1 entries still live, aged drains $D"
[ "$O" = yes ] && [ "$F" = clean ] && pass "2: the file reads back and fsck is clean" ||
    fail "2: read $O, fsck $F (control: read $CO, fsck $CF)"
ct_exit
