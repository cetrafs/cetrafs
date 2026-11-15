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
# The refusal is EOPNOTSUPP, not ETXTBSY: qemu's write-zeroes fallback
# past EOF and posix_fallocate() read it as "write the zeros yourself",
# where ETXTBSY was a guest I/O error for a whole migration pre-copy
# (audit 2026-11-15 B-11). For the same reason a resize to the size the
# file already has succeeds -- it frees nothing -- while a real resize
# stays refused.
#
# DISCRIMINATION: remove the check from cetrafs_fallocate()'s ALLOCATE
# branch and the first assertion fails -- the preallocation succeeds and
# takes blocks while the peer is still using the file.
# falloc_foreign_etxtbsy=1 (the old answers): ETXTBSY for both.
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

# trunc <blocks> -> "<rc> <errno>"
trunc() {
    python3 - "$MNT/image" "$1" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_RDWR)
try:
    os.ftruncate(f, int(sys.argv[2]) * 4096); print("0 0")
except OSError as e:
    print("-1 %d" % e.errno)
os.close(f)
PY
}

# A write fd is needed, and the access rule refuses a write-open while
# a live peer reads (access_rule.sh). Turn that half off for this one
# open, so fallocate's own check is the only thing that can refuse.
ct_param_set lock_ignore_readers 1
OUT="$(falloc)"
TSAME="$(trunc 64)"
TGROW="$(trunc 80)"
ct_param_set falloc_foreign_etxtbsy 1
COUT="$(falloc)"
CSAME="$(trunc 64)"
ct_param_set falloc_foreign_etxtbsy 0
ct_param_set lock_ignore_readers 0
RC="${OUT% *}"; ERR="${OUT#* }"
log "fallocate while a peer has it open -> rc=$RC errno=$ERR; truncate same size -> $TSAME, grow -> $TGROW"
log "control (old answers): fallocate -> $COUT, truncate same size -> $CSAME"

[ "$RC" != "0" ] && [ "$ERR" = "95" ] &&
    pass "the preallocation refused with EOPNOTSUPP while a live peer held the file open" ||
    fail "the preallocation returned rc=$RC errno=$ERR: not the EOPNOTSUPP refusal"
[ "$TSAME" = "0 0" ] && pass "a resize to the current size succeeds" || fail "a same-size resize returned $TSAME"
[ "$TGROW" = "-1 26" ] && pass "a real resize stays refused (ETXTBSY)" || fail "a real resize returned $TGROW"
[ "$COUT" = "-1 26" ] && [ "$CSAME" = "-1 26" ] && pass "control: the old answers were ETXTBSY for both" ||
    fail "control: the old answers were $COUT / $CSAME -- the knob does not reach them"

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
