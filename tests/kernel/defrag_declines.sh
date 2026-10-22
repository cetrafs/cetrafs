#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag the janitor DECLINES must say so
#
# The worker exits silently on every path that declines: -EBUSY/-ESTALE
# from cetrafs_lock_defrag_begin(), and -ENOSPC/-EOPNOTSUPP/-ESTALE from
# cetrafs_defrag_inode(). Only a successful move is logged.
#
# That is not cosmetic. A SPARSE file is declined -EOPNOTSUPP, and a
# sparse VM image is the normal case here -- so a file that will never
# be defragmented leaves no trace saying why, and the fragmentation
# simply persists with nothing to explain it. It cost an hour of
# diagnosis while writing heartbeat_tick_work.sh, where a sparse probe
# file was being refused and the test sat waiting for a relocation the
# kernel had already decided against.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# This suite needs FRAGMENTED files: an external leaf, a depth-1 tree, an
# auto-defrag trigger. Speculative run allocation makes a sequential write
# land contiguously and merge into one extent, so the fragmentation its
# setup relies on never happens and the suite would test nothing (several
# assertions below check exactly that precondition, which is how this was
# caught). Turn runs off so allocation goes back one block at a time.
ct_param_set alloc_run_blocks 0
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 dfdecl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfdecl)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 1

log "a sparse file qualifies the gate but cannot be relocated"
# Strided writes: 24 single-block extents with holes between them, which
# clears both gates (>= 4 extents, index >= 200%) and so really does
# reach the worker -- and is then declined, because relocating a file
# with interior holes is not supported.
MARK="$(dmesg_mark)"
python3 - "$MNT/probe-a" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
blk = b's' * 4096
for i in range(24):
    os.pwrite(fd, blk, i * 2 * 4096)   # stride 2: a hole after every block
os.fsync(fd)
os.close(fd)
PY
sync
INO="$(stat -c '%i' "$MNT/probe-a")"
EXT="$("$IPOKE" "$IMG" extents "$INO")"
echo "$EXT" | grep -q "depth=1" &&
    pass "the sparse file is fragmented enough to reach the worker ($EXT)" ||
    fail "not fragmented enough: $EXT -- the worker would never be asked"

# Give the workqueue a moment; it is a separate thread.
for _ in $(seq 1 20); do
    dmesg_since "$MARK" | grep -q "auto-defrag: ino=$INO" && break
    sleep 1
done

if dmesg_since "$MARK" | grep -q "auto-defrag: ino=$INO"; then
    pass "the declined defrag is logged, naming the inode"
    dmesg_since "$MARK" | grep "auto-defrag: ino=$INO" | head -1 | sed 's/^/       /'
else
    fail "no auto-defrag line for ino=$INO -- a file that will never be defragmented says so nowhere"
fi
dmesg_since "$MARK" | grep "auto-defrag: ino=$INO" | grep -qiE "sparse|hole|not supported|declin" &&
    pass "...and says WHY, not merely that something happened" ||
    fail "the line gives no reason: $(dmesg_since "$MARK" | grep "auto-defrag: ino=$INO" | head -1)"

# The CLI, run by hand on the same sparse file, must explain itself too --
# the kernel returns EOPNOTSUPP for both "sparse" and "defrag disabled", and
# a bare strerror ("Operation not supported") leaves an operator guessing.
log "defrag.cetra on that sparse file explains itself, not an opaque errno"
DOUT="$("$ROOT/userspace/defrag.cetra" "$MNT/probe-a" 2>&1 || true)"
echo "$DOUT" | grep -qiE "sparse|disabled on this mount" &&
    pass "defrag.cetra: ${DOUT#*: }" ||
    fail "defrag.cetra gave an opaque message for a sparse file: $DOUT"

log "a declined file is left exactly as it was"
sync
AFTER="$("$IPOKE" "$IMG" extents "$INO")"
[ "$AFTER" = "$EXT" ] && pass "the sparse file is untouched ($AFTER)" ||
    fail "the file changed despite being declined: $EXT -> $AFTER"
SUM_OK="$(python3 -c "
import sys
d = open(sys.argv[1],'rb').read()
print('yes' if d[:4096] == b's'*4096 and d[4096:8192] == bytes(4096) else 'no')" "$MNT/probe-a")"
[ "$SUM_OK" = "yes" ] && pass "its data and holes are intact" || fail "content changed"

log "a successful defrag still logs its move"
# The control: the logging added for declines must not have replaced or
# broken the success path.
MARK2="$(dmesg_mark)"
python3 - "$MNT/dense" "$MNT/filler" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(sys.argv[2], os.O_CREAT | os.O_WRONLY, 0o644)
blk = b'd' * 4096
for i in range(24):          # dense, but interleaved so it fragments
    os.pwrite(a, blk, i * 4096)
    os.pwrite(b, blk, i * 4096)
os.fsync(a); os.fsync(b)
os.close(b); os.close(a)
PY
sync
DINO="$(stat -c '%i' "$MNT/dense")"
for _ in $(seq 1 30); do
    dmesg_since "$MARK2" | grep -q "auto-defrag: ino=$DINO" && break
    sleep 1
done
dmesg_since "$MARK2" | grep -q "auto-defrag: ino=$DINO" &&
    pass "a dense fragmented file is still relocated and logged" ||
    fail "the success path stopped logging: $(dmesg_since "$MARK2" | tail -2)"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
