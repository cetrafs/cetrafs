#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory with a gap in its blocks is refused, and growth never writes over an entry
#
# A directory grows only at its end, and growth took "the blocks it
# holds" as that end. A directory whose extents leave a gap -- damage, or
# a hostile image -- then mapped a "new" block the tree already held, and
# the new entry went into its slot 0: over '.', in the directory's first
# block (audit 2026-11-22 N-28). Two checks now:
#   - the extents must be dense from block 0 (cetrafs_dir_extents_addr_ok()),
#     so such a directory is refused as damage on every read;
#   - growth refuses a block it mapped that already names an entry.
#
# Staged: a directory d filled to exactly one full dirent block, then,
# unmounted, its one inline extent moved to logical block 1 (a gap at 0).
# Mounted again, one more create in d must grow it:
#   ctl:   dir_density_unchecked=1 dir_grow_blank_unchecked=1 (the old
#          code) -- the create lands in d's first block, slot 0: '.' is
#          gone;
#   blank: dir_density_unchecked=1 -- the growth check refuses the block,
#          '.' stays;
#   fixed: the create is refused as damage before any write, '.' stays.
#
# DISCRIMINATION: the ctl round, in-suite.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in dir_density_unchecked dir_grow_blank_unchecked; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt dsr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set dir_density_unchecked 0
ct_param_set dir_grow_blank_unchecked 0

slot0() { # <dev> <lba> -> the inode number dirent slot 0 of that block names
    dd if="$1" bs=4096 skip="$2" count=1 status=none | od -An -tu8 -N8 | tr -d ' '
}

dblocks() { # <img> <ino> -> the blocks its inline extents cover
    "$IPOKE" "$1" extents "$2" | awk -F'len=' '/^ext /{ t += $2 } END { print t + 0 }'
}

# round <tag> <density_unchecked> <blank_unchecked> -> "create=<ok|fail> slot0=<ino> dino=<ino>"
round() {
    local img dev dino n=0 phys cr=fail
    img="$(ct_image 560 "dsr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    mkdir "$MNT/d"
    dino="$(stat -c %i "$MNT/d")"
    # Fill d's first block and no more: create until a second block
    # appears, then remove the one that made it.
    while :; do
        touch "$MNT/d/f$n"
        sync
        ct_umount "$MNT"
        [ "$(dblocks "$img" "$dino")" -gt 1 ] && break
        ct_mount "$dev" "$MNT"
        n=$((n + 1))
        [ "$n" -lt 64 ] || { echo "setup: d never grew"; return; }
    done
    ct_mount "$dev" "$MNT"
    rm -f "$MNT/d/f$n"
    ct_umount "$MNT"
    # Back to one block: the growth's block is still named by the tree,
    # so rebuild the image with n files instead of shrinking it.
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    dino="$(stat -c %i "$MNT/d")"
    for i in $(seq 0 $((n - 1))); do touch "$MNT/d/f$i"; done
    sync
    ct_umount "$MNT"
    [ "$("$IPOKE" "$img" extents "$dino" | sed -n 's/.*entries=\([0-9]*\) .*/\1/p') $(dblocks "$img" "$dino")" = "1 1" ] ||
        { echo "setup: d is not one extent of one block"; return; }
    phys="$("$IPOKE" "$img" extents "$dino" | sed -n 's/^ext 0 .*phys=\([0-9]*\).*/\1/p')"
    [ "$(slot0 "$dev" "$phys")" = "$dino" ] || { echo "setup: d's first slot does not name d"; return; }
    "$IPOKE" "$img" setlblk "$dino" 0 1 2>/dev/null
    echo "$2" >"$P/dir_density_unchecked"
    echo "$3" >"$P/dir_grow_blank_unchecked"
    ct_mount "$dev" "$MNT"
    touch "$MNT/d/extra" 2>/dev/null && cr=ok
    echo 0 >"$P/dir_density_unchecked"
    echo 0 >"$P/dir_grow_blank_unchecked"
    ct_umount "$MNT"
    echo "files=$n create=$cr slot0=$(slot0 "$dev" "$phys") dino=$dino"
}

get() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p"; }

R="$(round ctl 1 1)"
log "ctl: $R"
[ -n "$(get dino "$R")" ] && [ "$(get slot0 "$R")" != "$(get dino "$R")" ] &&
    pass "control: unchecked, the growth wrote over '.' in d's first block ($R)" ||
    fail "control: the hazard did not reproduce -- the check cannot tell: $R"
R="$(round blank 1 0)"
log "blank: $R"
[ "$(get create "$R")" = fail ] && [ -n "$(get dino "$R")" ] && [ "$(get slot0 "$R")" = "$(get dino "$R")" ] &&
    pass "the growth check refuses a mapped block that names an entry: '.' stays ($R)" ||
    fail "the growth check: $R"
R="$(round fixed 0 0)"
log "fixed: $R"
[ "$(get create "$R")" = fail ] && [ -n "$(get dino "$R")" ] && [ "$(get slot0 "$R")" = "$(get dino "$R")" ] &&
    pass "a directory with a gap is refused before any write: '.' stays ($R)" ||
    fail "the gapped directory: $R"
ct_exit
