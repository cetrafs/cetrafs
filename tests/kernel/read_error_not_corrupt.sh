#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a block the device fails to read is an I/O error, not corruption
#
# The tail-checked readers (xattr, extent leaf and index blocks through
# cetrafs_blk_tail_bread(), dirent blocks through dir.c's own) retried a
# read that failed on the same footing as a checksum mismatch, and when
# the budget ran out called it corruption: "run fsck", the corruption
# count bumped, and under corruption=stop the whole mount stopped -- for
# a path error that the device would have answered a moment later.
# ERRORS.md kind 1: the operation gets EIO, nothing more.
#
# Staged on a dm device with one block turned into an error target
# after the mount: a file's xattr block, then a directory's dirent block,
# each read forced-fresh. Mounted corruption=stop, so the old verdict
# shows as a stopped mount.
#
# DISCRIMINATION: with read failures counted as mismatches, corruptions
# rises and the mount stops.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_failable_dev 560 rderr)"
[ -n "$DEV" ] || { skip "device-mapper unavailable"; ct_exit; }
NAME="$(basename "$DEV")"
read -r _ SECTORS _ LOOP _ < <(dmsetup table "$NAME")
IMG="$(cat "/sys/dev/block/$LOOP/loop/backing_file")"
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt rderr)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
mount -t cetrafs -o corruption=stop "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
corrupt() { sed -n 's/^corruptions: //p' "$PROC"; }
stopped() { sed -n 's/^stopped: //p' "$PROC"; }

echo x >"$MNT/f"
python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"v" * 64)' "$MNT/f"
mkdir "$MNT/d"
for i in 1 2 3; do touch "$MNT/d/e$i"; done
sync
FI="$(stat -c %i "$MNT/f")"; DI="$(stat -c %i "$MNT/d")"
XB="$("$IPOKE" "$IMG" xattrblk "$FI")"
DB="$("$IPOKE" "$IMG" extents "$DI" | sed -n 's/^ext 0 logical=0 phys=\([0-9]*\) .*/\1/p')"
[ -n "$XB" ] && [ "$XB" != 0 ] && [ -n "$DB" ] ||
    { fail "setup: no xattr block ($XB) or dirent block ($DB) to fail"; ct_exit; }
STOP0="$(stopped)"
log "xattr block $XB, dirent block $DB; stopped=$STOP0 corruptions=$(corrupt)"

dm_set() {
    dmsetup suspend --noflush --nolockfs "$NAME"
    dmsetup load "$NAME" --table "$1"
    dmsetup resume "$NAME"
}
fail_block() { # <block>: that block's 8 sectors return EIO, reads and writes
    local x=$(($1 * 8))
    dm_set "0 $x linear $LOOP 0
$x 8 error
$((x + 8)) $((SECTORS - x - 8)) linear $LOOP $((x + 8))"
}
LINEAR="0 $SECTORS linear $LOOP 0"

# round <label> <block> <command...>: the command must fail with EIO and
# leave the corruption count and the mount alone.
round() {
    local label="$1" blk="$2" c0 out mark
    shift 2
    c0="$(corrupt)"
    mark="$(dmesg_mark)"
    fail_block "$blk"
    out="$("$@" 2>&1)" && rc=0 || rc=$?
    dm_set "$LINEAR"
    # The reader names the block whichever verdict it reaches, so this
    # proves the read got there in the fixed and the old kernel alike.
    dmesg_since "$mark" | grep -qE "block $blk (could not be read|failed its tail checksum)" ||
        { fail "$label: setup: the device never failed the read ($out)"; return; }
    [ "$rc" != 0 ] && grep -qi 'input/output error' <<<"$out" &&
        pass "$label: the read failed with EIO" || fail "$label: expected EIO, got rc=$rc: $out"
    [ "$(corrupt)" = "$c0" ] && pass "$label: not counted as corruption" ||
        fail "$label: a device read error was counted as corruption ($c0 -> $(corrupt))"
    [ "$(stopped)" = "$STOP0" ] && pass "$label: the mount keeps going" ||
        fail "$label: a device read error stopped the mount (stopped: $(stopped))"
    dmesg_since "$mark" | grep -q 'corrupted, not just a torn' &&
        fail "$label: logged as corruption: $(dmesg_since "$mark" | grep 'corrupted, not' | head -1)" || true
    # A stopped mount would keep the next round from proving anything.
    if [ "$(stopped)" != "$STOP0" ]; then
        umount "$MNT" || umount -l "$MNT"
        mount -t cetrafs -o corruption=stop "$DEV" "$MNT"
    fi
}

getx() { python3 -c 'import os,sys; os.getxattr(sys.argv[1], "user.k")' "$1"; }
round xattr "$XB" getx "$MNT/f"
# The directory is read fresh once its dirent_seq moves, as a peer's
# create would move it.
"$IPOKE" "$IMG" bumpseq "$DI" 2>/dev/null
round dirent "$DB" ls "$MNT/d"

# And both work again once the device does.
getx "$MNT/f" >/dev/null 2>&1 && [ "$(ls "$MNT/d" | wc -l)" = 3 ] &&
    pass "both read again once the device answers" || fail "the xattr or the directory did not come back"
ct_umount "$MNT"
ct_exit
