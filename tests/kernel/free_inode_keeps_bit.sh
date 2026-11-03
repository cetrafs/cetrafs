#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create's unwind frees its inode number only once the record is dead, and never calls a blank record corrupt
#
# cetrafs_free_inode() is what every create/mkdir/symlink unwind calls.
# Two faults in it:
#
#   A. A create that failed before writing its record (mkdir on a full
#      volume: the number is taken, the '.'/'..' block is not) leaves an
#      all-zero record. The free read it with cetrafs_read_raw_inode(),
#      which burned its retries on the checksum and reported the number
#      as DAMAGED: corruptions: 1, "run fsck" in the log, and -- under
#      corruption=stop -- the mount stopped, for an ordinary ENOSPC.
#      The mark also outlived the number: the next file handed it was
#      refused every write (EUCLEAN). Now the free reads raw, as the
#      allocator does, and an all-zero record is simply a dead one; and
#      a mark is dropped when this node gives the number a new record.
#
#   B. A create whose record was written and whose iget then failed
#      calls the free with a record claiming one link. If the free could
#      not zero it (here: its read fails too), it cleared the bit anyway.
#      The next create to draw the number refused it with EIO -- the
#      allocator will not hand out a record that claims links -- and kept
#      it, an unnamed live-looking inode. Now the bit stays set: a leak,
#      which fsck reports as a leftover and -r frees.
#
# DISCRIMINATION: A fails on the previous code (corruptions 1). B fails
# if the free clears the bit regardless (the next create gets EIO).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in iget_read_fail free_inode_read_fail; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

SBPOKE="$(ct_helper sb_poke)"
IMG="$(ct_image 560 freeino)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt freeino)"
FSCK="$ROOT/userspace/fsck.cetra"
ct_mkfs_small "$DEV" >/dev/null
IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { sed -n "s/^$1: //p" "$PROC/info"; }
lowest_free() { # the number the next create takes: the lowest clear bit
    blockdev --flushbufs "$DEV"
    python3 -I - "$DEV" "$IBM" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
b = os.pread(fd, 4096, int(sys.argv[2]) * 4096)
print(next(i + 1 for i in range(len(b) * 8) if not (b[i // 8] >> (i % 8)) & 1))
PY
}
bit() { # <ino>: the inode's bit on the device
    blockdev --flushbufs "$DEV"
    python3 -I - "$DEV" "$IBM" "$1" <<'PY'
import os, sys
dev, ibm, ino = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fd = os.open(dev, os.O_RDONLY)
print((os.pread(fd, 1, ibm * 4096 + (ino - 1) // 8)[0] >> ((ino - 1) % 8)) & 1)
os.close(fd)
PY
}

# ---------------------------------------------------------------- A
log "A: mkdir on a full volume, on a number never used before"
dd if=/dev/zero of="$MNT/fill" bs=1M status=none 2>/dev/null || true
sync
MARK="$(dmesg_mark)"
C0="$(info corruptions)"
if mkdir "$MNT/d" 2>/dev/null; then
    fail "A: setup: mkdir succeeded on a full volume -- the unwind under test did not run"
    ct_exit
fi
pass "A: setup: mkdir failed (ENOSPC) after taking an inode number"
[ "$(info corruptions)" = "$C0" ] && pass "A: no corruption counted for the blank record" ||
    fail "A: corruptions went $C0 -> $(info corruptions) for an ordinary ENOSPC"
dmesg_since "$MARK" | grep -qE "failed its record checksum|damaged" &&
    fail "A: the log calls it damage: $(dmesg_since "$MARK" | grep -E 'checksum|damaged' | head -1)" ||
    pass "A: and the log says nothing about damage"
truncate -s 64M "$MNT/fill"
sync
echo data >"$MNT/after" 2>/dev/null && [ "$(cat "$MNT/after")" = data ] &&
    pass "A: the next file is created and written (ino $(stat -c %i "$MNT/after"))" ||
    fail "A: the next file could not be written"

# ---------------------------------------------------------------- B
log "B: a create whose iget fails, and whose free cannot read the record"
MARK="$(dmesg_mark)"
sync
N="$(lowest_free)"
ct_param_set iget_read_fail 1
ct_param_set free_inode_read_fail 1
if touch "$MNT/b1" 2>/dev/null; then
    fail "B: setup: the create succeeded -- iget_read_fail was not reached"
    ct_exit
fi
LEFT="$(cat /sys/module/cetrafs/parameters/iget_read_fail)$(cat /sys/module/cetrafs/parameters/free_inode_read_fail)"
ct_param_set iget_read_fail 0
ct_param_set free_inode_read_fail 0
[ "$LEFT" = 00 ] &&
    pass "B: setup: the create took ino $N, its iget failed, and its free could not read the record" ||
    { fail "B: setup: knobs left '$LEFT' -- the create did not fail where intended"; ct_exit; }
[ "$(bit "$N")" = 1 ] && pass "B: ino $N keeps its bit" || fail "B: ino $N's bit was cleared under a live-looking record"
touch "$MNT/b2" 2>/dev/null && [ "$(stat -c %i "$MNT/b2")" != "$N" ] &&
    pass "B: the next create takes another number and succeeds" ||
    fail "B: the next create failed or reused ino $N: $(dmesg_since "$MARK" | grep -m1 'refusing to hand' || true)"
ct_umount "$MNT"
rc=0
OUT="$("$FSCK" "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && grep -q "inode $N is an empty file (nlink=1) that no directory entry names" <<<"$OUT" &&
    pass "B: fsck reports ino $N as an interrupted create, exit 0" ||
    fail "B: fsck rc=$rc: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)"
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
OUT="$("$FSCK" "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "B: after fsck -r: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)" ||
    pass "B: fsck -r frees it"
ct_exit
