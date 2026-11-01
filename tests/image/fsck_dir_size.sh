#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck checks a directory's size against its entries, and -r sets it
#
# A directory's size is sizeof(cetrafs_dirent_t) per occupied slot, '.'
# and '..' included; every create and unlink moves it by one entry. A
# size left wrong -- a lost publish, a crash between the entry and the
# record -- stays wrong for good, since each later create or unlink
# adjusts the number it finds, and nothing looked at it: fsck called a
# directory of 798 bytes clean where the entries said 1064.
#
# No kernel module and nothing mounted: mkfs writes the root, the poke
# sets its size wrong, fsck must report exactly that and -r must fix it.
#
# DISCRIMINATION (measured on the unfixed fsck): the wrong size passes
# as clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper inode_block_poke)"
DE=266 # sizeof(cetrafs_dirent_t)

IMG="$(ct_image 560 dirsize)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null

rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "a fresh volume's directory sizes agree with their entries" ||
    { fail "fresh volume: fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -1)"; ct_exit; }

want="$("$POKE" "$DEV" size 1)"
[ -n "$want" ] && [ $((want % DE)) = 0 ] && pass "setup: root's size is $want ($((want / DE)) entries)" ||
    { fail "setup: cannot read root's size ('$want')"; ct_exit; }
"$POKE" "$DEV" setsize 1 $((want + DE)) >/dev/null

rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "directory inode 1 has size $((want + DE)) but holds $((want / DE)) entries" <<<"$out" &&
    pass "fsck reports the root's size one entry too large" ||
    fail "fsck did not report the wrong size (rc=$rc): $(grep '^ERR' <<<"$out" | head -1)"

rc=0
"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || rc=$? # ct_fsck passes one argument
rc2=0
out="$(ct_fsck "$DEV" 2>&1)" || rc2=$?
got="$("$POKE" "$DEV" size 1)"
[ "$rc2" = 0 ] && [ "$got" = "$want" ] && pass "fsck -r set it back to $want and the volume is clean" ||
    fail "after -r (rc=$rc): size $got, fsck rc=$rc2: $(grep '^ERR' <<<"$out" | head -1)"
ct_exit
