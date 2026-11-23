#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck reports a directory whose blocks leave a gap
#
# The kernel refuses, on every node, a directory whose extents are not
# dense from logical block 0 (cetrafs_dir_extents_addr_ok(), audit
# 2026-11-22 N-28). fsck's directory walk read such a directory's names
# block by block and reported the volume clean (audit 2026-11-22
# N-271). It now checks the walk's extents the way the kernel does, and
# reports a gap or an overlap.
#
# Staged on an image (nothing mounted): a fresh volume's root directory,
# its one inline extent moved to logical block 1 -- a gap at 0.
#   0. setup: the fresh volume is fsck-clean, and the gap is in place;
#   1. fsck: nonzero, and names the directory's gap.
#
# DISCRIMINATION: the control, in-suite --
# CETRAFS_FSCK_TEST_DIR_GAPS_UNCHECKED=1, the old walk (with the names
# checks off too, which also see the moved block): the volume is
# reported clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
IPOKE="$(ct_helper inode_block_poke)"
SBPOKE="$(ct_helper sb_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 600 fsdg)"
DEV="$(ct_loop "$IMG")"

ct_mkfs "$DEV" -N 1024 -f >/dev/null
ROOTINO="$("$SBPOKE" "$DEV" | sed -n 's/^root_ino=//p')"
"$FSCK" "$DEV" >/dev/null 2>&1 && pass "setup: the fresh volume is fsck-clean" ||
    { fail "setup: the fresh volume is not fsck-clean"; ct_exit; }
"$IPOKE" "$IMG" setlblk "$ROOTINO" 0 1 2>/dev/null
blockdev --flushbufs "$DEV"
"$IPOKE" "$IMG" extents "$ROOTINO" | grep -q '^ext 0 logical=1 ' && pass "setup: the root's one extent starts at logical block 1" ||
    { fail "setup: the root's extent was not moved: $("$IPOKE" "$IMG" extents "$ROOTINO" | tr '\n' ' ')"; ct_exit; }
SAID="directory inode $ROOTINO has extent 0 at logical block 1 where 0 was expected"

CRC=0
# the names checks off as well: a first block moved to logical 1 also
# holds its '.' and '..' out of place (fsck_dir_names.sh), and the gap
# check must be the only thing that can fail this volume
OUT="$(CETRAFS_FSCK_TEST_DIR_GAPS_UNCHECKED=1 CETRAFS_FSCK_TEST_NAMES_UNCHECKED=1 "$FSCK" "$DEV" 2>&1)" || CRC=$?
[ "$CRC" = 0 ] && ! grep -q "$SAID" <<<"$OUT" &&
    pass "control: the old walk reports the volume clean, gap and all" ||
    fail "control: the old walk exited $CRC -- the hazard did not reproduce: $(grep -E '^ERR' <<<"$OUT" | head -2 | tr '\n' ' ')"
RC=0
OUT="$("$FSCK" "$DEV" 2>&1)" || RC=$?
[ "$RC" != 0 ] && grep -q "$SAID" <<<"$OUT" && pass "1: fsck reports the root directory's gap (exit $RC)" ||
    fail "1: exit $RC, $(grep -E '^ERR' <<<"$OUT" | head -3 | tr '\n' ' ')"
ct_exit
