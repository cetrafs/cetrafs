#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create whose inode record fails to reach the device must fail, not publish a name
#
# cetrafs_write_raw_inode(sync=true) is how create/mkdir/link/symlink
# make a new record durable BEFORE the dirent that names it is published
# (rule 8). It called sync_dirty_buffer() and returned 0 whatever that
# said -- and a failed sync leaves the buffer clean and !uptodate, so the
# record image is simply gone. The create then published its dirent and
# returned success: a name pointing at a record that never reached the
# device, on every node.
#
# The fault is a real write error on exactly ONE block -- the record of
# the inode the create is about to get -- and only on writes: dm-flakey
# with error_writes, spliced between two linear segments. A whole-device
# failure would be caught first by the bitmap flush, and a read error
# would make the create fail for the wrong reason.
#
# DISCRIMINATION (measured on the unfixed code): the first create fails
# only by luck -- iget re-reads the lost record and reports EUCLEAN, a
# corruption errno for a device error -- but in the directory phase all
# 20 creates report success, 7 are gone after a remount, and fsck finds
# their inodes allocated with no name.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_flakey 2>/dev/null || true

DEV="$(ct_failable_dev 560 recwr)"
[ -n "$DEV" ] || { skip "device-mapper unavailable"; ct_exit; }
NAME="$(basename "$DEV")"
read -r _ SECTORS _ LOOP _ < <(dmsetup table "$NAME")
MNT="$(ct_mnt recwr)"
SBPOKE="$(ct_helper sb_poke)"
ct_mkfs_small "$DEV" >/dev/null
ITS="$("$SBPOKE" "$DEV" | sed -n 's/^inode_table_start=//p')"
[ -n "$ITS" ] || { fail "could not read inode_table_start"; ct_exit; }
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

touch "$MNT/probe"
sync
P="$(stat -c %i "$MNT/probe")"
T=$((P + 1)) # the number the next create is handed
BLK=$((ITS + T - 1))
X=$((BLK * 8))
log "probe got ino $P; failing writes to ino $T's record (block $BLK)"

dm_set() { # <table>
    dmsetup suspend --noflush --nolockfs "$NAME"
    dmsetup load "$NAME" --table "$1"
    dmsetup resume "$NAME"
}
LINEAR="0 $SECTORS linear $LOOP 0"
dm_set "0 $X linear $LOOP 0
$X 8 flakey $LOOP $X 0 3600 1 error_writes
$((X + 8)) $((SECTORS - X - 8)) linear $LOOP $((X + 8))"

MARK="$(dmesg_mark)"
out="$(python3 - "$MNT/victim" 2>&1 <<'PY'
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    os.close(fd)
    print("create=0 ino=%d" % os.stat(sys.argv[1]).st_ino)
except OSError as e:
    print("create=" + errno.errorcode.get(e.errno, str(e.errno)))
sys.stdout.flush()
PY
)"
dm_set "$LINEAR"
log "$out"

# Setup proof: the injected block was really written (and failed).
# Captured, then matched: `dmesg_since | grep -q` under pipefail reports
# the producer's SIGPIPE as a miss (tests/README.md).
klog="$(dmesg_since "$MARK")"
if grep -q "logical block $BLK," <<<"$klog"; then
    pass "a write to ino $T's record block hit the injected error"
else
    fail "no I/O error was logged for block $BLK -- the fault never fired (setup did not arrange the situation)"
    tail -5 <<<"$klog" >&2
fi

case "$out" in
create=0*) fail "the create returned SUCCESS although its record never reached the device ($out)" ;;
create=EIO*) pass "the create failed with EIO" ;;
*) fail "the create failed, but not with EIO: $out" ;;
esac

# ---- phase 2: the DIRECTORY's own record fails to reach the device ----
# Here nothing re-reads what was written. Taking the namespace lock is a
# CAS on the directory's record (on a no-CAW device: a read-modify-write
# whose sync result was dropped the same way), and a create that grows
# the directory publishes the new dirent block's extent with a sync
# write of that record. Every create that reports success must survive.
# A record write the device refused stops the mount
# (docs/internal/ERRORS.md): this node no longer knows what that create
# left on the device. Recover the way an operator does -- remount.
PROC="$(ct_procdir "$DEV")"
[ "$(sed -n 's/^stopped: //p' "$PROC/info")" = error ] &&
    pass "the refused record write stopped the mount" ||
    fail "the mount kept going after a refused record write (stopped: $(sed -n 's/^stopped: //p' "$PROC/info"))"
umount "$MNT" || umount -l "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
sync
D="$(stat -c %i "$MNT/d")"
DBLK=$((ITS + D - 1))
DX=$((DBLK * 8))
log "failing writes to directory ino $D's record (block $DBLK) across 20 creates"
dm_set "0 $DX linear $LOOP 0
$DX 8 flakey $LOOP $DX 0 3600 1 error_writes
$((DX + 8)) $((SECTORS - DX - 8)) linear $LOOP $((DX + 8))"
MARK2="$(dmesg_mark)"
claimed="$(python3 - "$MNT/d" <<'PY2'
import os, sys
ok = []
for i in range(20):
    p = os.path.join(sys.argv[1], "e%02d" % i)
    try:
        os.close(os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
        ok.append("e%02d" % i)
    except OSError:
        pass
print(" ".join(ok))
sys.stdout.flush()
PY2
)"
dm_set "$LINEAR"
log "creates that reported success: ${claimed:-none}"
klog="$(dmesg_since "$MARK2")"
if grep -q "logical block $DBLK," <<<"$klog"; then
    pass "a write to directory ino $D's record block hit the injected error"
else
    fail "no I/O error was logged for block $DBLK -- the fault never fired"
fi

umount "$MNT" || umount -l "$MNT" # stopped by the first refused write, like the first case
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# With the fix every create here fails (the namespace-lock CAS on the
# directory now reports its failed write), so this holds over an EMPTY
# set -- correct behaviour, not coverage. What it discriminates is the
# old code, where 20 of 20 reported success and 7 were gone (e13..e19).
lost=""
for n in $claimed; do
    [ -e "$MNT/d/$n" ] || lost="$lost $n"
done
if [ -z "$lost" ]; then
    pass "every create that reported success is still there after a remount"
else
    fail "creates that reported SUCCESS are gone after a remount:$lost"
fi
if [ -e "$MNT/victim" ] && ! stat "$MNT/victim" >/dev/null 2>&1; then
    fail "after remount 'victim' is listed but cannot be stat'ed"
else
    pass "after remount no name points at an unwritten record"
fi
ct_umount "$MNT"

rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
# Each refused record write stopped the mount -- a crash at that
# instant -- so the create's unwind never freed the number it had
# claimed: its bit stays set over a record that never reached the
# device. A leak (the number cannot be handed out again), the safe
# direction, and the one finding allowed per stop.
bad="$(grep '^ERR' <<<"$fo" | grep -v "is marked in use but its checksum is wrong" || true)"
leaks="$(grep -c "is marked in use but its checksum is wrong" <<<"$fo" || true)"
if [ -z "$bad" ] && [ "$leaks" -le 2 ]; then
    pass "fsck: nothing but the stops' unwritten records ($leaks)"
else
    fail "fsck rc=$rc after the failed create: $(head -3 <<<"$bad") (unwritten records: $leaks)"
fi

ct_exit
