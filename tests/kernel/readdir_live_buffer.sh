#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# readdir emits names from a validated copy of the block, not the live buffer
#
# A dirent block is validated when it is read -- checksum, and a
# name_len that fits its field -- and readdir then handed dir_emit() a
# pointer into the buffer. A forced-fresh reader in another thread
# re-reads the device into that same buffer, and an image with a valid
# checksum and a name_len of 4000 landing in between was emitted as is:
# the VFS bounds a name at PATH_MAX, so ~4 KiB of adjacent kernel memory
# went to userspace (audit 2026-11-14 RT-1). The walk now visits a copy
# taken under the buffer lock and re-validated.
#
# Reader A's walk is held after reading the block (dir_walk_stall_ms);
# the block on the device is made hostile (valid CRC, name_len 400);
# the directory's dirent_seq is bumped as a peer's change would, and
# reader B lists it, re-reading the block fresh into the same buffer. A's names must all be at most 255 bytes.
#
# DISCRIMINATION: dir_walk_no_copy visits the live buffer, as before; A
# then returns a 400-byte name.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in dir_walk_stall_ms dir_walk_no_copy; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
POKE="$(ct_helper dirent_field_poke)"
EXTENT="$(ct_helper pending_poke)"
SEQ="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt rdlb)"
ct_track mnt "$MNT"
ct_param_set dir_walk_stall_ms 0
ct_param_set dir_walk_no_copy 0
P=/sys/module/cetrafs/parameters
OUT="$(ct_tmp rdlb-out)"

# <no_copy 0|1> -> the longest name reader A got (or an error)
probe() {
    local img dev ino blk
    img="$(ct_image 560 "rdlb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    for i in 1 2 3 4 5; do : >"$MNT/d/file-$i"; done
    sync
    ino="$(stat -c %i "$MNT/d")"
    blk="$("$EXTENT" "$img" extent "$ino" | cut -d' ' -f1)"
    echo "$1" >$P/dir_walk_no_copy
    python3 -c '
import ctypes, os, struct, sys
# Raw getdents64: readdir(3) and os.listdir() stop a name at its first
# NUL, which hides a long name that is mostly zeros. The record
# length does not.
nr = {"x86_64": 217, "aarch64": 61}[os.uname().machine]
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
# Armed only now: the stall is one-shot, and the lookup of the path
# above walks the parent directory.
open(sys.argv[2], "w").write("3000")
buf = ctypes.create_string_buffer(65536)
longest = 0
while True:
    n = libc.syscall(nr, fd, buf, len(buf))
    if n < 0:
        # A later call re-reads the now-hostile block fresh and is
        # refused; what matters is what the held walk already emitted.
        print(longest if longest else "err-%d" % ctypes.get_errno()); sys.exit(0)
    if n == 0:
        break
    off = 0
    while off < n:
        reclen = struct.unpack_from("H", buf.raw, off + 16)[0]
        longest = max(longest, reclen - 19 - 1)
        off += reclen
print(longest)' "$MNT/d" $P/dir_walk_stall_ms >"$OUT" &
    sleep 1
    # 400, not thousands: past the 255-byte field and into the next
    # entry, but short of the bytes where filldir's own '/' scan would
    # refuse the name and hide what was read.
    "$POKE" "$img" "$blk" 0 name_len 400 >/dev/null
    # As a peer's change would: reader B finds dirent_seq moved and
    # re-reads every block forced-fresh, into the buffer A holds.
    "$SEQ" "$img" bumpseq "$ino" >/dev/null
    ls "$MNT/d" >/dev/null 2>&1 || true
    wait || true
    echo 0 >$P/dir_walk_no_copy
    echo 0 >$P/dir_walk_stall_ms
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    cat "$OUT"
}
R="$(probe 0)"
log "reader A's longest name: $R"
case "$R" in
err-*) pass "reader A refused the block that changed under it ($R)" ;;
*) [ "$R" -le 255 ] && pass "reader A emitted only names that fit the field (longest $R)" ||
    fail "reader A emitted a $R-byte name -- read past the name field from the live buffer" ;;
esac
R0="$(probe 1)"
log "control: reader A's longest name: $R0"
case "$R0" in
err-*) fail "control: the live-buffer walk failed ($R0) -- the suite cannot tell" ;;
*) [ "$R0" -gt 255 ] && pass "control: the live buffer hands A a $R0-byte name -- the suite discriminates" ||
    fail "control: the live-buffer walk emitted nothing longer than $R0 -- the suite cannot tell" ;;
esac
ct_exit
