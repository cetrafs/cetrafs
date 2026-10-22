#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay verifies before it redoes: an entry whose target somebody else
# has rewritten must NOT be applied.
#
# Journal redo used to be unconditional, justified by "a surviving entry
# means its writer crashed while holding that operation's lock, so nobody
# else can have touched the target". Under `nofilelock` extent leaves
# have no such lock, and the claim is false: a node dies mid-write, a
# peer legitimately rewrites the same leaf, and the periodic replay then
# blind-copies the dead node's image over it. The result is a valid,
# CRC-correct, WRONG extent map -- invisible to fsck, visible only as a
# corrupted guest disk. Found: after an HA failover moved a VM.
#
# The fix is cetrafs_journal_header_t.prev_checksum: replay applies an
# entry only while the target still holds the image it was written
# against. Three outcomes are asserted here -- applied, refused, skipped
# -- plus a negative control proving the assertions can fail.
#
# The cross-node original is ctest's journal-replay-guard scenario; this
# reconstructs each decision single-node with journal_poke, so the guard
# is covered by `make check` and not only by a two-machine run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"

# Everything here is allocated through the harness so the single
# ct_cleanup EXIT trap unwinds it. A suite that installs its own trap
# REPLACES that one and leaks its loop device into the next suite --
# suite_invariants.sh fails the run for it, correctly.
IMG="$(ct_image 560 jguard)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jguard)"
PD="$(basename "$DEV")"
BLK_A="$(ct_tmp jguard-a)"

ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

# The replay counters are module-GLOBAL and every suite in a run shares
# one module load, so each assertion below is a DELTA against the value
# this suite last saw -- never an absolute. (scrub_orphan_inode.sh was
# bitten by exactly this.) They can only be read while something is
# mounted, so each case samples them before unmounting.
ctr() { sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }
APP=0; REF=0; SKIP=0
sample() { APP="$(ctr journal_replay_applied)"; REF="$(ctr journal_replay_refused)"
           SKIP="$(ctr journal_replay_skipped)"; }

log "building two successive states of one dirent block"
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
TARGET_LBA="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
[ -n "$TARGET_LBA" ] && pass "guard: creating a file journaled a dirent block (lba=$TARGET_LBA)" ||
    fail "guard: no journal entry logged for a file create"
sample
ct_umount "$MNT"
# State A -- root holding 'alpha' alone. This is the image a dead node's
# surviving entry carries: the OLDER one.
dd if="$DEV" of="$BLK_A" bs=4096 skip="$TARGET_LBA" count=1 status=none
mount -t cetrafs "$DEV" "$MNT"
touch "$MNT/beta"      # state B -- the surviving node's NEWER write
ct_umount "$MNT"

# --------------------------------------------------------------- case 1
log "an entry whose target is untouched is still APPLIED (redo must keep working)"
# prev_checksum taken from the target as it reads right now, which is the
# honest "my write never landed" state.
"$JPOKE" "$DEV" 0 0 "$TARGET_LBA" "$BLK_A" --guard-current >/dev/null
mount -t cetrafs "$DEV" "$MNT"
LS="$(ls "$MNT" | sort | tr '\n' ' ')"; A_PREV=$APP; sample
ct_umount "$MNT"
[ "$LS" = "alpha " ] && pass "guard: a verified entry WAS applied (root back to state A: $LS)" ||
    fail "guard: a verified entry was not applied (expected 'alpha ', got '$LS')"
[ "$APP" -gt "$A_PREV" ] && pass "guard: journal_replay_applied moved ($A_PREV -> $APP)" ||
    fail "guard: journal_replay_applied did not move ($A_PREV -> $APP)"

# --------------------------------------------------------------- case 2
log "an entry whose target CHANGED under it is REFUSED"
mount -t cetrafs "$DEV" "$MNT"; touch "$MNT/beta"; sample; ct_umount "$MNT"   # back to state B
"$JPOKE" "$DEV" 0 0 "$TARGET_LBA" "$BLK_A" --guard-stale >/dev/null
MARK2="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT"
LS="$(ls "$MNT" | sort | tr '\n' ' ')"; R_PREV=$REF; sample
ct_umount "$MNT"
[ "$LS" = "alpha beta " ] && pass "guard: the peer's newer write SURVIVED the replay ($LS)" ||
    fail "guard: replay clobbered the newer write (expected 'alpha beta ', got '$LS')"
dmesg_since "$MARK2" | grep -q "NOT applying it" &&
    pass "guard: the refusal is logged loudly, naming the block" ||
    fail "guard: nothing in dmesg reports the refusal"
[ "$REF" -gt "$R_PREV" ] && pass "guard: journal_replay_refused counts it ($R_PREV -> $REF)" ||
    fail "guard: journal_replay_refused did not move ($R_PREV -> $REF)"

# --------------------------------------------------------------- case 3
log "an entry for a freshly-allocated block is SKIPPED, never applied"
"$JPOKE" "$DEV" 0 0 "$TARGET_LBA" "$BLK_A" --fresh >/dev/null
mount -t cetrafs "$DEV" "$MNT"
LS="$(ls "$MNT" | sort | tr '\n' ' ')"; S_PREV=$SKIP; sample
ct_umount "$MNT"
[ "$LS" = "alpha beta " ] && pass "guard: an F_FRESH entry left the block alone ($LS)" ||
    fail "guard: an F_FRESH entry was applied (expected 'alpha beta ', got '$LS')"
[ "$SKIP" -gt "$S_PREV" ] && pass "guard: journal_replay_skipped counts it ($S_PREV -> $SKIP)" ||
    fail "guard: journal_replay_skipped did not move ($S_PREV -> $SKIP)"

# ----------------------------------------------------- negative control
# Without this, all of the above would pass just as well against code
# that never replays anything at all. journal_ignore_guard restores the
# pre-fix behaviour; case 2 must then CORRUPT.
log "negative control: with the guard disabled, case 2 must corrupt"
ct_param_set journal_ignore_guard 1
"$JPOKE" "$DEV" 0 0 "$TARGET_LBA" "$BLK_A" --guard-stale >/dev/null
mount -t cetrafs "$DEV" "$MNT"
LS="$(ls "$MNT" | sort | tr '\n' ' ')"
ct_umount "$MNT"
ct_param_set journal_ignore_guard 0
[ "$LS" = "alpha " ] && pass "guard: negative control reproduced the bug (newer write lost: $LS)" ||
    fail "guard: negative control did NOT corrupt (got '$LS') -- the assertions above prove nothing"

ct_exit
