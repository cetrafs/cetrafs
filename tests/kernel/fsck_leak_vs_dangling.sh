#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r does not free a named file's blocks as "leaked"
#
# The content pass walks only records whose inode bit is set, so a file
# a directory still names but whose bit is clear owns blocks that look
# leaked -- marked in use, referenced by no allocated record. -r cleared
# them there and then. The namespace pass, later, found the dirent
# naming a FREE inode and blocked repair -- after the file's data had
# already been handed back to the allocator.
#
# Staged: a file with data, its inode bit cleared. After fsck -r the bit
# is put back (the repair an operator makes for a dangling entry), and a
# read-only fsck must find every one of the file's blocks still marked.
#
# DISCRIMINATION: with the leak clear done in the content pass, the
# restored file's blocks read "referenced by an inode but marked FREE".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 leakdangle)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt leakdangle)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/named" bs=4096 count=8 status=none
INO="$(stat -c %i "$MNT/named")"
ct_umount "$MNT"
blockdev --flushbufs "$DEV"

IBM="$("$SBPOKE" "$IMG" | sed -n 's/^inode_bmap_start=//p')"
[ -n "$IBM" ] || { fail "setup: no inode_bmap_start"; ct_exit; }
OFF=$((IBM * 4096 + (INO - 1) / 8)); MASK=$((1 << ((INO - 1) % 8)))
flip_bit() {   # $1 = set|clear
    python3 - "$IMG" "$OFF" "$MASK" "$1" <<'PY'
import sys
p, off, mask, op = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with open(p, 'r+b') as f:
    f.seek(off); b = f.read(1)[0]
    b = (b | mask) if op == 'set' else (b & ~mask & 0xff)
    f.seek(off); f.write(bytes([b]))
PY
    blockdev --flushbufs "$DEV"
}
flip_bit clear

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
grep -q "names inode $INO, which is marked FREE" <<<"$OUT" && grep -qE 'WARN: [0-9]+ data block\(s\) .*leaked' <<<"$OUT" ||
    { fail "setup: fsck -r did not see both the dangling entry and the 'leaked' blocks: $(grep -E 'ERR|WARN' <<<"$OUT" | head -3)"; ct_exit; }
pass "setup: fsck -r saw inode $INO named but FREE, and its blocks as leaked"

flip_bit set
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -q 'referenced by an inode but marked FREE' <<<"$OUT"; then
    fail "fsck -r freed the named file's blocks: $(grep -m1 'marked FREE' <<<"$OUT")"
else
    pass "the named file's blocks are all still marked in use"
fi
ct_exit
