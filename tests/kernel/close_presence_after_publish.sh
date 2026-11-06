#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a last writer's close withdraws what marks the file in use only after its publish
#
# Under nofilelock the presence bit is the only thing that stops a peer's
# truncate or punch on a file open here; a suspended writer's mark and
# bit do the same on a default mount, and an explicit flock lock under
# nofilelock is the lock. The last writer's close took all three away
# FIRST and published the record after -- the leaf flush, the cache
# flush and the file-sector CAS, milliseconds to seconds. A peer's punch
# in that window found no user, freed the blocks and published its tree;
# this node's publish then put its own shadow tree back over it, naming
# the freed blocks again, and the peer's allocator handed them to another
# file (audit 2026-11-06 H3, the live-migration close).
#
# Staged with close_publish_fail, which makes the close's publish fail:
# the order is visible on the device as what is still set when close(2)
# has returned. Each case asserts the marker is STILL set after the
# failed close, then that the heartbeat publishes (size on the record)
# and only then clears it (a suspension has published the size already):
#   (1) nofilelock: the writer's presence bit;
#   (2) nofilelock: an fd holding flock(LOCK_EX) -- the lock and the bit;
#   (3) default mount, a writer suspended by flock(LOCK_UN): its mark in
#       suspended_writer_nodes and its bit.
#
# DISCRIMINATION: with the old order every marker reads clear the moment
# close(2) returns, over a record still saying size 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/close_publish_fail ] || { skip "close_publish_fail is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
KNOB=/sys/module/cetrafs/parameters/close_publish_fail

DEV="$(ct_dev 560 cpap)"
MNT="$(ct_mnt cpap)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2

recsize() { "$LOCK_POKE" "$DEV" "$1" --rec | sed -n 's/^size=\([0-9]*\).*/\1/p'; }
readers() { "$LOCK_POKE" "$DEV" "$1" | sed -n 's/.*readers=\(0x[0-9a-f]*\).*/\1/p'; }
lmode() { "$LOCK_POKE" "$DEV" "$1" | sed -n 's/.* mode=\([0-9]*\).*/\1/p'; }
susp() { "$LOCK_POKE" "$DEV" --sw "$1" | sed -n 's/^suspended=\(0x[0-9a-f]*\).*/\1/p'; }

# write 256 KiB through one fd and close it with the publish failing;
# $2: "" | flock_ex | flock_un. Prints what the device says right after.
closeit() {
    python3 - "$1" "$2" "$KNOB" <<'PY'
import fcntl, os, sys
f, how, knob = sys.argv[1:4]
fd = os.open(f, os.O_RDWR)
if how == "flock_ex":
    fcntl.flock(fd, fcntl.LOCK_EX)
os.pwrite(fd, os.urandom(262144), 0)
if how == "flock_un":
    fcntl.flock(fd, fcntl.LOCK_UN)
open(knob, "w").write("1")
os.close(fd)
print("OK")
PY
}

# the heartbeat finishes it: size published, then the markers clear
settled() {
    local ino=$1 what=$2 i
    for i in $(seq 1 20); do
        [ "$(recsize "$ino")" = 262144 ] && [ "$(readers "$ino")" = 0x0 ] && [ "$(lmode "$ino")" = 0 ] &&
            [ "$(susp "$ino")" = 0x0 ] && { pass "$what: the heartbeat published the close and then cleared it"; return; }
        sleep 1
    done
    fail "$what: not settled in 20 s (size $(recsize "$ino"), readers $(readers "$ino"), mode $(lmode "$ino"), suspended $(susp "$ino"))"
}

case_run() { # <mount opts> <file> <how> <label>
    local f="$MNT/$2" ino out
    : >"$f"
    sync
    ino="$(stat -c %i "$f")"
    [ "$(recsize "$ino")" = 0 ] || { fail "$4: setup: the new record does not say size 0"; return; }
    out="$(closeit "$f" "$3" 2>&1)" || true
    [ "$out" = OK ] || { fail "$4: setup: the staging script failed: $out"; return; }
    R="$(readers "$ino")" M="$(lmode "$ino")" W="$(susp "$ino")" S="$(recsize "$ino")"
    [ "$(cat "$KNOB")" = 0 ] || { fail "$4: setup: the close never reached its publish"; ct_param_set close_publish_fail 0; return; }
    # A suspension publishes everything before it gives the lock back
    # (a suspended writer cannot write), so there the record already has
    # the size; elsewhere only the close publishes it.
    if [ "$3" = flock_un ]; then
        [ "$S" = 262144 ] || { fail "$4: setup: the suspension did not publish the record (size $S)"; return; }
    else
        [ "$S" = 0 ] || { fail "$4: setup: the record was published although the publish failed (size $S)"; return; }
    fi
    case "$3" in
    "") [ "$R" != 0x0 ] && pass "$4: the presence bit outlives a close whose publish failed ($R)" ||
        fail "$4: the presence bit was withdrawn over an unpublished record" ;;
    flock_ex)
        [ "$M" != 0 ] && pass "$4: the explicit lock outlives a close whose publish failed (mode $M)" ||
            fail "$4: the explicit lock was cleared over an unpublished record"
        [ "$R" != 0x0 ] && pass "$4: and so does the presence bit ($R)" ||
            fail "$4: the presence bit was withdrawn over an unpublished record" ;;
    flock_un)
        [ "$W" != 0x0 ] && pass "$4: the suspended writer's mark outlives a close whose publish failed ($W)" ||
            fail "$4: the suspended writer's mark was dropped over an unpublished record"
        [ "$R" != 0x0 ] && pass "$4: and so does its presence bit ($R)" ||
            fail "$4: the suspended writer's presence bit was withdrawn over an unpublished record" ;;
    esac
    settled "$ino" "$4"
}

ct_mkfs_small "$DEV" >/dev/null
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
case_run nofilelock a "" "nofilelock writer"
case_run nofilelock b flock_ex "nofilelock flock holder"
umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean (nofilelock)" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"

ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
case_run default c flock_un "suspended writer"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean (default)" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
