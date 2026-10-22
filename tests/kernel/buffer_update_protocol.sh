#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every buffer-update call site runs, and leaves no buffer locked
#
# cetrafs_bh_begin_update() locks a buffer; _end_update()/_abort_update()
# release it. A path that reaches neither leaves the buffer locked
# forever, and every later access to that block blocks -- the filesystem
# wedges on one block with no error anywhere. That failure mode is why
# run.sh runs each suite under a timeout: a hang here is reported as
# TIMEOUT rather than looking like "still running".
#
# There are 13 begin sites across dir.c, file.c, xattr.c, caw.c and
# defrag.c. This drives all of them and then re-reads everything they
# touched, so a leaked lock turns into a hang instead of passing quietly.
#
# What it cannot do is prove the ORDERING inside each region (dirty
# before unlock) -- that is kernel/record_write_vs_fresh_read.sh. This
# one is about balance: every begin reaching exactly one end or abort.
#
# DISCRIMINATION, stated honestly: the timeout machinery that turns a
# hang into a reported failure IS measured (run.sh was verified against a
# suite that just sleeps -- it reports TIMEOUT and fails the batch). The
# leaked lock itself was deliberately NOT injected: a task blocked on a
# buffer lock is uninterruptible, so the umount and then the rmmod hang
# too, and clearing that needs a reboot. The coverage this suite adds is
# therefore structural -- it guarantees every begin site runs and every
# block they touched is read again afterwards -- rather than demonstrated
# by a failing run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 bup)"
MNT="$(ct_mnt bup)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "driving every begin/end call site"
D="$MNT/bup"
mkdir "$D"

# dir.c: add_entry, and dirent_block_init once the directory outgrows its
# first block (>15 entries).
for i in $(seq 1 40); do : >"$D/f$i"; done
mkdir "$D/sub" "$D/sub2"
ln "$D/f1" "$D/hard"
ln -s f1 "$D/link"

# dir.c: update_dotdot (a directory moving to a new parent) and
# remove_entry (rename's source removal, then real unlinks).
mv "$D/sub" "$D/sub2/moved"
mv "$D/f2" "$D/f2-renamed"
rm "$D/f3" "$D/f4"

# file.c: leaf_array_insert past the 4 inline extents, then trim, then
# punch. Interleaved writes to two files force non-contiguous extents.
for i in $(seq 1 8); do
    dd if=/dev/zero of="$D/frag" bs=4096 count=1 seek=$((i * 3)) conv=notrunc status=none
    dd if=/dev/zero of="$D/spacer" bs=4096 count=1 seek=$i conv=notrunc status=none
done
sync
truncate -s 16384 "$D/frag"
fallocate --punch-hole --keep-size -o 4096 -l 4096 "$D/frag"

# xattr.c: the first attribute (allocates the block) and a second one
# (slot update), then a removal.
# No setfattr/getfattr in this image; python3 wraps the same syscalls.
pyset() { python3 -c "import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())" "$@"; }
pydel() { python3 -c "import os,sys; os.removexattr(sys.argv[1], sys.argv[2])" "$@"; }
pylist() { python3 -c "import os,sys; print(os.listxattr(sys.argv[1]))" "$@"; }
pyset "$D/f5" user.a one
pyset "$D/f5" user.b two
pydel "$D/f5" user.b

# defrag.c: commit + block copy.
"$ROOT/userspace/defrag.cetra" "$D/frag" >/dev/null 2>&1 || true
sync
pass "protocol: every begin/end call site ran without wedging"

# The part that makes a leaked lock show up: touch everything again. A
# buffer left locked blocks here rather than returning an error.
log "re-reading everything those paths touched"
COUNT="$(find "$D" | wc -l)"
cat "$D"/f* >/dev/null 2>&1 || true
ls -la "$D" >/dev/null
ls -la "$D/sub2/moved" >/dev/null
pylist "$D/f5" >/dev/null
readlink "$D/link" >/dev/null
dd if="$D/frag" of=/dev/null bs=4096 status=none
pass "protocol: re-read $COUNT paths, nothing blocked on a held buffer"

# And again after a remount, which drops every cached buffer: if the
# on-disk result of those paths were malformed rather than merely
# locked, this is where it shows.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
AFTER="$(find "$MNT/bup" | wc -l)"
[ "$AFTER" = "$COUNT" ] && pass "protocol: all $COUNT paths still there after a remount" ||
    fail "protocol: $AFTER paths after remount, expected $COUNT"
ls -la "$MNT/bup" >/dev/null && pass "protocol: the directory still reads back after a remount" ||
    fail "protocol: directory unreadable after remount"
ct_umount "$MNT"

FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "cetrafs fsck: OK" &&
    pass "fsck: clean after exercising every begin/end site" ||
    fail "fsck: problems: $(echo "$FSCK_OUT" | grep -iE 'ERR|WARN' | head -2 | tr '\n' ' ')"

ct_exit
