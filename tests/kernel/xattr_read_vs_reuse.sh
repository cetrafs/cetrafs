#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless xattr read never returns another file's xattr
#
# getxattr and listxattr take no lock: they read the record fresh, then
# read the xattr block it names. Nothing ties the second read to the
# first. A peer that removed this file's last xattr freed the block in
# between; another file's setxattr then took it, and the read found a
# perfectly valid xattr block -- magic and checksum intact -- belonging
# to somebody else, and returned its value as this file's.
#
# Played on one node: getxattr on file A is paused between its record
# read and its block read; meanwhile, on the device, A's record loses
# its xattr block and that block is filled with file B's xattr block.
#
# DISCRIMINATION (measured on the old code): getxattr on A returns B's
# value.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_read_pause_ms ] || { skip "xattr_read_pause_ms is missing"; ct_exit; }

REC_POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 xrr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xrr)"
B_BLOCK="$(ct_tmp xrr-b)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

: >"$MNT/a"
: >"$MNT/b"
python3 -I -c "
import os, sys
os.setxattr(sys.argv[1], 'user.k', b'value-of-A')
os.setxattr(sys.argv[2], 'user.k', b'value-of-B')
os.setxattr(sys.argv[2], 'user.bonly', b'x')" "$MNT/a" "$MNT/b"
sync
AINO="$(stat -c %i "$MNT/a")"
BINO="$(stat -c %i "$MNT/b")"
LA="$("$REC_POKE" "$IMG" xattrblk "$AINO")"
LB="$("$REC_POKE" "$IMG" xattrblk "$BINO")"
[ "$LA" -gt 0 ] && [ "$LB" -gt 0 ] && [ "$LA" != "$LB" ] ||
    { fail "setup: xattr blocks a=$LA b=$LB"; ct_exit; }
dd if="$IMG" of="$B_BLOCK" bs=4096 skip="$LB" count=1 status=none
pass "setup: A's xattr lives in block $LA, B's in $LB"

ct_param_set xattr_read_pause_ms 1500
OUT="$(ct_tmp xrr-out)"
MARK="$(dmesg_mark)"
python3 -I -c "
import errno, os, sys
try:
    print(os.getxattr(sys.argv[1], 'user.k').decode())
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
sys.stdout.flush()" "$MNT/a" >"$OUT" 2>&1 &
PID=$!
wait_for 15 "dmesg_since '$MARK' | grep -q 'ino=$AINO pausing'" ||
    { kill "$PID" 2>/dev/null; fail "setup: the read never paused"; ct_exit; }
# The peer: A's xattrs are gone, and its old block is B's now.
"$REC_POKE" "$IMG" xattrblk "$AINO" 0 >/dev/null
dd if="$B_BLOCK" of="$IMG" bs=4096 seek="$LA" conv=notrunc status=none
wait "$PID" || true
ct_param_set xattr_read_pause_ms 0
GOT="$(cat "$OUT")"
log "getxattr on A returned: $GOT"
case "$GOT" in
value-of-B) fail "getxattr on A returned B's value from a block A no longer owns" ;;
value-of-A) fail "getxattr on A returned A's old value from a block A no longer owns" ;;
ENODATA) pass "getxattr on A sees that A has no xattrs any more" ;;
*) fail "getxattr on A returned '$GOT'" ;;
esac

log "the same for listxattr"
# Put A back as it was, then replay the reuse under a paused listing.
umount "$MNT"
"$REC_POKE" "$IMG" xattrblk "$AINO" "$LA" >/dev/null
ct_mount "$DEV" "$MNT"
python3 -I -c "
import os, sys
os.setxattr(sys.argv[1], 'user.k', b'value-of-A')" "$MNT/a"
sync
[ "$("$REC_POKE" "$IMG" xattrblk "$AINO")" = "$LA" ] || { fail "setup: A's xattr block moved to $("$REC_POKE" "$IMG" xattrblk "$AINO")"; ct_exit; }
ct_param_set xattr_read_pause_ms 1500
MARK="$(dmesg_mark)"
python3 -I -c "
import errno, os, sys
try:
    print(','.join(sorted(os.listxattr(sys.argv[1]))) or 'EMPTY')
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
sys.stdout.flush()" "$MNT/a" >"$OUT" 2>&1 &
PID=$!
wait_for 15 "dmesg_since '$MARK' | grep -q 'ino=$AINO pausing'" ||
    { kill "$PID" 2>/dev/null; fail "setup: the listing never paused"; ct_exit; }
"$REC_POKE" "$IMG" xattrblk "$AINO" 0 >/dev/null
dd if="$B_BLOCK" of="$IMG" bs=4096 seek="$LA" conv=notrunc status=none
wait "$PID" || true
ct_param_set xattr_read_pause_ms 0
GOT="$(cat "$OUT")"
log "listxattr on A returned: $GOT"
[ "$GOT" = EMPTY ] && pass "listxattr on A lists nothing" ||
    fail "listxattr on A returned '$GOT' from a block A no longer owns"

umount "$MNT"
ct_exit
