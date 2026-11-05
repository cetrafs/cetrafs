#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# under nofilelock a punch frees the blocks the CURRENT leaf names, not a cached one
#
# Under nofilelock "is my cached extent tree current?" is answered by a
# verdict -- does a peer have the file open, and did a peer stamp it --
# cached for up to a second. Fine for mapping a read; for evict,
# truncate and punch, which FREE what the leaves name, it is the wrong
# sign of staleness: a peer's session inside that second rewrote a leaf
# this node still had cached, and the punch freed the block the leaf
# USED to name -- by then not this file's (audit L6). The destructive
# paths now expire the verdict first, so the record is read fresh and a
# peer's stamp marks the tree cold.
#
# Staged on a depth-1 file on a nofilelock mount: the file is read (the
# verdict and the leaf are cached), then within the second a "peer"
# moves block 0 from P to a new block Q -- the leaf rewritten on the
# device, the record stamped -- and this node punches
# block 0. The punch must go for Q and leave P allocated (the peer's own
# free of P is not staged, so fsck names P as leaked).
#
# DISCRIMINATION: proven by removing cetrafs_lock_expire_verdicts() from
# the punch: the punch frees P and Q is the leak.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LEAF_POKE="$(ct_helper leaf_poke)"
REC_POKE="$(ct_helper inode_block_poke)"
FSCK="$ROOT/userspace/fsck.cetra"

IMG="$(ct_image 560 pfl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfl)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

# Depth 1: five separate extents spill the four inline slots.
for i in 0 1 2 3 4; do
    printf 'BLOCK%05d' "$i" | dd of="$MNT/v" bs=4096 seek=$((i * 2)) count=1 conv=notrunc status=none
    [ "$i" -lt 4 ] && printf x >"$MNT/spacer$i"
done
sync
INO="$(stat -c %i "$MNT/v")"
P="$("$LEAF_POKE" "$IMG" show "$INO" | sed -n 's/^ent 0 block=0 phys=\([0-9]*\) .*/\1/p')"
[ -n "$P" ] || { fail "setup: v has no depth-1 leaf entry for block 0: $("$LEAF_POKE" "$IMG" show "$INO" 2>&1 | head -2)"; ct_exit; }
# Q: where the peer moved block 0. Not given a bit: this node owns the
# only Block Group, a peer cannot allocate in it, and a bit poked under
# a mount that owns the bitmap is invisible to it anyway. So the punch's
# free of Q is refused as a double free -- which is the evidence the
# punch went for Q -- and P, the block the old leaf names, must stay
# allocated (fsck lists it as leaked).
Q=$((P + 100000))

OUT="$(ct_tmp pfl-out)"
MARK="$(dmesg_mark)"
python3 - "$MNT/v" "$LEAF_POKE" "$REC_POKE" "$IMG" "$INO" "$Q" >"$OUT" 2>&1 <<'PY' || true
import ctypes, os, subprocess, sys, time
libc = ctypes.CDLL(None, use_errno=True)
f, leaf_poke, rec_poke, img, ino, q = sys.argv[1:7]
fd = os.open(f, os.O_RDWR)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
os.pread(fd, 4096, 0)                  # the verdict and the leaf, cached now
t0 = time.monotonic()
subprocess.run([leaf_poke, img, "setphys", ino, "0", q], check=True, capture_output=True)
subprocess.run([rec_poke, img, "peerseq", ino, "1"], check=True, capture_output=True)
if libc.fallocate(fd, 3, ctypes.c_longlong(0), ctypes.c_longlong(4096)) != 0:
    print("SETUP punch failed", ctypes.get_errno())
print("ELAPSED %.2f" % (time.monotonic() - t0))
os.close(fd)
PY
log "$(tr '\n' ';' <"$OUT")"
grep -q "^SETUP" "$OUT" && { fail "setup: $(grep SETUP "$OUT")"; ct_exit; }
EL="$(sed -n 's/^ELAPSED //p' "$OUT")"
awk -v e="$EL" 'BEGIN { exit !(e < 0.9) }' || { fail "setup: the punch came ${EL}s after the read -- outside the cached second"; ct_exit; }
umount "$MNT"

LEAKS="$(CETRAFS_FSCK_DUMP_LEAKS=1 "$FSCK" "$DEV" 2>&1 | sed -n 's/^LEAK: lba=//p' | tr '\n' ' ')"
log "P=$P Q=$Q leaked: $LEAKS"
grep -qw "$P" <<<"$LEAKS" && pass "the punch did not free P, the block only the cached leaf still named" ||
    fail "the punch freed P through a stale cached leaf (leaked: $LEAKS)"
dmesg_since "$MARK" | grep -q "extent \[$Q +1)" && pass "it went for Q, the block the current leaf names" ||
    fail "the punch never tried to free Q"
ct_exit
