#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The background scrub reclaims ORPHAN INODES -- allocated, nlink=0, in use
# by nobody -- and spares one a peer still has open.
#
# The orphan is the designed residue of a cross-node delete: eviction
# refuses to free an inode a peer holds open (its read-presence bit), and
# the peer's own eviction cannot know the file died under it, so the number
# stays allocated with nothing left to free it. Planted here directly with
# orphan_poke (bitmap bit + nlink=0 record, no dirent), exactly that end
# state.
#
# Discriminators:
#   - with the scrub DISABLED the orphan stays (negative control: nothing
#     else reclaims it, so a green run proves the scrub did it);
#   - a second planted inode with a nonzero read_open_nodes mask must be
#     SPARED (a peer is still reading the dead file);
#   - fsck reports the orphan as a WARN, not a corruption ERR (exit 0).
#
# NOTE every fsck check below captures output FIRST -- `ct_fsck | grep -q`
# under pipefail is the harness's documented trap (grep -q's early exit
# SIGPIPEs fsck and fails the pipeline despite the match).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

POKE="$(ct_helper orphan_poke)"
ORPHAN=30          # reclaimable: nlink=0, nobody uses it
HELD=31            # spared: nlink=0 but a peer's read-presence bit is set

IMG="$(mktemp /tmp/cetrafs-orphino-XXXXXX.img)"
truncate -s 560M "$IMG"
DEV="$(losetup --find --show "$IMG")"
MNT="$(mktemp -d /tmp/cetrafs-orphino-mnt-XXXXXX)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" >/dev/null

orphans_reclaimed() { sed -n 's/^scrub_orphan_inodes_reclaimed: //p' "/proc/fs/cetrafs/$PROC_DEV/info"; }

log "plant orphan ino=$ORPHAN (nlink=0, unused) and held ino=$HELD (nlink=0, a peer reads it)"
"$POKE" "$DEV" "$ORPHAN" 0 0 >/dev/null
"$POKE" "$DEV" "$HELD" 0 0x4 >/dev/null

FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
echo "$FSCK_OUT" | grep -q "inode $ORPHAN is allocated" \
    && pass "setup: fsck sees the orphan" || fail "setup: fsck missed the planted orphan"
[ "$FSCK_RC" = 0 ] \
    && pass "an orphan inode is a WARN, not a corruption fsck fails on" \
    || fail "fsck exited $FSCK_RC on a volume whose only fault is the designed orphan residue"

log "negative control: with the scrub disabled the orphan must SURVIVE"
ct_param_set scrub 0
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
sleep 3
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "inode $ORPHAN is allocated" \
    && pass "negative control: nothing but the scrub reclaims an orphan" \
    || fail "the orphan vanished with the scrub disabled -- this test proves nothing"

log "enable a fast scrub; one cycle must reclaim ino=$ORPHAN and spare ino=$HELD"
ct_param_set scrub 1
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
# DELTA, not absolute: the counter is module-global and suites in one
# run share the module load, so an earlier suite's reclaims (e.g.
# high_inode_count.sh's two planted orphans) survive into this one. The
# absolute check passed standalone and failed only in the full matrix
# -- counter residue satisfied the wait before this
# suite's scrub ever ran.
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# (read right after mount: procfs needs the mount, and the first scrub
# cycle cannot fire before scrub_interval_secs from now)
BASE="$(orphans_reclaimed)"
for i in $(seq 1 30); do
    [ "$(($(orphans_reclaimed) - BASE))" -ge 1 ] 2>/dev/null && break
    sleep 1
done
REC="$(($(orphans_reclaimed) - BASE))"
[ "$REC" = 1 ] \
    && pass "the scrub reclaimed exactly one orphan inode (delta=$REC)" \
    || fail "scrub_orphan_inodes_reclaimed delta=$REC, expected 1 (0 = missed the orphan, >1 = over-freed)"
ct_umount "$MNT"

FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "inode $ORPHAN is allocated" \
    && fail "fsck still sees the orphan the scrub claims to have reclaimed" \
    || pass "the orphan inode is gone (ino=$ORPHAN freed)"
echo "$FSCK_OUT" | grep -q "inode $HELD is allocated" \
    && pass "the scrub SPARED the inode a peer still reads (ino=$HELD)" \
    || fail "the scrub freed an inode whose read-presence bit says a peer is using it"

losetup -d "$DEV"
rmdir "$MNT"
rm -f "$IMG"

ct_exit
