#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# preallocation must refuse while a live peer has the file open
#
# cetrafs_setattr() names the hazard for truncate and punch: an
# operation that rewrites the extent map under a peer's open file. Both
# refuse with -ETXTBSY (punch_foreign_open.sh). fallocate's ALLOCATE
# mode is the third: it appends preallocated extents to a copy of the
# record and publishes the whole file sector, last writer wins. Under
# `nofilelock` no exclusive claim stands in the way, so a peer writing
# the image meanwhile had its new extents published over -- their
# blocks referenced by nothing, its data gone.
#
# DISCRIMINATION: remove the check from cetrafs_fallocate()'s ALLOCATE
# branch and the first assertion fails -- the preallocation succeeds and
# takes blocks while the peer is still using the file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 fallocforeign)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fallocforeign)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

dd if=/dev/zero of="$MNT/image" bs=4096 count=64 conv=fsync status=none
INO="$(stat -c '%i' "$MNT/image")"
FREE_BEFORE="$(sed -n 's/^free_data_blocks: //p' "$(ct_procdir "$DEV")/info")"
ct_umount "$MNT"

# A peer that registered, still beats, and has the file OPEN -- not a
# lock claim: under nofilelock there is none, which is the whole point.
"$LOCK_POKE" "$DEV" "$INO" --reader 1 >/dev/null
ct_mount "$DEV" "$MNT"
"$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null

falloc() {
    python3 - "$MNT/image" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
r = libc.fallocate(f, 0x01, ctypes.c_long(64 * 4096), ctypes.c_long(64 * 4096))
e = ctypes.get_errno()
os.close(f)
print("%d %d" % (r, e))
sys.stdout.flush()
PY
}

# A write fd is needed, and the access rule refuses a write-open while
# a live peer reads (access_rule.sh). Turn that half off for this one
# open, so fallocate's own check is the only thing that can refuse.
ct_param_set lock_ignore_readers 1
OUT="$(falloc)"
ct_param_set lock_ignore_readers 0
RC="${OUT% *}"; ERR="${OUT#* }"
log "fallocate while a peer has it open -> rc=$RC errno=$ERR"

[ "$RC" != "0" ] && [ "$ERR" = "26" ] &&
    pass "the preallocation refused with ETXTBSY while a live peer held the file open" ||
    fail "the preallocation returned rc=$RC errno=$ERR: it rewrote the map of a file a peer is still using"

FREE_NOW="$(sed -n 's/^free_data_blocks: //p' "$(ct_procdir "$DEV")/info")"
[ "$FREE_NOW" = "$FREE_BEFORE" ] &&
    pass "and took no block from the allocator ($FREE_NOW)" ||
    fail "free_data_blocks moved $FREE_BEFORE -> $FREE_NOW despite the refusal"

# And it must work again once the peer is gone -- a refusal that never
# lifts is a different bug.
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null
"$LOCK_POKE" "$DEV" "$INO" --reader 65535 >/dev/null 2>&1 ||
    "$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null
ct_mount "$DEV" "$MNT"

OUT2="$(falloc)"
RC2="${OUT2% *}"
[ "$RC2" = "0" ] &&
    pass "the preallocation works again once the peer is gone" ||
    fail "the preallocation still refuses (rc=$RC2) after the peer left -- the guard does not lift"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
