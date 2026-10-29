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

log "a region that runs off the end of the device is refused"
check bg_regions_start 300000 "the Block Group data regions would extend past total_blocks"
check inode_table_blocks 400000 "the inode table would extend past total_blocks"

# The version gate became a RANGE when 0x0009 was introduced so that
# volumes from the previous release stay mountable and growable without
# a reformat (cetrafs.h). A range is easier to get wrong than an
# equality -- an off-by-one at either end silently admits a layout this
# build does not understand, or locks out one it does -- so both ends
# are poked, and the accepted values are required to still mount.
log "the format version gate accepts exactly its supported range"
check version 7 "a format version older than this build supports"
check version 10 "a format version newer than this build knows"
check version 65535 "a nonsense format version"

for v in 8 9; do
    "$SB_POKE" "$DEV" version "$v" >/dev/null
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        umount "$MNT"
        pass "format version $v is accepted"
    else
        fail "format version $v was refused, but this build is supposed to accept it"
    fi
done
"$SB_POKE" "$DEV" version 9 >/dev/null

log "counts must fit the regions that hold them"
check inodes_count 999999 "more inodes than the bitmap has bits or the table has blocks"
check inodes_count 0 "an inode table nothing can be allocated from"
check node_table_count 0 "a Node Registry no node can register in"
check sb_bytes 439 "a superblock of a size this build does not agree with"
check node_entry_size 4 "a registry row smaller than the struct written into it"

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
