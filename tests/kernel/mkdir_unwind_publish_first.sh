#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed mkdir frees its block only once the record naming it is dead
#
# mkdir writes its '.'/'..' block, then the record that names it, then
# instantiates it. When the instantiation (iget) failed, the unwind freed
# the block FIRST and then wrote the record back dead: a dead-record write
# the device refused -- or a crash between the two -- left a live-looking
# directory record naming a free block, for the allocator to hand out to
# the next file (audit 2026-11-22, N-25; CLAUDE.md rule 21). The block is
# now freed after the record is shown dead, and kept with the number when
# it cannot be.
#
# Staged: iget_read_fail=1 fails the new directory's iget; the unwind's
# dead-record write is refused (born_unwind_write_fail) and so is the
# number's free (free_inode_read_fail), as a device refusing writes would.
# The check: fsck finds no block in use but marked free -- the record and
# its block are left as a pair, which fsck reports as an orphan.
# A clean round (iget fails, nothing else does) must still free both.
#
# DISCRIMINATION: the control, in-suite -- mkdir_unwind_free_first=1, the
# old order: fsck finds the record's block marked free.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in iget_read_fail born_unwind_write_fail free_inode_read_fail mkdir_unwind_free_first; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
ct_param_set iget_read_fail 0
ct_param_set born_unwind_write_fail 0
ct_param_set free_inode_read_fail 0
ct_param_set mkdir_unwind_free_first 0
ct_param_set scrub 0
MNT="$(ct_mnt mkuw)"
ct_track mnt "$MNT"

# round <tag> <refuse 0|1> <free_first 0|1> -> RES
round() {
    local dev failed=n out
    dev="$(ct_dev 560 "mkuw$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    touch "$MNT/a"
    echo "$3" >$P/mkdir_unwind_free_first
    if [ "$2" = 1 ]; then
        echo 1 >$P/born_unwind_write_fail
        echo 1 >$P/free_inode_read_fail
    fi
    echo 1 >$P/iget_read_fail
    mkdir "$MNT/x" 2>/dev/null || failed=y
    echo 0 >$P/iget_read_fail
    echo 0 >$P/born_unwind_write_fail
    echo 0 >$P/free_inode_read_fail
    echo 0 >$P/mkdir_unwind_free_first
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    RES="failed=$failed marked_free=$(grep -c 'in use but marked free' <<<"$out" || true)"
    RES="$RES errs=$(grep -c '^ERR' <<<"$out" || true)"
    log "$1: $RES"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2; }

round ctl 1 1
[ "$(get failed "$RES")" = y ] && [ "$(get marked_free "$RES")" -ge 1 ] &&
    pass "control: freed first, the refused unwind left the record naming a free block ($RES)" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $RES"
round refused 1 0
[ "$(get failed "$RES")" = y ] || fail "refused setup: the injected iget failure did not fail the mkdir ($RES)"
[ "$(get marked_free "$RES")" = 0 ] &&
    pass "with the record not shown dead, its block stayed allocated ($RES)" ||
    fail "the failed mkdir freed a block its record still names: $RES"
round clean 0 0
[ "$(get failed "$RES")" = y ] && [ "$(get errs "$RES")" = 0 ] &&
    pass "a failed mkdir whose unwind lands frees both: fsck clean ($RES)" ||
    fail "the ordinary unwind left damage or a leak: $RES"
ct_exit
