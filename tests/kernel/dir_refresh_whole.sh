#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory a peer changed is refreshed once, not re-read by every lookup
#
# After a peer changes a directory (its dirent_seq moves) every walk of
# it reads forced-fresh, and the stamp that lets walks trust the cache
# again was re-armed only by a pass that ran to the end. A lookup stops
# at its match, so each stat re-read the directory from block 0 one
# round trip at a time: ~134k reads for `ls -l` of 2000 files (audit
# 2026-11-14 P6). The first stale walk now refreshes the whole directory
# in batches and re-arms the stamp.
#
# 400 files; the directory's dirent_seq is bumped as a peer's change
# would; the dentry cache is dropped and every file is stat'ed; the loop
# device's completed reads are counted.
#
# DISCRIMINATION: dir_refresh_whole_off re-reads per walk, as before.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dir_refresh_whole_off ] || { skip "dir_refresh_whole_off is missing"; ct_exit; }
SEQ="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt drw)"
ct_track mnt "$MNT"
ct_param_set dir_refresh_whole_off 0
P=/sys/module/cetrafs/parameters

# <off 0|1> <bump 0|1> -> "<reads> <files stat'ed>"
probe() {
    local img dev ino r0 n
    img="$(ct_image 560 "drw$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    for i in $(seq 1 400); do : >"$MNT/d/file-$i"; done
    sync
    ls "$MNT/d" >/dev/null
    ino="$(stat -c %i "$MNT/d")"
    [ "$2" = 0 ] || "$SEQ" "$img" bumpseq "$ino" >/dev/null # a peer's change
    echo "$1" >$P/dir_refresh_whole_off
    echo 2 >/proc/sys/vm/drop_caches
    r0="$(awk '{print $1}' "/sys/block/$(basename "$dev")/stat")"
    n="$(for i in $(seq 1 400); do stat -c %i "$MNT/d/file-$i"; done 2>/dev/null | wc -l)"
    echo "$(($(awk '{print $1}' "/sys/block/$(basename "$dev")/stat") - r0)) $n"
    echo 0 >$P/dir_refresh_whole_off
    ct_umount "$MNT" >/dev/null
}
read -r B _ <<<"$(probe 0 0)"
read -r R N <<<"$(probe 0 1)"
read -r R0 N0 <<<"$(probe 1 1)"
log "400 stats: $B reads unchanged; a peer changed it: $R refreshed whole, $R0 per walk"
[ "$N" = 400 ] && [ "$N0" = 400 ] || fail "setup: $N / $N0 of 400 files stat'ed"
[ "$R0" -ge 1000 ] || fail "setup: per-walk reading took only $R0 reads -- the directory was not stale"
# The stat itself (records, inode) costs B; the refresh adds the
# directory once, a few dozen blocks -- not a re-read per stat.
[ "$R" -le $((B + 100)) ] && pass "the stale directory cost $R reads for 400 stats -- refreshed once" ||
    fail "the stale directory cost $R reads for 400 stats -- still re-read per lookup (unchanged: $B)"
[ "$R0" -gt $((R * 3)) ] && pass "control: re-reading per walk takes $R0 -- the suite discriminates" ||
    fail "control: $R0 against $R -- the suite cannot tell"
ct_exit
