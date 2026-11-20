#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the superblock's region map is checked, not just its checksum
#
# Every region start in the superblock is used directly as a WRITE
# target: an inode record is a blind full-block write at
# inode_table_start + (ino - 1), a ZG claim is a compare-and-swap at
# zg_table_start + zg_id, a registry row at node_table_start + idx.
# Nothing downstream re-derives any of them. So a superblock saying
# inode_table_start = 1 makes every file creation overwrite a Zone Group
# record, and 0 makes it overwrite the superblock.
#
# The CRC does not catch that. It proves the bytes are the bytes that
# were written -- nothing about whether the map they describe is sane.
# This project already drew that line for journal entries (fsck and
# journal.c both bounds-check a target because a correctly-checksummed
# entry naming block 0 destroys the superblock when replay applies it);
# the superblock's own map had no equivalent check.
#
# Each case below pokes ONE field, re-checksums so the superblock is
# structurally valid, and requires the mount to be refused -- then puts
# the field back and requires the mount to succeed again. That second
# half is the control: without it a refusal could be left over from the
# previous case rather than caused by this field.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SB_POKE="$(ct_helper sb_poke)"

IMG="$(ct_image 1200 sbval)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt sbval)"
ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

sb_field() { "$SB_POKE" "$DEV" | sed -n "s/^$1=//p"; }

if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    pass "baseline: an untouched volume mounts"
else
    fail "baseline: an untouched volume does not mount -- every case below would be meaningless"
    ct_exit
fi

# check <field> <bad value> <what it would do>
check() {
    local field="$1" bad="$2" why="$3" orig
    orig="$(sb_field "$field")"
    "$SB_POKE" "$DEV" "$field" "$bad" >/dev/null
    blockdev --flushbufs "$DEV"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
        fail "$field=$bad was accepted ($why)"
    else
        pass "$field=$bad is refused ($why)"
    fi
    "$SB_POKE" "$DEV" "$field" "$orig" >/dev/null
    blockdev --flushbufs "$DEV"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
    else
        fail "control: restoring $field=$orig did not make the volume mountable again -- the refusal above may have been for another reason"
    fi
}

log "a region that overlaps another, or sits on the superblock, is refused"
check inode_table_start 1 "the inode table would sit on the Zone Group table: every create overwrites a ZG record"
check inode_table_start 0 "the inode table would sit on the superblock"
check inode_bmap_start 6 "the inode bitmap would overlap the inode table"
check pending_free_start 6 "the pending-free queues would overlap the inode table"
check node_table_start 1 "the Node Registry would sit on the Zone Group table"
check zg_table_start 0 "the Zone Group table would sit on the superblock"
check pending_free_blocks_per_zg 0 "every cross-node free would have nowhere to go, and leak (fsck refuses it too)"

log "a region that runs off the end of the device is refused"
check bg_regions_start 300000 "the Block Group data regions would extend past total_blocks"
check inode_table_blocks 400000 "the inode table would extend past total_blocks"

# The version gate is a RANGE, CETRAFS_VERSION_MIN..CETRAFS_VERSION, and
# a range is easier to get wrong than an equality: an off-by-one at
# either end silently admits a layout this build does not understand, or
# locks out one it does. So both ends are poked and everything inside is
# required to still mount.
#
# The bounds are READ FROM THE HEADER rather than written out. They were
# 8 and 9 until the compatibility window closed in 0.9.2 and the range
# collapsed to a single value; a suite that spells them out does not
# fail when the window moves, it fails when someone changes the window
# -- which is backwards, and cost a red gate to notice.
# CETRAFS_VERSION_MIN may itself be the token CETRAFS_VERSION, which is
# what a closed window looks like in the source.
hdrdef() { sed -n "s/^#define $1  *//p" "$ROOT/include/cetrafs.h" | head -1 | awk '{print $1}'; }
# Shell arithmetic, not awk's strtonum() (gawk-only; mawk aborted here).
FMT_CUR="$(($(hdrdef CETRAFS_VERSION)))"
FMT_MINTOK="$(hdrdef CETRAFS_VERSION_MIN)"
[ "$FMT_MINTOK" = "CETRAFS_VERSION" ] && FMT_MINTOK="$(hdrdef CETRAFS_VERSION)"
FMT_MIN="$((FMT_MINTOK))"
[ "${FMT_MIN:-0}" -gt 0 ] && [ "${FMT_CUR:-0}" -ge "$FMT_MIN" ] ||
    fail "could not resolve the supported format range from include/cetrafs.h (got '$FMT_MIN'..'$FMT_CUR')"

log "the format version gate accepts exactly its supported range ($FMT_MIN..$FMT_CUR)"
check version "$((FMT_MIN - 1))" "a format version older than this build supports"
check version "$((FMT_CUR + 1))" "a format version newer than this build knows"
check version 65535 "a nonsense format version"

for v in $(seq "$FMT_MIN" "$FMT_CUR"); do
    "$SB_POKE" "$DEV" version "$v" >/dev/null
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
        pass "format version $v is accepted"
    else
        fail "format version $v was refused, but this build is supposed to accept it"
    fi
done
"$SB_POKE" "$DEV" version "$FMT_CUR" >/dev/null

log "counts must fit the regions that hold them"
check inodes_count 999999 "more inodes than the bitmap has bits or the table has blocks"
check inodes_count 0 "an inode table nothing can be allocated from"
check node_table_count 0 "a Node Registry no node can register in"
check sb_bytes 439 "a superblock of a size this build does not agree with"
check node_entry_size 4 "a registry row smaller than the struct written into it"
check data_align_blocks 0 "no data alignment at all, which every group's layout is computed from"
check data_align_blocks 3 "a data alignment that is not a power of two"
check data_align_blocks 1048576 "a data alignment past the 64 MiB maximum"

# Size fields bound kernel loops and allocations, and fsck refuses past
# what mkfs writes; the mount only checked them against the device
# (audit BM-18). Each value below also overlaps a neighbour, which the
# old code refused for -- so the REASON is what is asserted.
log "a size field past what mkfs writes is refused for its size"
# <field> <bad> <message the refusal must carry>
check_why() {
    local field="$1" bad="$2" msg="$3" orig mark
    orig="$(sb_field "$field")"
    "$SB_POKE" "$DEV" "$field" "$bad" >/dev/null
    blockdev --flushbufs "$DEV"
    mark="$(dmesg_mark)"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
        fail "$field=$bad was accepted"
    elif dmesg_since "$mark" | grep -q "$msg"; then
        pass "$field=$bad is refused for its size"
    else
        fail "$field=$bad was refused, but not for its size: $(dmesg_since "$mark" | grep -i superblock | tail -1)"
    fi
    "$SB_POKE" "$DEV" "$field" "$orig" >/dev/null
    blockdev --flushbufs "$DEV"
}
check_why pending_free_blocks_per_zg 513 "mkfs writes at most 512"
check_why inode_bmap_blocks 2 "inodes need exactly 1"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    pass "control: both restored, the volume mounts"
else
    fail "control: the volume does not mount with both fields restored"
fi

# A journal under 8 slots: an inode's held-back tree blocks are written at
# half the journal, and a batch larger than the journal is refused -- one
# slot failed every fsync needing two blocks, for the volume's life
# (audit M-24). 0 (no journal) and 17+ are legal; the baseline is -J 1.
log "a journal too small to hold one batch is refused, by the mount, fsck and growfs"
check node_journal_blocks 3 "one slot: every boundary needing two tree blocks fails EIO"
check node_journal_blocks 16 "seven slots, one under the minimum a batch is sized for"
JB_ORIG="$(sb_field node_journal_blocks)"
for bad in 3 16; do
    "$SB_POKE" "$DEV" node_journal_blocks "$bad" >/dev/null
    out="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" && rc=0 || rc=$?
    [ "$rc" -ne 0 ] && grep -q "per-node journal of $bad blocks" <<<"$out" &&
        pass "fsck refuses node_journal_blocks=$bad" || fail "fsck on node_journal_blocks=$bad: rc=$rc: $(tail -1 <<<"$out")"
    out="$("$ROOT/userspace/growfs.cetra" "$DEV" 2>&1)" && rc=0 || rc=$?
    [ "$rc" -ne 0 ] && grep -q "invalid node_journal_blocks $bad" <<<"$out" &&
        pass "growfs refuses node_journal_blocks=$bad" || fail "growfs on node_journal_blocks=$bad: rc=$rc: $(tail -1 <<<"$out")"
done
"$SB_POKE" "$DEV" node_journal_blocks "$JB_ORIG" >/dev/null
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 && pass "control: restored, fsck is clean again" ||
    fail "control: fsck still fails with node_journal_blocks=$JB_ORIG restored"

log "a cluster larger than the read-presence mask is refused"
# Row indices are taken modulo 64 in cetrafs_inode_t.read_open_nodes, so
# on a 128-row volume node 64 aliases node 0: node 64's read-open looks
# to node 0 like its own, is ignored, and the file is unlinked while it
# is being read -- the read-presence hole, silently reopened. mkfs refuses
# -M above 64; the kernel is what the mask protects and trusted it.
check node_table_count 128 "row indices would alias in the 64-bit read-presence mask"

log "an unknown RO_COMPAT feature is read-only, not refused outright"
ORIG_RO="$(sb_field features_ro_compat)"
"$SB_POKE" "$DEV" features_ro_compat 2 >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "a volume with an unimplemented RO_COMPAT feature mounted read-WRITE"
else
    pass "a volume with an unimplemented RO_COMPAT feature is refused read-write"
fi
if mount -t cetrafs -o ro "$DEV" "$MNT" 2>/dev/null; then
    pass "...and still mounts read-only, which is what RO_COMPAT means"
    umount "$MNT"
else
    fail "a volume with an unimplemented RO_COMPAT feature could not be mounted read-only either"
fi
"$SB_POKE" "$DEV" features_ro_compat "$ORIG_RO" >/dev/null
blockdev --flushbufs "$DEV"

log "an unknown INCOMPAT feature is refused, read-only included"
ORIG_IN="$(sb_field features_incompat)"
"$SB_POKE" "$DEV" features_incompat $((ORIG_IN | (1 << 40))) >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs -o ro "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "a volume with an unknown INCOMPAT feature mounted (read-only)"
else
    pass "a volume with an unknown INCOMPAT feature is refused, even read-only"
fi
# The CAS-stamp bit (G-6): mkfs sets it, and a volume without it -- made
# by a build whose writers never moved the stamps -- is refused, since a
# stamp means something only if every writer moves it.
[ $((ORIG_IN & (1 << 4))) != 0 ] && pass "mkfs sets the CAS-stamp feature (G-6)" ||
    fail "mkfs did not set the CAS-stamp feature (features_incompat=$ORIG_IN)"
"$SB_POKE" "$DEV" features_incompat $((ORIG_IN & ~(1 << 4))) >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "a volume without the CAS-stamp feature mounted"
else
    pass "a volume without the CAS-stamp feature (G-6) is refused"
fi
"$SB_POKE" "$DEV" features_incompat "$ORIG_IN" >/dev/null
blockdev --flushbufs "$DEV"
# The reserved Zone Group chain bit (A-13): set by a build that appends
# Zone Group segments, which this one cannot follow.
"$SB_POKE" "$DEV" features_incompat $((ORIG_IN | (1 << 5))) >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    umount "$MNT"
    fail "a volume with the reserved Zone Group chain feature mounted"
else
    pass "a volume with the reserved Zone Group chain feature (A-13) is refused"
fi
"$SB_POKE" "$DEV" features_incompat "$ORIG_IN" >/dev/null
blockdev --flushbufs "$DEV"

# COMPAT: the mount ignores it; a grow may not (cetrafs.h, the feature
# rules) -- growfs refuses first, so the kernel's own refusal is asked
# directly (grow_claim_probe: refused here with EOPNOTSUPP, before the
# claim check that otherwise answers EBUSY).
log "an unknown COMPAT feature mounts read-write; a live grow refuses it"
PROBE="$(ct_helper grow_claim_probe)"
NONCE=00000000000000000000000000000000
ORIG_C="$(sb_field features_compat)"
"$SB_POKE" "$DEV" features_compat $((ORIG_C | (1 << 40))) >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    pass "a volume with an unknown COMPAT feature mounts read-write"
    out="$("$PROBE" "$MNT" "$DEV" 0 "$NONCE" 2>&1 || true)"
    grep -q "errno=$(python3 -c 'import errno; print(errno.EOPNOTSUPP)')" <<<"$out" &&
        pass "...and the kernel refuses to grow it ($out)" || fail "the kernel grow did not refuse an unknown COMPAT bit: $out"
    umount "$MNT"
else
    fail "a volume with an unknown COMPAT feature was refused"
fi
"$SB_POKE" "$DEV" features_compat "$ORIG_C" >/dev/null
blockdev --flushbufs "$DEV"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    out="$("$PROBE" "$MNT" "$DEV" 0 "$NONCE" 2>&1 || true)"
    umount "$MNT"
    ! grep -q "errno=$(python3 -c 'import errno; print(errno.EOPNOTSUPP)')" <<<"$out" &&
        pass "control: with the bit cleared the grow gets past the feature check ($out)" ||
        fail "control: EOPNOTSUPP with no unknown bit -- the refusal is not the feature check: $out"
else
    fail "control: the volume did not mount with the bit cleared"
fi

# ------------------------------------------------- no false positives
#
# The expensive failure mode of a layout check is the opposite one: a
# geometry mkfs really produces being declared invalid, making a healthy
# volume unmountable. Every shape the auto-tuning can pick is tried.
log "every geometry mkfs can produce still mounts"
geom_ok() {
    local desc="$1"
    shift
    local gimg gdev gmnt
    gimg="$(ct_image 1200 geom)"
    gdev="$(ct_loop "$gimg")"
    gmnt="$(ct_mnt geom)"
    if ! ct_mkfs "$gdev" "$@" -f >/dev/null 2>&1; then
        fail "geometry $desc: mkfs failed"
        return
    fi
    if mount -t cetrafs "$gdev" "$gmnt" 2>/dev/null; then
        umount "$gmnt"
        pass "geometry $desc mounts"
    else
        fail "geometry $desc was rejected by the layout check -- false positive on a volume mkfs really produces"
    fi
    losetup -d "$gdev" 2>/dev/null || true
}
geom_ok "defaults"            # auto-tuned -z/-b/-J/-N
geom_ok "no journal" -z 1 -b 512 -J 0 -N 1024
geom_ok "max nodes" -z 1 -b 512 -J 1 -M 64 -N 1024
geom_ok "many ZGs" -z 2 -b 512 -J 2 -M 8 -N 4096
geom_ok "one node" -z 1 -b 512 -J 4 -M 1 -N 1024

ct_exit
