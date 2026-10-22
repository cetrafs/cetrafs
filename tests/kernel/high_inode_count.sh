#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A volume formatted with -N far above the 65536 default cap works end to
# end: mkfs/fsck geometry, allocation, and -- the actual risk -- the paths
# indexed by HIGH inode numbers, which cross into the inode bitmap's
# second and later blocks (65536 bits per 4 KiB block) and into table
# offsets no default-cap volume ever reaches.
#
# Creating >65536 real files on a loop device would take minutes for no
# extra coverage; instead a high-numbered inode is PLANTED (orphan_poke:
# bitmap bit + record) exactly where the second bitmap block begins, and
# the machinery that must handle it -- fsck's walk, the kernel's scrub
# reclaim, the allocator's bitmap scan -- is exercised against it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

POKE="$(ct_helper orphan_poke)"
N_INODES=131072          # 2 bitmap blocks, 512 MiB of inode table
HIGH=70000               # past the default cap AND past bitmap block 0
HIGHER=131070            # near the very end of the table

IMG="$(mktemp /tmp/cetrafs-highn-XXXXXX.img)"
truncate -s 2200M "$IMG"
DEV="$(losetup --find --show "$IMG")"
MNT="$(mktemp -d /tmp/cetrafs-highn-mnt-XXXXXX)"
PROC_DEV="$(basename "$DEV")"

log "mkfs -N $N_INODES (inode table alone is 512 MiB)"
ct_mkfs "$DEV" -N "$N_INODES" -z 1 -J 0 -f >/dev/null
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck accepts the high-N geometry" ||
    fail "fsck rejects a freshly made -N $N_INODES volume: $(echo "$FSCK_OUT" | tail -2)"
echo "$FSCK_OUT" | grep -q "inodes" && : # informational

log "normal life on the high-N volume"
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for i in $(seq 1 50); do echo "x$i" > "$MNT/f$i"; done
mkdir "$MNT/d"; ln "$MNT/f1" "$MNT/hard"; ln -s f2 "$MNT/sym"
sync
[ "$(cat "$MNT/f7")" = "x7" ] && pass "files on the high-N volume read back" || fail "read-back failed"
STATF="$(stat -f -c '%c' "$MNT")"
[ "$STATF" = "$N_INODES" ] && pass "statfs reports all $N_INODES inodes" ||
    fail "statfs f_files=$STATF, expected $N_INODES"
ct_umount "$MNT"

log "a HIGH inode number (bitmap block 2, deep table offset) is fully handled"
"$POKE" "$DEV" "$HIGH" 0 0 >/dev/null
"$POKE" "$DEV" "$HIGHER" 0 0 >/dev/null
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
echo "$FSCK_OUT" | grep -q "inode $HIGH is allocated" &&
    pass "fsck's walk reaches inode $HIGH (second bitmap block)" ||
    fail "fsck never saw the planted high inode -- its walk stops early"
echo "$FSCK_OUT" | grep -q "inode $HIGHER is allocated" &&
    pass "fsck's walk reaches inode $HIGHER (end of the table)" ||
    fail "fsck never saw the last-block inode"
[ "$FSCK_RC" = 0 ] && pass "the orphans are WARNs, not corruption, at high numbers too" ||
    fail "fsck exited $FSCK_RC"

log "the scrub reclaims a high-numbered orphan (bitmap CAS in block 2)"
ct_param_set scrub 1
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
orphans() { sed -n 's/^scrub_orphan_inodes_reclaimed: //p' "/proc/fs/cetrafs/$PROC_DEV/info"; }
# Delta against the module-global counter, same as scrub_orphan_inode.sh:
# an earlier suite's reclaims in the same module load are not ours.
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# (read right after mount: procfs needs the mount, and the first scrub
# cycle cannot fire before scrub_interval_secs from now)
OBASE="$(orphans)"
for i in $(seq 1 30); do
    [ "$(($(orphans) - OBASE))" -ge 2 ] 2>/dev/null && break
    sleep 1
done
REC="$(($(orphans) - OBASE))"
[ "$REC" = 2 ] && pass "the scrub reclaimed both high-numbered orphans (delta=$REC)" ||
    fail "scrub_orphan_inodes_reclaimed delta=$REC, expected 2 -- high bitmap blocks mishandled"
ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "inode $HIGH is allocated" &&
    fail "inode $HIGH still allocated after the scrub" ||
    pass "the high-numbered inodes are gone; the volume is clean again"

losetup -d "$DEV"
rmdir "$MNT"
rm -f "$IMG"

ct_exit
