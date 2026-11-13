#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow leaves a dead node's unreplayed journal alone, and the replay after it still applies the entry
#
# A node can die with a journal entry it never got to replay. The next
# mount's heartbeat replays that entry, and replay reads the journal and
# the target through the layout. A grow changes the layout and nothing
# else -- the journal slices and the target block stay where they are --
# so a grow between the death and the replay must not lose the entry,
# re-address it, or let the replay judge its target against a stale copy.
#
# Staged on one node. A file's first block is the target. Node 1 is
# planted as a registered row that went quiet at once (node_poke), and
# its journal holds one valid entry (journal_poke, guard current) with a
# payload that differs from the block. The volume is then grown offline
# -- which must succeed with the dead row present -- and mounted. Asserts:
#   - the grow leaves node 1's journal flag exactly as it was;
#   - the replay applies the entry, so the target block reads back as the
#     payload (the sha256 of the device block, read after the unmount);
#   - fsck is clean afterwards.
#
# DISCRIMINATION: CETRAFS_GROWFS_TEST_CLOBBER_JOURNAL zeroes every node's
# journal area during the grow. The control round then asserts the
# payload is NOT applied (the entry was lost), so a grow that damages the
# journal is visibly caught.
#
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
PFPOKE="$(ct_helper pending_poke)"
DEV="$(ct_big_dev 1200 gdj)"
MNT="$(ct_mnt gdj)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
# The target is a file's DATA block, which no writer journals (only dirent,
# xattr and extent-leaf blocks are), so the owner check (L9) would refuse
# the entry before the path under test is reached. Switched off to isolate
# that path, as journal_replay_owner.sh and grow_live_replay.sh do.
[ -w /sys/module/cetrafs/parameters/journal_ignore_owner ] || { skip "journal_ignore_owner is missing"; ct_exit; }
ct_param_set journal_ignore_owner 1

PEER=1
PAY="$(ct_tmp gdj-pay)"
head -c 4096 /dev/urandom >"$PAY"
WANT="$(sha256sum <"$PAY" | cut -d' ' -f1)"

blk() { dd if="$DEV" bs=4096 skip="$1" count=1 status=none | sha256sum | cut -d' ' -f1; }

# round <tag> [VAR=value ...]
# Sets R_APPLIED (the target reads back as the payload) and R_JSAME (the
# grow left the journal flag alone). Returns 1 when the setup did not
# arrange the situation.
round() {
    local tag="$1" ino target jdump_pre jdump_post
    shift
    ct_mkfs "$DEV" -s 600M -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=2 conv=fsync status=none
    ino="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    target="$("$PFPOKE" "$DEV" extent "$ino" 2>/dev/null | cut -d' ' -f1)"
    if [ -z "$target" ] || [ "$target" -le 0 ]; then
        fail "$tag: setup: no data block for the target file ($target)"
        return 1
    fi
    if [ "$(blk "$target")" = "$WANT" ]; then
        fail "$tag: setup: the target already holds the payload"
        return 1
    fi
    "$NODEPOKE" "$DEV" "$PEER" 1 ee 0 >/dev/null 2>&1 # REGISTERED, last_seen 0: quiet from the start
    "$JPOKE" "$DEV" "$PEER" 0 "$target" "$PAY" >/dev/null 2>&1
    jdump_pre="$("$JPOKE" "$DEV" "$PEER" --dump 2>/dev/null || true)"
    case "$jdump_pre" in
    *state=0*) fail "$tag: setup: node $PEER's journal is not dirty -- there is nothing to replay"; return 1 ;;
    "") fail "$tag: setup: cannot read node $PEER's journal flag"; return 1 ;;
    esac

    if ! env "$@" "$ROOT/userspace/growfs.cetra" "$DEV" -s 1200M >/dev/null 2>&1; then
        fail "$tag: growfs refused to grow the volume with a dead node's journal to replay"
        return 1
    fi
    jdump_post="$("$JPOKE" "$DEV" "$PEER" --dump 2>/dev/null || true)"
    R_JSAME=0
    [ "$jdump_pre" = "$jdump_post" ] && R_JSAME=1

    # The replay runs from the heartbeat once the dead row has been
    # watched for the stale window. Wait for it, then unmount so the
    # device holds what the node wrote.
    mount -t cetrafs "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    R_APPLIED=0
    for _ in $(seq 1 60); do
        if [ "$(blk "$target")" = "$WANT" ]; then
            R_APPLIED=1
            break
        fi
        sleep 1
    done
    ct_umount "$MNT"
    R_APPLIED_AFTER_UMOUNT=0
    [ "$(blk "$target")" = "$WANT" ] && R_APPLIED_AFTER_UMOUNT=1
    return 0
}

# ---- the real case: the grow leaves the entry, the replay applies it
round grown || ct_exit
if [ "$R_JSAME" = 1 ]; then
    pass "the grow left node $PEER's journal flag exactly as it was"
else
    fail "the grow changed node $PEER's journal flag"
fi
if [ "$R_APPLIED_AFTER_UMOUNT" = 1 ]; then
    pass "the replay applied the dead node's entry: the target block holds the payload after the grow"
else
    fail "the dead node's entry was not applied after the grow (the target block does not hold the payload)"
fi
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null && pass "fsck is clean after the grow and the replay" ||
    fail "fsck reports damage after the grow and the replay"

# ---- the negative control: a grow that clobbers the journal loses the entry
round clobbered CETRAFS_GROWFS_TEST_CLOBBER_JOURNAL=1 || ct_exit
if [ "$R_APPLIED_AFTER_UMOUNT" = 0 ]; then
    pass "control: a grow that zeroes the journals loses the entry, and the check sees it"
else
    fail "control: the payload was applied even though the journals were zeroed by the grow -- the check does not discriminate"
fi

ct_exit
