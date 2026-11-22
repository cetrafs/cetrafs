#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a dirent's file_type byte never decides an nlink: the locked inode's mode does
#
# Removing an entry took one off the parent's nlink when the entry's
# file_type byte said DIR, and a rename-over zeroed the replaced file's
# nlink by the same byte instead of taking one off. Nothing verifies that
# byte -- a damaged block whose CRC was restamped passes every check --
# so a regular file whose entry claims DIR cost its parent a link on
# unlink, and, replaced by a rename while hardlinked, lost its nlink
# altogether: its other name then named a file evict freed (audit
# 2026-11-22, N-50). Both now go by the verified record's mode, and the
# disagreement is reported.
#
#   1. unlink of a regular file whose entry says DIR: the parent's nlink
#      stays 2, and the mismatch is logged;
#   2. rename-over of a hardlinked regular file whose entry says DIR: the
#      other name keeps the file, nlink 1, its data intact after a
#      remount.
#
# DISCRIMINATION: the control, in-suite -- nlink_trust_dirent_type=1, the
# old decisions: the parent drops to 1, and the hardlinked file is lost.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
[ -w "$P/nlink_trust_dirent_type" ] || { skip "nlink_trust_dirent_type is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
DPOKE="$(ct_helper dirent_field_poke)"
DIRENT=266 # sizeof(cetrafs_dirent_t)
ct_param_set nlink_trust_dirent_type 0
ct_param_set auto_defrag 0
MNT="$(ct_mnt dtnt)"
ct_track mnt "$MNT"

# as_dir <img> <dir ino> <name>: rewrite that entry's file_type to DIR
as_dir() {
    local blk s name
    blk="$("$IPOKE" "$1" extents "$2" | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p' | head -1)"
    for s in $(seq 0 14); do
        name="$(dd if="$1" bs=1 skip=$((blk * 4096 + s * DIRENT + 11)) count=${#3} status=none)"
        [ "$name" = "$3" ] && { "$DPOKE" "$1" "$blk" "$s" file_type 2 >/dev/null && return 0; }
    done
    return 1
}

# round <tag> <trust> -> RES
round() {
    local img dev p q mark
    img="$(ct_image 560 "dtnt$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    mkdir "$MNT/p" "$MNT/q"
    : >"$MNT/p/victim"
    head -c 65536 /dev/urandom >"$MNT/q/keep"
    ln "$MNT/q/keep" "$MNT/q/tgtnm"
    : >"$MNT/q/srcnm"
    SUM="$(md5sum <"$MNT/q/keep")"
    p="$(stat -c %i "$MNT/p")" q="$(stat -c %i "$MNT/q")"
    ct_umount "$MNT"
    as_dir "$img" "$p" victim && as_dir "$img" "$q" tgtnm ||
        { fail "$1 setup: the entries could not be found to poke"; ct_exit; }
    echo "$2" >$P/nlink_trust_dirent_type
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    rm "$MNT/p/victim"
    mv "$MNT/q/srcnm" "$MNT/q/tgtnm"
    echo 0 >$P/nlink_trust_dirent_type
    RES="parent_nlink=$(stat -c %h "$MNT/p")"
    RES="$RES logged=$(dmesg_since "$mark" | grep -c 'going by the record' || true)"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    RES="$RES keep_nlink=$(stat -c %h "$MNT/q/keep" 2>/dev/null || echo gone)"
    [ "$(md5sum <"$MNT/q/keep" 2>/dev/null)" = "$SUM" ] && RES="$RES keep_data=ok" || RES="$RES keep_data=bad"
    ct_umount "$MNT"
    log "$1: $RES"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2; }

round ctl 1
[ "$(get parent_nlink "$RES")" = 1 ] && [ "$(get keep_nlink "$RES")" != 1 ] &&
    pass "control: by the byte, the parent lost a link and the hardlinked file its count ($RES)" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $RES"
round fixed 0
[ "$(get parent_nlink "$RES")" = 2 ] && [ "$(get logged "$RES")" -ge 2 ] &&
    pass "1: the unlink kept the parent's nlink at 2 and reported the entry ($RES)" ||
    fail "1: $RES"
[ "$(get keep_nlink "$RES")" = 1 ] && [ "$(get keep_data "$RES")" = ok ] &&
    pass "2: the rename-over left the other name its file, nlink 1, data intact" ||
    fail "2: $RES"
ct_exit
