#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer that changed the file during a truncate/punch is not published over
#
# punch_peer_late.sh covers a peer that OPENS the file while a punch or
# truncate is building its new tree: the pre-publish recheck sees it
# open and refuses. That recheck is presence, not change (CLAUDE.md rule
# 10): a peer session that opened, appended and CLOSED inside the window
# leaves nobody open and a different tree on the device. A path-based
# truncate(2) holds only the namespace lock, which a peer's write-open
# does not take, so in the DEFAULT mode that window is real; under
# nofilelock punch has the same one.
#
# Now the publish carries the file_seq its plan was read at, and refuses
# (ETXTBSY) when another node has stamped the file sector since.
#
# The peer's session is the record it would leave behind -- a larger
# size and a file_seq stamped with its node id -- poked on the device
# while the operation is held by rebuild_stall_pre_ms, with no presence
# bit, so the existing recheck has nothing to see.
#
# DISCRIMINATION: with rebuild_plan_unchecked=1 (the old publish), both
# rounds publish over the peer: the size goes back to the planned one
# and the dropped blocks are freed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/rebuild_plan_unchecked ] || { skip "rebuild_plan_unchecked is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 rbstamp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rbstamp)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
freeb() { sed -n 's/^free_data_blocks: //p' "$INFO"; }
PEER_SIZE=$((80 * 4096))

# round <name> <op>: truncate the 64-block file to 8 blocks by PATH, or
# punch 16 blocks out of it through an fd; a peer's session lands
# during the stall.
round() {
    local name="$1" op="$2" F="$MNT/file.$1" INO FREE0 RES OUT RC ERR SIZE
    RES="$(ct_tmp "rbstamp-$name")"
    dd if=/dev/urandom of="$F" bs=4096 count=64 conv=fsync status=none
    INO="$(stat -c '%i' "$F")"
    sync
    FREE0="$(freeb)"
    ct_param_set rebuild_stall_pre_ms 2000
    python3 - "$F" "$op" >"$RES" <<'PY' &
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
if sys.argv[2] == "punch":
    f = os.open(sys.argv[1], os.O_RDWR)
    r = libc.fallocate(f, 0x02 | 0x01, ctypes.c_long(8 * 4096), ctypes.c_long(16 * 4096))
    e = ctypes.get_errno()
    os.close(f)
else:
    r = libc.truncate(sys.argv[1].encode(), ctypes.c_long(8 * 4096))
    e = ctypes.get_errno()
print("%d %d" % (r, e))
sys.stdout.flush()
PY
    local P=$!
    sleep 0.7
    # The peer's whole session: it opened, wrote past the end, closed.
    "$IPOKE" "$IMG" setsize "$INO" "$PEER_SIZE" 2>/dev/null
    "$IPOKE" "$IMG" peerseq "$INO" 1 2>/dev/null
    wait "$P" || true
    ct_param_set rebuild_stall_pre_ms 0
    OUT="$(cat "$RES")"
    RC="${OUT% *}"; ERR="${OUT#* }"
    SIZE="$("$IPOKE" "$IMG" size "$INO")"
    log "$name: $op -> rc=$RC errno=$ERR; record size $SIZE; free $FREE0 -> $(freeb)"
    [ "$RC" != 0 ] && [ "$ERR" = 26 ] &&
        pass "$name: the $op refused (ETXTBSY): a peer stamped the file since it was planned" ||
        fail "$name: the $op returned rc=$RC errno=$ERR over a peer's session it never saw"
    [ "$SIZE" = "$PEER_SIZE" ] &&
        pass "$name: the record still carries the peer's size ($SIZE)" ||
        fail "$name: the record's size is $SIZE, not the peer's $PEER_SIZE: published over"
    [ "$(freeb)" = "$FREE0" ] &&
        pass "$name: nothing went back to the allocator" ||
        fail "$name: free_data_blocks moved $FREE0 -> $(freeb): blocks the peer's tree names were freed"
}

round trunc truncate
round punch punch

ct_umount "$MNT"
ct_exit
