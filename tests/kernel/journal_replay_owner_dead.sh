#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replay entry whose owner is a dead record is not redone onto a block that record still names
#
# Replay confirms an entry's target is still a block of the inode the
# entry names: same generation, and the record still references it. A
# deleted file's record keeps naming its tree and xattr blocks until the
# free that claimed it forgets them, and evict frees the blocks FIRST --
# so for that span a block already handed to another file still "belongs"
# to the dead record, and a dead node's entry for it was redone over the
# new owner's block (audit 2026-11-15 BL-62). A dead owner (nlink 0) now
# holds nothing.
#
# Staged on one node: f is given an xattr block (state A), then a second
# xattr (state B, block T) -- T is f's live block. A dead record (nlink
# 0) is planted naming T as its xattr block, as the deleted file's
# record would while its free is in flight; a stale peer's journal holds
# one entry for T carrying A, guarded against B, naming that record.
#   setup: T is f's and the dead record names it;
#   1. the redo was refused as "no longer a block of its owner";
#   2. T still holds f's B;
#   3. f's xattrs read back intact.
#
# DISCRIMINATION: journal_owner_dead_ok=1 restores the old verdict; the
# control requires T overwritten with A.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_owner_dead_ok ] ||
    { skip "journal_owner_dead_ok is missing"; ct_exit; }
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
OWNER=900
xset() { python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], b"x" * int(sys.argv[3]))' "$@"; }
xlen() { python3 -I -c 'import os,sys; print(len(os.getxattr(sys.argv[1], sys.argv[2])))' "$@" 2>/dev/null; }

ct_param_set hb_interval_secs 2
ct_param_set journal_owner_dead_ok 0

# run <control 0|1>
run() {
    local ctl="$1" tag="jrod$1"
    local IMG DEV MNT NID PEER FI T A ASUM BSUM MARK i got refused D
    IMG="$(ct_image 560 "$tag")"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt "$tag")"
    ct_track mnt "$MNT"
    info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
    blk() { dd if="$IMG" bs=4096 skip="$1" count=1 status=none | sha256sum | cut -d' ' -f1; }
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo data >"$MNT/f"
    xset "$MNT/f" user.a 200
    FI="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    T="$("$IPOKE" "$IMG" xattrblk "$FI" 2>/dev/null)"
    [ -n "$T" ] && [ "$T" != 0 ] || { fail "setup($ctl): f has no xattr block"; return; }
    A="$(ct_tmp "$tag-a")"
    dd if="$IMG" of="$A" bs=4096 skip="$T" count=1 status=none
    ASUM="$(sha256sum <"$A" | cut -d' ' -f1)"

    ct_mount "$DEV" "$MNT"
    NID="$(info this_node_id)"
    PEER=$(((NID + 1) % 4))
    xset "$MNT/f" user.b 4
    sync
    ct_umount "$MNT"
    T="$("$IPOKE" "$IMG" xattrblk "$FI" 2>/dev/null)"
    [ -n "$T" ] && [ "$T" != 0 ] || { fail "setup($ctl): f lost its xattr block"; return; }
    BSUM="$(blk "$T")"
    [ "$BSUM" != "$ASUM" ] || { fail "setup($ctl): the xattr block did not change (A = B)"; return; }

    # The deleted file's record: same number and generation the entry
    # names, nlink 0, still naming T.
    "$IPOKE" "$IMG" plantrec "$OWNER" 0100644 >/dev/null 2>&1 || { fail "setup($ctl): no slot for ino $OWNER"; return; }
    "$IPOKE" "$IMG" xattrblk "$OWNER" "$T" >/dev/null 2>&1
    "$IPOKE" "$IMG" nlink "$OWNER" 0 >/dev/null 2>&1
    [ "$("$IPOKE" "$IMG" xattrblk "$OWNER" 2>/dev/null)" = "$T" ] &&
        [ "$("$IPOKE" "$IMG" nsget "$OWNER" 2>/dev/null | cut -d' ' -f2)" = 0 ] ||
        { fail "setup($ctl): ino $OWNER is not a dead record naming block $T"; return; }
    pass "setup($ctl): block $T is f's; dead ino $OWNER still names it"

    ct_mount "$DEV" "$MNT"
    ct_param_set journal_owner_dead_ok "$ctl"
    MARK="$(dmesg_mark)"
    "$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1 # REGISTERED, last_seen=0: stale at once
    cp "$A" "$A.pay"
    JOURNAL_POKE_OWNER="$OWNER" "$JPOKE" "$IMG" "$PEER" 0 "$T" "$A.pay" --guard-current >/dev/null 2>&1
    got="" refused=""
    for i in $(seq 1 40); do
        [ "$(blk "$T")" = "$ASUM" ] && got=1
        D="$(dmesg_since "$MARK")"
        grep -q "target block $T is no longer a block of its owner (ino $OWNER" <<<"$D" && refused=1
        [ -n "$got" ] || [ -n "$refused" ] && break
        sleep 1
    done
    ct_param_set journal_owner_dead_ok 0
    if [ "$ctl" = 0 ]; then
        [ -n "$refused" ] && pass "1: the redo was refused: the dead record owns nothing" ||
            fail "1: no refusal for the dead owner's entry"
        [ -z "$got" ] && [ "$(blk "$T")" = "$BSUM" ] && pass "2: block $T still holds f's xattrs" ||
            fail "2: block $T was overwritten (got='$got')"
        echo 3 >/proc/sys/vm/drop_caches
        [ "$(xlen "$MNT/f" user.a)" = 200 ] && [ "$(xlen "$MNT/f" user.b)" = 4 ] &&
            pass "3: f's xattrs read back" || fail "3: f's xattrs do not read back"
    else
        [ -n "$got" ] && [ -z "$refused" ] &&
            pass "control: the old verdict redoes onto f's block (block $T holds A)" ||
            fail "control: journal_owner_dead_ok did not restore the redo (refused='$refused' got='$got')"
    fi
    ct_umount "$MNT"
}

run 0
run 1
ct_exit
