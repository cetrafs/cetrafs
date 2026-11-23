#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a path stat keeps a file's page cache unless its change stamp moved
#
# Every dentry revalidate of a file nobody here has open re-reads its
# record and applies it (cetrafs_refresh_vfs_inode_if_newer()), and the
# apply dropped the file's whole page cache and marked its tree cold --
# with no look at file_seq, the change stamp every other cache decision
# asks. A path stat() was enough to send a reader's next read to the
# device (audit 2026-11-22 N-32). The caches now go only when the
# record's stamp is not the one they stand at.
#
# An 8 MiB file written and read here, then closed:
#   1. five path stats keep its caches (refresh_cache_kept rises, no
#      drop), and reading it again costs (almost) no device reads;
#   2. a peer's publish (a new size and file_seq on the device) is still
#      seen: the next stat drops the caches and reports the new size.
#
# DISCRIMINATION: refresh_drops_always=1 (as before): the stats drop the
# caches and the re-read goes back to the device.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/refresh_drops_always ] || { skip "refresh_drops_always is missing"; ct_exit; }
[ -z "${CT_MOUNT_OPTS:-}" ] || { skip "the stamps a nofilelock reader keeps are nofilelock_coherency.sh's"; ct_exit; }
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt rkc)"
ct_track mnt "$MNT"
ct_param_set refresh_drops_always 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <always 0|1> -> RES "drops= kept= rereads= peerdrops= peersize="
round() {
    local dev info st reads0 d0 k0 i
    dev="$(ct_dev 560 "rkc$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    info="$(ct_procdir "$dev")/info"
    st="/sys/block/$(basename "$dev")/stat"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=8 conv=fsync status=none
    cat "$MNT/f" >/dev/null # in the page cache, no fd left open
    echo "$2" >$P/refresh_drops_always
    d0="$(sed -n 's/^refresh_cache_drops: //p' "$info")"
    k0="$(sed -n 's/^refresh_cache_kept: //p' "$info")"
    for i in 1 2 3 4 5; do stat "$MNT/f" >/dev/null; done
    RES="drops=$(($(sed -n 's/^refresh_cache_drops: //p' "$info") - d0))"
    RES="$RES kept=$(($(sed -n 's/^refresh_cache_kept: //p' "$info") - k0))"
    reads0="$(awk '{print $1}' "$st")"
    cat "$MNT/f" >/dev/null
    RES="$RES rereads=$(($(awk '{print $1}' "$st") - reads0))"
    # A peer's publish: a new size, stamped as node 1's.
    d0="$(sed -n 's/^refresh_cache_drops: //p' "$info")"
    "$LPOKE" "$dev" --peer-size "$(stat -c %i "$MNT/f")" $((4 << 20)) 1 >/dev/null
    RES="$RES peersize=$(stat -c %s "$MNT/f")"
    RES="$RES peerdrops=$(($(sed -n 's/^refresh_cache_drops: //p' "$info") - d0))"
    echo 0 >$P/refresh_drops_always
    ct_umount "$MNT"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (always drop): $C"
[ "$(get kept "$R")" -ge 1 ] && [ "$(get drops "$R")" = 0 ] && [ "$(get rereads "$R")" -le 8 ] &&
    pass "1: five path stats kept the caches; the re-read took $(get rereads "$R") device reads" || fail "1: $R"
[ "$(get peerdrops "$R")" -ge 1 ] && [ "$(get peersize "$R")" = $((4 << 20)) ] &&
    pass "2: a peer's publish is still seen: caches dropped, the new size reported" || fail "2: $R"
[ "$(get drops "$C")" -ge 1 ] && [ "$(get rereads "$C")" -ge 32 ] &&
    pass "control: dropping always, the stats sent the re-read to the device ($(get rereads "$C") reads)" ||
    fail "control: $C -- the stats do not reach the refresh, or the re-read does not show it"
ct_exit
