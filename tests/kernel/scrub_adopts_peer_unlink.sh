#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file a peer deleted while this node had it open is freed after the close, not left cached
#
# A peer that unlinks a file this node has open leaves the free to the
# opener (its eviction sees the presence bit). The opener's eviction
# frees on its own link count, which a peer's unlink never moves: after
# the close the dead file stayed cached here with i_nlink 1, its
# eviction freed nothing, and the orphan scrub skipped the number
# because "our own object's eviction owns the free" (audit 2026-11-15
# BL-87). The scrub now adopts the death into that object and drops its
# unused dentries, so the eviction frees it.
#
# Staged on one node: a file with data, held open for reading; the
# peer's unlink written to the backing image while it is (its dirent
# erased, the directory's dirent_seq bumped, the record's nlink 0); the
# close; then a fast scrub.
#   setup: the record reads deleted while the in-core object lived;
#   1. the eviction freed it during the mount: the number is free and
#      nothing leaked (fsck after the unmount);
#   2. fsck clean.
#
# DISCRIMINATION: scrub_local_no_adopt=1 -- the number is still allocated
# with nlink 0 after the unmount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/scrub_local_no_adopt ] || { skip "scrub_local_no_adopt is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
CORRUPT="$(ct_helper corrupt_poke)"
MNT="$(ct_mnt sapu)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set trim_quarantine_secs 1 # else every claim holds the scrub off for 600 s
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set scrub_local_no_adopt 0

# <no_adopt 0|1> -> "dead= msg= allocated= leaked= err="
round() {
    local img dev d ino dino mark dead=0 msg=0 alloc=0 leaked=0 err=0 o
    img="$(ct_image 560 "sapu$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    d="$MNT/d"
    mkdir "$d"
    dd if=/dev/urandom of="$d/f" bs=1M count=2 conv=fsync status=none
    ino="$(stat -c %i "$d/f")"
    dino="$(stat -c %i "$d")"
    sync
    echo "$1" >/sys/module/cetrafs/parameters/scrub_local_no_adopt
    mark="$(dmesg_mark)"
    exec 7<"$d/f"
    # The peer's unlink, as it leaves the device.
    "$CORRUPT" "$img" dirent "$dino" f >/dev/null 2>&1
    "$IPOKE" "$img" bumpseq "$dino" >/dev/null 2>&1
    "$IPOKE" "$img" setsize "$dino" 532 >/dev/null 2>&1 # '.' and '..': what the unlink leaves
    "$IPOKE" "$img" nlink "$ino" 0 >/dev/null 2>&1
    [ "$("$IPOKE" "$img" nsget "$ino" 2>/dev/null | cut -d' ' -f2)" = 0 ] && dead=1
    exec 7<&-
    ct_param_set scrub 1
    for _ in $(seq 1 40); do
        dmesg_since "$mark" | grep -q "scrub: ino=$ino: deleted by another node" && { msg=1; break; }
        sleep 0.5
    done
    sleep 2 # the eviction after the adopt, and any cycle that follows
    ct_param_set scrub 0
    echo 0 >/sys/module/cetrafs/parameters/scrub_local_no_adopt
    ct_umount "$MNT"
    o="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q "inode $ino is allocated" <<<"$o" && alloc=1
    grep -qi "leak" <<<"$o" && leaked=1
    grep -q "^ERR" <<<"$o" && err=1
    grep -m3 "^ERR" <<<"$o" >&2 || true # said, for a failing round
    echo "dead=$dead msg=$msg allocated=$alloc leaked=$leaked err=$err"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "adopted: $R"
C="$(round 1)"
log "control (not adopted): $C"
for v in "$R" "$C"; do
    [ "$(get dead "$v")" = 1 ] || { fail "setup: the record did not read deleted ($v)"; ct_exit; }
done
pass "setup: the peer's unlink was on the device while this node held the file"
[ "$(get msg "$R")" = 1 ] && [ "$(get allocated "$R")" = 0 ] && [ "$(get leaked "$R")" = 0 ] &&
    pass "1: the scrub adopted the death and the eviction freed the number and its blocks" ||
    fail "1: the dead file was not freed during the mount ($R)"
[ "$(get err "$R")" = 0 ] && pass "2: fsck clean" || fail "2: fsck reported errors ($R)"
[ "$(get allocated "$C")" = 1 ] &&
    pass "control: not adopted, the number was still allocated with no name after the unmount" ||
    fail "control: the dead file was freed anyway -- the suite does not reach the skip ($C)"
ct_exit
