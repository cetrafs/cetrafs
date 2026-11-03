#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a free into a Block Group nobody owns is refused loudly, and that BG's bitmap is left alone
#
# A Block Group returns to the unowned pool only once it is empty, so an
# extent pointing into one is a reference to blocks nobody allocated.
# The free path sent it to the owner's pending-free queue, whose lookup
# failed with -EINVAL for the "no owner" ZG id -- unlogged, and every
# caller of a free drops its error. Now it is named, counted as damage,
# and the bitmap (which the next claimer owns) is not touched.
#
# Played by marking the file's BG unowned on the image, then deleting.
#
# DISCRIMINATION: without the check nothing is logged and corruptions
# stays 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
EXTENT_POKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 freeunowned)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt freeunowned)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/f" bs=4096 count=4 status=none
sync
PHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c %i "$MNT/f")" | cut -d' ' -f1)"
ct_umount "$MNT"
BG="$("$MAP" "$IMG" | awk -v l="$PHYS" '$1 == "bg" { split($4, a, "="); if (a[2] <= l) b = $2 } END { print b }')"
"$POKE" "$IMG" "$BG" --owner 65535 >/dev/null
BMAP_BEFORE="$("$MAP" "$IMG" | awk -v b="$BG" '$1 == "bg" && $2 == b { print $5 }')"
"$MAP" "$IMG" | grep -q "^bg $BG owner_zg=65535 " && pass "setup: f's blocks are in BG $BG, now marked unowned" ||
    { fail "setup: BG $BG not unowned: $("$MAP" "$IMG" | grep "^bg $BG ")"; ct_exit; }

ct_mount "$DEV" "$MNT"
PROC="$(ct_procdir "$DEV")"
MARK="$(dmesg_mark)"
C0="$(sed -n 's/^corruptions: //p' "$PROC/info")"
rm "$MNT/f"
sync
dmesg_since "$MARK" | grep -q "is in BG $BG, which no Zone Group owns" &&
    pass "the free is refused and named" || fail "nothing logged for a free into an unowned BG"
[ "$(sed -n 's/^corruptions: //p' "$PROC/info")" -gt "$C0" ] && pass "and counted as damage" ||
    fail "corruptions did not move ($C0)"
ct_umount "$MNT"
[ "$("$MAP" "$IMG" | awk -v b="$BG" '$1 == "bg" && $2 == b { print $5 }')" = "$BMAP_BEFORE" ] &&
    pass "BG $BG's free count is untouched ($BMAP_BEFORE)" || fail "BG $BG was modified by the refused free"
ct_exit
