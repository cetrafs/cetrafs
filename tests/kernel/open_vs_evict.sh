#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an open never publishes itself on a file that lost its last name since it looked
#
# Eviction frees a file once its record reads nlink 0 and no live peer
# shows as an opener; it asks with a forced-fresh read, then frees by a
# CAS that checks only nlink, generation and the namespace lock. An open
# on another node checked nlink on ITS read and then published itself
# (read presence, or the write lock) by a swap that did not look at nlink
# at all. A peer's unlink landing between the opener's read and its swap
# produced an open on a deleted file, invisible to an evict that had
# already looked: the evicting node freed blocks the opener then read and
# wrote through its fd.
#
# The opener here is this node, held by lock_open_pause_ms between its
# read and its swap; the peer's unlink is played by setting nlink to 0 on
# the device in that window. The swap must refuse, and leave nothing on
# the record.
#
# Control: a file this node ALREADY has open is not this race -- a
# second open of it after unlink (through /proc/self/fd) must still work.
#
# DISCRIMINATION (measured on the code without the check): both opens
# succeed on the deleted record, and the device shows this node's
# presence bit (read) and its exclusive lock (write) on it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LOCK_POKE="$(ct_helper inode_lock_poke)"
REC_POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 ove)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ove)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# dump_field <ino> <key>: a lock field of the record, from the device.
dump_field() { "$LOCK_POKE" "$DEV" "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k {print $2}'; }

# race <file> <flags>: open <file> with python <flags>, held after its
# read; the peer's unlink lands in the pause.
race() {
    local f="$1" flags="$2" ino out go pid i
    ino="$(stat -c %i "$MNT/$f")"
    out="$(mktemp /tmp/cetrafs-ove-out-XXXXXX)"
    go="$(mktemp -u /tmp/cetrafs-ove-go-XXXXXX)"
    ct_track file "$out"
    ct_track file "$go"
    ct_param_set lock_open_pause_ms 2000
    # The fd stays open until the device has been looked at: its close
    # would withdraw what the open published.
    python3 -I - "$MNT/$f" "$flags" "$go" >"$out" 2>&1 <<'PY' &
import errno, os, sys, time
try:
    fd = os.open(sys.argv[1], getattr(os, sys.argv[2]))
    print("open=0", flush=True)
except OSError as e:
    print("open=" + errno.errorcode.get(e.errno, str(e.errno)), flush=True)
    sys.exit(0)
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)
os.close(fd)
PY
    pid=$!
    sleep 0.5
    "$REC_POKE" "$IMG" nlink "$ino" 0 2>/dev/null
    for i in $(seq 1 100); do grep -q '^open=' "$out" && break; sleep 0.1; done
    OPEN="$(sed -n 's/^open=//p' "$out")"
    READERS="$(dump_field "$ino" readers)"
    LMODE="$(dump_field "$ino" mode)"
    NLINK="$("$LOCK_POKE" "$DEV" --rec "$ino" | tr ' ' '\n' | awk -F= '$1 == "nlink" {print $2}')"
    : >"$go"
    wait "$pid" || true
    INO="$ino"
    [ "$NLINK" = 0 ] || { fail "setup: the record reads nlink=$NLINK -- the peer's unlink was not arranged"; ct_exit; }
}

printf 'data' >"$MNT/r"
printf 'data' >"$MNT/w"
sync

log "a read-open whose file is deleted between its read and its presence publish"
race r O_RDONLY
log "open=$OPEN readers=$READERS on ino $INO"
[ "$OPEN" != 0 ] && pass "the read-open was refused ($OPEN)" ||
    fail "the read-open succeeded on a record with nlink 0"
[ "$READERS" = 0x0 ] && pass "no presence bit was left on the deleted record" ||
    fail "presence $READERS was published on the deleted record -- an evict that already looked frees under it"

log "a write-open whose file is deleted between its read and its lock claim"
race w O_WRONLY
log "open=$OPEN lock_mode=$LMODE on ino $INO"
[ "$OPEN" != 0 ] && pass "the write-open was refused ($OPEN)" ||
    fail "the write-open succeeded on a record with nlink 0"
[ "$LMODE" = 0 ] && pass "no lock was claimed on the deleted record" ||
    fail "the exclusive lock (mode $LMODE) was claimed on the deleted record"

log "control: a file already open here still reopens after its unlink"
out="$(python3 -I - "$MNT/c" <<'PY'
import os, sys
p = sys.argv[1]
fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o644)
os.write(fd, b"data")
os.fsync(fd)
os.close(fd)
fd = os.open(p, os.O_RDONLY)
os.unlink(p)
try:
    fd2 = os.open("/proc/self/fd/%d" % fd, os.O_WRONLY)
    os.close(fd2)
    print("reopen=0")
except OSError as e:
    print("reopen=%d" % e.errno)
os.close(fd)
PY
)"
[ "$out" = reopen=0 ] && pass "an unlinked file this node holds open reopens for write" ||
    fail "reopening an unlinked file this node holds open failed: $out"

# No fsck: the two poked records read nlink 0 under names that are still
# in the directory, which fsck rightly reports -- that is the simulation.
umount "$MNT"
ct_exit
