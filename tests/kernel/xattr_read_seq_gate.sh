#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless xattr read trusts its copy only if the record's xattr_seq did not move under it
#
# getxattr copies the block the record names, then re-reads the record
# and keeps the copy only if it still names that block. A block number
# cycles: a peer removes the last xattr (the block is freed), another
# file's setxattr takes it, that file drops it, and this file's next
# setxattr takes it again -- the record names the same number, and the
# copy is the OTHER file's xattrs (audit 2026-11-11 X4). Every publish
# that changes xattr_block now stamps xattr_seq (format 0x000A), and the
# re-read requires the stamp unchanged too.
#
# The rig: the copy is taken (value A), the read pauses before its
# re-read (xattr_recheck_pause_ms); meanwhile the block is rewritten in
# place to value B and the record's xattr_seq advanced -- what a cycle
# that landed on the same number leaves. A read that honours the stamp
# starts over and returns B; one that does not returns its copy, A.
#
#  1. the paused read returns B.
#
# DISCRIMINATION (2026-11-11, xattr.c without the stamp check): 1
# returns A.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_recheck_pause_ms ] || { skip "xattr_recheck_pause_ms is missing"; ct_exit; }
REC="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 xseq)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xseq)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
touch "$MNT/f"
INO="$(stat -c %i "$MNT/f")"
setx() { python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", sys.argv[2].encode())' "$MNT/f" "$1"; }
get() { python3 -I -c 'import os,sys; sys.stdout.write(os.getxattr(sys.argv[1], "user.k").decode())' "$MNT/f"; }
setx AAAAAAAA
[ "$(get)" = AAAAAAAA ] || { fail "setup: the value does not read back"; ct_exit; }
sync

OUT="$(ct_tmp xseq-out)"
ct_param_set xattr_recheck_pause_ms 3000
( get >"$OUT" 2>&1 ) &
R=$!
sleep 1
ct_param_set xattr_recheck_pause_ms 0
setx BBBBBBBB
sync
"$REC" "$IMG" bumpxseq "$INO" 2>/dev/null
wait "$R" || true
V="$(cat "$OUT")"
[ "$(get)" = BBBBBBBB ] || { fail "setup: the in-place rewrite did not land: $(get)"; ct_exit; }
[ "$V" = BBBBBBBB ] && pass "1: the read saw xattr_seq move and started over (B)" ||
    fail "1: the read returned its copy from before the stamp moved: '$V'"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -m2 ERR)"
losetup -d "$DEV"
ct_exit
