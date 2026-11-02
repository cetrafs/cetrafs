#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a hole punch must refuse while a live peer has the file open
#
# cetrafs_setattr()'s own comment states the hazard about BOTH
# operations: "a truncate/punch landing under [a peer's open file] both
# frees blocks the writer is still extending into and gets its extent
# removal reverted by the writer's eventual flush, leaving extents that
# reference FREE blocks."
#
# The reasoning covered punch. The guard was only ever added to
# truncate. Under `nofilelock` -- the mount mode a VM datastore actually
# runs in -- no exclusive claim exists for the claim check to see, so a
# peer writing an image while this node punched a hole in it was simply
# allowed, and both halves of that sentence could happen.
#
# unlink, rename-replace, setattr, setxattr and eviction all answer
# -ETXTBSY here. Punch now does too.
#
# Discrimination: remove the check from cetrafs_fallocate()'s punch
# branch and the first assertion fails -- the punch succeeds and the
# blocks go back to the allocator while a peer still references them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 punchforeign)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt punchforeign)"
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

punch() {
    python3 - "$MNT/image" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
r = libc.fallocate(f, 0x02 | 0x01, ctypes.c_long(8 * 4096), ctypes.c_long(16 * 4096))
e = ctypes.get_errno()
os.close(f)
print("%d %d" % (r, e))
sys.stdout.flush()
PY
}

# The punch needs a write fd, and the access rule now refuses a
# write-open while a live peer reads (access_rule.sh) -- under the
# default mount this file could not be opened for write here at all.
# Turn that half off for this one open, so the punch's own check is
# the only thing that can refuse: it is still what stands between a
# nofilelock writer and a peer's blocks.
ct_param_set lock_ignore_readers 1
OUT="$(punch)"
ct_param_set lock_ignore_readers 0
RC="${OUT% *}"; ERR="${OUT#* }"
log "punch while a peer has it open -> rc=$RC errno=$ERR"

[ "$RC" != "0" ] && [ "$ERR" = "26" ] &&
    pass "the punch refused with ETXTBSY while a live peer held the file open" ||
    fail "the punch returned rc=$RC errno=$ERR: it freed blocks under a peer that is still using them"

FREE_NOW="$(sed -n 's/^free_data_blocks: //p' "$(ct_procdir "$DEV")/info")"
[ "$FREE_NOW" = "$FREE_BEFORE" ] &&
    pass "and no block went back to the allocator ($FREE_NOW)" ||
    fail "free_data_blocks moved $FREE_BEFORE -> $FREE_NOW despite the refusal"

# And it must work again once the peer is gone -- a refusal that never
# lifts is a different bug.
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null
"$LOCK_POKE" "$DEV" "$INO" --reader 65535 >/dev/null 2>&1 ||
    "$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null
ct_mount "$DEV" "$MNT"

OUT2="$(punch)"
RC2="${OUT2% *}"
[ "$RC2" = "0" ] &&
    pass "the punch works again once the peer is gone" ||
    fail "the punch still refuses (rc=$RC2) after the peer left -- the guard does not lift"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults"
pass "fsck clean"

ct_exit
