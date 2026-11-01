#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# listing a large directory reads each dirent block about once, not once per getdents call
#
# readdir resumed every getdents(2) call by walking the directory from
# its first block and discarding entries below the saved position --
# after READING them. When the directory has changed on another node
# every one of those reads is forced fresh, so a listing cost device
# reads quadratic in the directory's size: each 32 KiB getdents buffer
# re-read everything before it. Blocks wholly below the resume point
# are now skipped unread.
#
# The peer's change is played by advancing the directory's dirent_seq
# on the device. The cost is counted at the loop device.
#
# DISCRIMINATION (measured on the unfixed code): 20000 entries in 1298
# blocks cost 14338 device reads for one listing (fixed: 1377), and it
# grows with the square of the directory size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
N=20000

DEV="$(ct_dev 700 rdresume)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt rdresume)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N $((N + 1024)) -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
python3 - "$MNT/d" "$N" <<'PY'
import os, sys
for i in range(int(sys.argv[2])):
    os.close(os.open("%s/entry%07d" % (sys.argv[1], i), os.O_CREAT | os.O_WRONLY, 0o644))
PY
sync
DINO="$(stat -c %i "$MNT/d")"
DSIZE="$(stat -c %s "$MNT/d")"
DBLOCKS=$((DSIZE / 4096))
log "directory: $N entries in $DBLOCKS blocks"

"$IPOKE" "$BACK" bumpseq "$DINO" >/dev/null 2>&1 # a peer changed it: every read is forced fresh
reads() { awk '{print $1}' "/sys/block/$(basename "$DEV")/stat"; }
r0="$(reads)"
got="$(python3 -c 'import os,sys; print(len(os.listdir(sys.argv[1])))' "$MNT/d")"
r1="$(reads)"
[ "$got" = "$N" ] && pass "setup: the listing returned all $N names" || fail "the listing returned $got names, not $N"
dr=$((r1 - r0))
log "device reads for one listing: $dr (directory blocks: $DBLOCKS)"
[ "$dr" -lt $((DBLOCKS * 3)) ] && pass "one listing read each block about once ($dr reads, $DBLOCKS blocks)" ||
    fail "one listing cost $dr device reads over $DBLOCKS blocks -- every getdents call re-read from the top"

ct_umount "$MNT"
ct_exit
