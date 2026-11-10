#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay redoes a block only while it is still its owner's, and announces the redo with the owner's change stamp
#
# The replay guard proves a target holds the BYTES its entry was written
# against. A block freed and reallocated since can hold those very bytes
# -- an empty dirent block looks like any other -- and the redo then
# lands on a stranger's block. And a redo changes bytes no stamp
# announced, so a node that had cached the block before its writer died
# went on trusting the old copy (L9). Every entry now names its owner,
# the inode whose metadata the target is (format 0x000A), and replay:
#
#  1. refuses a target its named owner does not reference -- the shape
#     of a block freed and reallocated with matching bytes;
#  2. refuses an owner whose number now carries another generation;
#  3. control: the right owner is redone, and its change stamp
#     (dirent_seq, for a directory) moves;
#  4. control: with journal_ignore_owner the first entry IS applied --
#     the refusal in 1 is the owner check and nothing else.
#
# Staged single-node as journal_replay_guard.sh stages its cases: two
# states of the root's dirent block, an entry carrying the older one
# over the newer, its guard taken from the target as it reads.
#
# DISCRIMINATION: with no owner check, 1 and 2 apply the entry (the root
# goes back to the older state); with no stamp advance, 3's dirent_seq
# does not move (checked 2026-11-10).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_ignore_owner ] || { skip "journal_ignore_owner is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 jowner)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jowner)"
BLK_A="$(ct_tmp jowner-a)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

lsroot() { ls "$MNT" | sort | tr '\n' ' '; }
dseq() { "$LPOKE" "$IMG" "$ROOT_INO" --rec | sed -n 's/.* dirent_seq=\([0-9]*\) .*/\1/p'; }

mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
ROOT_INO="$(stat -c %i "$MNT")"
echo data >"$MNT/f"
F_INO="$(stat -c %i "$MNT/f")"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
TARGET_LBA="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
ct_umount "$MNT"
[ -n "$TARGET_LBA" ] || { fail "setup: the create journaled no dirent block"; ct_exit; }
dd if="$IMG" of="$BLK_A" bs=4096 skip="$TARGET_LBA" count=1 status=none # state A: f alpha
mount -t cetrafs "$DEV" "$MNT"
touch "$MNT/beta"                                                       # state B: f alpha beta
ct_umount "$MNT"
OUT="$(JOURNAL_POKE_OWNER= "$JPOKE" "$IMG" "$NID" 0 "$TARGET_LBA" "$BLK_A" --guard-current 2>&1 | head -1)"
grep -q "owner=$ROOT_INO," <<<"$OUT" || { fail "setup: the poke does not name the root as the block's owner: $OUT"; ct_exit; }

# replay_case <log> [env...]: plant the older image under <env>, mount, report the root
replay_case() {
    local what="$1"; shift
    env "$@" "$JPOKE" "$IMG" "$NID" 0 "$TARGET_LBA" "$BLK_A" --guard-current >/dev/null
    MARK="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT"
    LS="$(lsroot)"
    ct_umount "$MNT"
    log "$what: root is '$LS'"
}

# ------------------------------------------------------------------- 1
replay_case "1 (owner: a file that does not hold the block)" JOURNAL_POKE_OWNER="$F_INO"
[ "$LS" = "alpha beta f " ] && pass "1: the entry was not applied to a block its owner does not hold" ||
    fail "1: a block its named owner does not reference was redone: root is '$LS'"
dmesg_since "$MARK" | grep -q "is no longer a block of its owner (ino $F_INO" && pass "1: and the refusal names the owner" ||
    fail "1: no owner refusal in dmesg"

# ------------------------------------------------------------------- 2
replay_case "2 (owner: the root, another generation)" JOURNAL_POKE_OWNER="$ROOT_INO" JOURNAL_POKE_OWNER_GEN=12345
[ "$LS" = "alpha beta f " ] && pass "2: an owner of another generation is refused" ||
    fail "2: an entry naming a reused inode number was redone: root is '$LS'"

# ------------------------------------------------------------------- 3
S0="$(dseq)"
replay_case "3 (control: the right owner)" JOURNAL_POKE_OWNER=
[ "$LS" = "alpha f " ] && pass "3: control: the root's own entry is redone" ||
    fail "setup: the entry naming the right owner was not applied ('$LS') -- 1 and 2 prove nothing"
S1="$(dseq)"
[ -n "$S0" ] && [ "$S1" != "$S0" ] && pass "3: and the root's dirent_seq moved ($S0 -> $S1)" ||
    fail "3: the redo left the root's dirent_seq at '$S1' (was '$S0') -- a peer's cached copy stays trusted"

# ------------------------------------------------------------------- 4
mount -t cetrafs "$DEV" "$MNT"; touch "$MNT/beta"; ct_umount "$MNT" # back to state B
ct_param_set journal_ignore_owner 1
replay_case "4 (control: case 1 with the owner check off)" JOURNAL_POKE_OWNER="$F_INO"
ct_param_set journal_ignore_owner 0
[ "$LS" = "alpha f " ] && pass "4: control: without the owner check case 1's entry is applied" ||
    fail "4: control: even unchecked the entry was not applied ('$LS') -- 1 proves nothing"
ct_exit
