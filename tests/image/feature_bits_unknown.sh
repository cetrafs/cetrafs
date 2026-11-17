#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a feature bit this build does not know stops every tool that would rewrite the volume
#
# The superblock carries three feature words (cetrafs.h, the feature
# rules): INCOMPAT -- an older build must not mount; RO_COMPAT -- it may
# mount read-only only; COMPAT -- the module may ignore it. A tool that
# REWRITES the volume cannot ignore any of them: fsck -r rewrites what it
# finds, and a structure it cannot see reads to it as space nobody uses;
# growfs lays out new groups around structures it does not know.
#
# For an unknown bit in each word, on a fresh volume (then, for the
# repair, with BG1's descriptor damaged so that a repair writes):
#   fsck     -- INCOMPAT refused (1); RO_COMPAT/COMPAT warned, checked (0)
#   fsck -r  -- refused before anything is written (INCOMPAT 1, as a
#               plain check; the others 3; image unchanged)
#   growfs   -- refused before anything is written (image unchanged)
#
# DISCRIMINATION: control -- the same volume with no unknown bit is
# repaired (0) and grown by the same commands.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
SBPOKE="$(ct_helper sb_poke)"
POKE="$(ct_helper csum_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
GROWFS="$ROOT/userspace/growfs.cetra"
IMG="$(ct_image 600 featbits)"
BIT=$((1 << 40))

# <field|none> -> RES "fsck=<rc> repair=<rc> rsame=<y|n> grow=<rc> gsame=<y|n>"
round() {
    local dev cur before rc
    truncate -s 600M "$IMG"
    dev="$(ct_loop "$IMG")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    if [ "$1" != none ]; then
        cur="$("$SBPOKE" "$dev" | sed -n "s/^$1=//p")"
        "$SBPOKE" "$dev" "$1" $((cur | BIT)) >/dev/null
    fi
    blockdev --flushbufs "$dev"
    rc=0
    "$FSCK" "$dev" >/dev/null 2>&1 || rc=$?
    RES="fsck=$rc"
    # Something to repair, so that a repair that runs writes.
    "$POKE" "$dev" bg-desc 1 >/dev/null
    blockdev --flushbufs "$dev"
    before="$(sha256sum <"$IMG")"
    rc=0
    "$FSCK" -r "$dev" >/dev/null 2>&1 || rc=$?
    blockdev --flushbufs "$dev"
    RES="$RES repair=$rc rsame=$([ "$before" = "$(sha256sum <"$IMG")" ] && echo y || echo n)"
    losetup -d "$dev"
    truncate -s 1200M "$IMG"
    dev="$(ct_loop "$IMG")"
    before="$(sha256sum <"$IMG")"
    rc=0
    "$GROWFS" "$dev" >/dev/null 2>&1 || rc=$?
    blockdev --flushbufs "$dev"
    RES="$RES grow=$rc gsame=$([ "$before" = "$(sha256sum <"$IMG")" ] && echo y || echo n)"
    losetup -d "$dev"
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

for f in features_incompat features_ro_compat features_compat; do
    round "$f"
    log "$f: $RES"
    want=0
    [ "$f" = features_incompat ] && want=1
    [ "$(field fsck "$RES")" = "$want" ] && pass "$f: fsck exits $want" || fail "$f: fsck: $RES"
    wantr=3
    [ "$f" = features_incompat ] && wantr=1
    [ "$(field repair "$RES")" = "$wantr" ] && [ "$(field rsame "$RES")" = y ] &&
        pass "$f: fsck -r refused, nothing written" || fail "$f: fsck -r: $RES"
    g="$(field grow "$RES")"
    [ "$g" != 0 ] && [ "$g" -lt 128 ] && [ "$(field gsame "$RES")" = y ] &&
        pass "$f: growfs refused, nothing written" || fail "$f: growfs: $RES"
done
round none
log "control: $RES"
[ "$(field fsck "$RES")" = 0 ] && [ "$(field repair "$RES")" = 0 ] && [ "$(field grow "$RES")" = 0 ] &&
    [ "$(field rsame "$RES")" = n ] && [ "$(field gsame "$RES")" = n ] &&
    pass "control: with no unknown bit the volume is checked, repaired (written) and grown" ||
    fail "control: the same commands do not succeed on a plain volume -- $RES"
ct_exit
