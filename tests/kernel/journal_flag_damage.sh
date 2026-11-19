#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a damaged journal flag block reads DIRTY, never CLEAN
#
# A node's journal flag block carries a magic and a state and no CRC.
# Replay, the heartbeat sweep and fsck read "DIRTY" only from state 1,
# so a damaged state read CLEAN: the replay a crash left owed was
# skipped, and attach then retired every live entry under it -- a torn
# block's repair erased, fsck silent (audit 2026-11-15 BL-40). A state
# no writer stamps now reads DIRTY: replay judges each entry against its
# target, so a needless replay redoes nothing. A magic that is neither
# zero nor ours is not a flag block: -EUCLEAN, and the mount refuses.
#
# Staged in this node's own area, offline: a valid, guard-matching entry
# for f's xattr block, carrying an older image of it (A over B), under
#   a. a flag with state 2: fsck reports it as ERR; the mount replays
#      the entry (the block holds the payload) and parks the flag CLEAN.
#   b. a flag with a garbage magic: fsck reports it; the mount is
#      refused and the entry stays; fsck --discard-journal parks it,
#      and the volume then mounts.
#
# DISCRIMINATION: journal_flag_damage_clean=1 restores the old verdict;
# a's control requires the entry retired unapplied (the block keeps its
# content, the slot is empty), b's that the mount succeeds and retires it.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_flag_damage_clean ] ||
    { skip "journal_flag_damage_clean is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
xset() { python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], b"x" * int(sys.argv[3]))' "$@"; }

ct_param_set scrub 0
ct_param_set journal_flag_damage_clean 0

# run <a|b> <control 0|1>
run() {
    local sc="$1" ctl="$2" tag="jfd$1$2"
    local IMG DEV MNT NID INO TARGET PAY WANT ORIG OUT MARK mounted=""
    IMG="$(ct_image 560 "$tag")"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt "$tag")"
    ct_track mnt "$MNT"
    blk() { dd if="$IMG" bs=4096 skip="$TARGET" count=1 status=none | sha256sum | cut -d' ' -f1; }
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
    echo data >"$MNT/f"
    xset "$MNT/f" user.a 200
    INO="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    TARGET="$("$IPOKE" "$IMG" xattrblk "$INO" 2>/dev/null)"
    [ -n "$TARGET" ] && [ "$TARGET" != 0 ] || { fail "setup($sc$ctl): f has no xattr block"; return; }
    PAY="$(ct_tmp "$tag-pay")"
    dd if="$IMG" of="$PAY" bs=4096 skip="$TARGET" count=1 status=none
    WANT="$(sha256sum <"$PAY" | cut -d' ' -f1)"
    ct_mount "$DEV" "$MNT"
    xset "$MNT/f" user.b 4
    sync
    ct_umount "$MNT"
    TARGET="$("$IPOKE" "$IMG" xattrblk "$INO" 2>/dev/null)" # B: rewritten elsewhere
    [ -n "$TARGET" ] && [ "$TARGET" != 0 ] || { fail "setup($sc$ctl): f lost its xattr block"; return; }
    ORIG="$(blk)"
    [ "$ORIG" != "$WANT" ] || { fail "setup($sc$ctl): the xattr block did not change"; return; }

    if [ "$sc" = a ]; then
        JOURNAL_POKE_STATE=2 "$JPOKE" "$IMG" "$NID" 3 "$TARGET" "$PAY" >/dev/null
        "$JPOKE" "$IMG" "$NID" --dump | grep -q "^state=2 " ||
            { fail "setup($sc$ctl): the flag does not read state 2: $("$JPOKE" "$IMG" "$NID" --dump)"; return; }
    else
        JOURNAL_POKE_FLAG_MAGIC=0x0badf1a6 "$JPOKE" "$IMG" "$NID" 3 "$TARGET" "$PAY" >/dev/null
    fi
    "$JPOKE" "$IMG" "$NID" --live | grep -q "^slot 3 target $TARGET\$" ||
        { fail "setup($sc$ctl): no live entry in slot 3"; return; }
    [ "$(blk)" = "$ORIG" ] || { fail "setup($sc$ctl): the block changed before any mount"; return; }
    pass "setup($sc$ctl): node $NID's area holds an entry for block $TARGET under a damaged flag"

    if [ "$ctl" = 0 ]; then
        OUT="$("$FSCK" "$DEV" 2>&1 || true)"
        if [ "$sc" = a ]; then
            grep -q "^ERR: node $NID journal flag block has state 2, neither CLEAN nor DIRTY" <<<"$OUT" &&
                pass "a: fsck reports the damaged state" ||
                fail "a: fsck is silent on state 2: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)"
        else
            grep -q "^ERR: node $NID journal flag block has bad magic" <<<"$OUT" &&
                pass "b: fsck reports the bad magic" ||
                fail "b: fsck is silent on the bad magic: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)"
        fi
    fi

    ct_param_set journal_flag_damage_clean "$ctl"
    MARK="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null && mounted=1
    ct_param_set journal_flag_damage_clean 0
    [ -n "$mounted" ] && umount "$MNT"
    blockdev --flushbufs "$DEV"

    if [ "$ctl" = 1 ]; then
        [ -n "$mounted" ] && [ "$(blk)" = "$ORIG" ] && ! "$JPOKE" "$IMG" "$NID" --live | grep -q "^slot 3 " &&
            pass "control $sc: the old verdict reads CLEAN and retires the entry unapplied" ||
            fail "control $sc: mounted='$mounted', block $([ "$(blk)" = "$WANT" ] && echo replayed || echo kept), entry $("$JPOKE" "$IMG" "$NID" --live | grep -c '^slot 3 ' || true)"
        return
    fi
    if [ "$sc" = a ]; then
        [ -n "$mounted" ] && pass "a: the volume mounts" || fail "a: the mount failed: $(dmesg_since "$MARK" | tail -3)"
        [ "$(blk)" = "$WANT" ] && pass "a: the entry was replayed (block $TARGET holds the payload)" ||
            fail "a: the entry was not replayed ($([ "$(blk)" = "$ORIG" ] && echo "block unchanged" || echo "block changed to something else"))"
        "$JPOKE" "$IMG" "$NID" --dump | grep -q "^state=0 " && pass "a: the replay parked the flag CLEAN" ||
            fail "a: the flag after the mount: $("$JPOKE" "$IMG" "$NID" --dump)"
        "$FSCK" "$DEV" 2>&1 | grep -q "journal flag block has state" &&
            fail "a: fsck still reports the flag after the replay" || pass "a: fsck no longer reports the flag"
    else
        [ -z "$mounted" ] && pass "b: the mount is refused" || fail "b: the volume mounted over a garbage flag block"
        dmesg_since "$MARK" | grep -q "has bad magic 0x0badf1a6 -- not a journal area" &&
            pass "b: the kernel names the bad flag block" || fail "b: no bad-magic message in dmesg"
        [ "$(blk)" = "$ORIG" ] && "$JPOKE" "$IMG" "$NID" --live | grep -q "^slot 3 target $TARGET\$" &&
            pass "b: the entry and its target are as they were" || fail "b: the refused mount changed the area or the block"
        "$FSCK" --discard-journal "$NID" "$DEV" >/dev/null 2>&1 || true
        "$JPOKE" "$IMG" "$NID" --dump | grep -q "^state=0 " && ! "$JPOKE" "$IMG" "$NID" --live | grep -q . &&
            pass "b: fsck --discard-journal parks it CLEAN with the entry dropped" ||
            fail "b: after --discard-journal: $("$JPOKE" "$IMG" "$NID" --dump)"
        ct_mount "$DEV" "$MNT" && pass "b: the volume mounts after the discard"
        ct_umount "$MNT"
    fi
}

run a 0
run a 1
run b 0
run b 1
ct_exit
