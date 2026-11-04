#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer that opens the file DURING a punch or truncate is not run over
#
# punch_foreign_open.sh covers a peer already using the file when the
# punch starts. Punch and truncate decide that once, then build a whole
# new tree -- record reads, journalled leaf writes, a bitmap flush --
# and only then publish it, last writer wins, and free what it dropped.
# A peer that opened and wrote in that gap (a live migration's
# destination, a guest TRIM on the source) had its extents published
# over and its blocks freed (CLAUDE.md rule 15).
#
# Now the question is asked again right before the publish (refuse, free
# nothing) and right after it (keep the publish, free nothing: what the
# peer may still name stays allocated, for the scrub).
#
# A peer is a registered, beating node row plus its bit in the file's
# read_open_nodes, poked on the device while the punch is held by
# rebuild_stall_pre_ms / rebuild_stall_post_ms.
#
# Truncate has the same shape and gets the same two rounds.
#
# DISCRIMINATION: with cetrafs_rebuild_recheck() not asking, the pre
# rounds complete and free the blocks; with the post-publish check
# removed, the post rounds free them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/rebuild_stall_pre_ms ] || { skip "rebuild_stall_pre_ms is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 punchlate)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt punchlate)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
freeb() { sed -n 's/^free_data_blocks: //p' "$INFO"; }

# round <name> <knob> <op>: punch 16 blocks of a 64-block file, or
# truncate it to 8, held by <knob>; a peer opens the file meanwhile.
round() {
    local name="$1" knob="$2" op="$3" F="$MNT/image.$1" INO FREE0 OUT RC ERR RES
    RES="$(ct_tmp "punchlate-$name")"
    dd if=/dev/zero of="$F" bs=4096 count=64 conv=fsync status=none
    INO="$(stat -c '%i' "$F")"
    sync
    FREE0="$(freeb)"
    ct_param_set "$knob" 2000
    python3 - "$F" "$op" >"$RES" <<'PY' &
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
f = os.open(sys.argv[1], os.O_RDWR)
if sys.argv[2] == "punch":
    r = libc.fallocate(f, 0x02 | 0x01, ctypes.c_long(8 * 4096), ctypes.c_long(16 * 4096))
else:
    r = libc.ftruncate(f, ctypes.c_long(8 * 4096))
e = ctypes.get_errno()
os.close(f)
print("%d %d" % (r, e))
sys.stdout.flush()
PY
    local P=$!
    sleep 0.7
    "$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    "$LOCK_POKE" "$DEV" "$INO" --reader 1 >/dev/null
    wait "$P" || true
    ct_param_set "$knob" 0
    OUT="$(cat "$RES")"
    RC="${OUT% *}"; ERR="${OUT#* }"
    log "$name: $op -> rc=$RC errno=$ERR; free $FREE0 -> $(freeb)"
    case "$name" in
        *pre)
            [ "$RC" != 0 ] && [ "$ERR" = 26 ] &&
                pass "$name: the $op refused (ETXTBSY) when the peer arrived before its publish" ||
                fail "$name: the $op returned rc=$RC errno=$ERR with a peer that opened the file meanwhile"
            ;;
        *post)
            [ "$RC" = 0 ] &&
                pass "$name: the $op had already passed its last check, and completed" ||
                fail "$name: the $op returned rc=$RC errno=$ERR (setup: it should have passed its check)"
            ;;
    esac
    [ "$(freeb)" = "$FREE0" ] &&
        pass "$name: and nothing went back to the allocator under the peer" ||
        fail "$name: free_data_blocks moved $FREE0 -> $(freeb): blocks freed under a peer that opened the file"
    # The peer leaves.
    "$LOCK_POKE" "$DEV" "$INO" --reader 65535 >/dev/null 2>&1 || true
    "$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null
}

round pre rebuild_stall_pre_ms punch
round post rebuild_stall_post_ms punch
round tpre rebuild_stall_pre_ms truncate
round tpost rebuild_stall_post_ms truncate

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
