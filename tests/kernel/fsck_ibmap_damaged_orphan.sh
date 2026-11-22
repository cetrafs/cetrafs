#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r takes a damaged inode-bitmap sector's bits as in use, never as free
#
# fsck loaded the inode bitmap bit by bit, including the bits of sectors
# whose checksum fails, and only counted the damage. The data bitmap
# treats such a sector as in use (fsck_bmap_bit_damaged()); the inode
# bitmap had no equivalent, and repair went ahead. So under -r a live
# inode nothing names, whose bit happened to read 0 in a damaged
# sector, was skipped by the inode passes: its blocks were cleared as
# leaked, its number could be handed to /lost+found, and the bitmap was
# then restamped so the loss looked valid (audit 2026-11-22 N-40).
#
# A file with known data is written and unmounted; its dirent is
# unnamed (dirent_field_poke) -- a live, unnamed inode, which fsck -r
# links into /lost+found. Two volumes:
#   control: the inode's bit is intact. Setup: fsck -r links it.
#   damaged: the bit is cleared WITHOUT restamping its sector
#            (bmap_poke raw), so the bit reads 0 and the sector fails
#            its checksum. Setup: read-only fsck reports the damaged
#            sector. Then fsck -r must still link the inode into
#            /lost+found with its data, and leave its blocks allocated.
#
# DISCRIMINATION (measured on the unfixed code): the damaged case frees
# the file's blocks and /lost+found does not hold it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SBPOKE="$(ct_helper sb_poke)"
IPOKE="$(ct_helper inode_block_poke)"
DPOKE="$(ct_helper dirent_field_poke)"
BPOKE="$(ct_helper bmap_poke)"
MNT="$(ct_mnt fibdo)"
DIRENT=266 # sizeof(cetrafs_dirent_t)

# volume <tag> <damage 0|1> -> "<ino> <in /lost+found> <data intact> <fsck -r rc> <setup ok|...> <fsck clean after>"
volume() {
    local img dev ino blk slot name ibm bit rc=0 out lf=no data=no sum clean=no
    img="$(ct_image 560 "fibdo$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    head -c 262144 /dev/urandom >"$MNT/victim"
    sum="$(md5sum <"$MNT/victim" | cut -d' ' -f1)"
    ino="$(stat -c %i "$MNT/victim")"
    ct_umount "$MNT"
    blockdev --flushbufs "$dev"
    # The root directory's first dirent block, and the slot naming victim.
    blk="$("$IPOKE" "$img" extents 1 | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
    slot=""
    for s in $(seq 0 14); do
        name="$(dd if="$img" bs=1 skip=$((blk * 4096 + s * DIRENT + 11)) count=6 status=none)"
        [ "$name" = victim ] && { slot=$s; break; }
    done
    [ -n "$blk" ] && [ -n "$slot" ] || { echo "0 no no 0 no-dirent no"; return; }
    "$DPOKE" "$img" "$blk" "$slot" inode 0 >/dev/null
    if [ "$2" = 1 ]; then
        ibm="$("$SBPOKE" "$img" | sed -n 's/^inode_bmap_start=//p')"
        bit=$((ino - 1))
        "$BPOKE" "$img" "$ibm" "$bit" 0 raw >/dev/null
        blockdev --flushbufs "$dev"
        ct_fsck "$dev" 2>&1 | grep -q "inode bitmap.*fail their checksum" ||
            { echo "$ino no no 0 no-damage no"; return; }
    fi
    blockdev --flushbufs "$dev"
    out="$("$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1)" || rc=$?
    blockdev --flushbufs "$dev"
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    for f in "$MNT"/lost+found/*; do
        [ -f "$f" ] || continue
        [ "$(stat -c %i "$f")" = "$ino" ] && lf=yes && [ "$(md5sum <"$f" | cut -d' ' -f1)" = "$sum" ] && data=yes
    done
    ct_umount "$MNT"
    # Its blocks still allocated: a referenced block left free is an ERR
    # to the read-only pass.
    ct_fsck "$dev" >/dev/null 2>&1 && clean=yes
    echo "$ino $lf $data $rc ok $clean"
}

read -r INO LF DATA RC SETUP CLEAN <<<"$(volume ctl 0)"
[ "$SETUP" = ok ] && [ "$LF" = yes ] && pass "control: with the bit intact, fsck -r links inode $INO into /lost+found" ||
    { fail "control: setup '$SETUP', /lost+found holds inode $INO: $LF -- nothing to compare against"; ct_exit; }

read -r INO LF DATA RC SETUP CLEAN <<<"$(volume dmg 1)"
[ "$SETUP" = ok ] || { fail "setup: $SETUP -- the damaged sector was not arranged"; ct_exit; }
pass "setup: inode $INO's bit reads 0 in a sector fsck reports damaged"
[ "$LF" = yes ] && [ "$DATA" = yes ] &&
    pass "the damaged sector's bit was taken as in use: inode $INO is in /lost+found with its data" ||
    fail "inode $INO was skipped: in /lost+found $LF, data intact $DATA (fsck -r rc=$RC)"
[ "$CLEAN" = yes ] && pass "after the repair fsck is clean: the file's blocks stayed allocated" ||
    fail "after the repair fsck reports damage -- the file's blocks were freed under it"
ct_exit
