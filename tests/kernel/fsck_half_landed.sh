#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r clears a create's half-landed record instead of refusing all repair
#
# A whole-record write that stops between its two sectors leaves both
# sectors valid and on different generations. Only a create writes a
# new generation, and it syncs the record before the dirent, so such a
# record is unnamed and owns nothing. fsck called it "checksum is wrong",
# disabled every repair for the run, and no tool could ever clear it
# (audit 2026-11-15 BM-69).
#
# Planted, besides a leaked data block (a bit set that nothing names):
#   U. an unnamed slot half-landed: fsck -r keeps repairing -- the
#      leaked bit is cleared, the record is dead-stamped and its number
#      freed, and a second fsck finds nothing;
#   N. a NAMED file's record half-landed: no create leaves that, which
#      half is the file cannot be told, so repair stays disabled and the
#      leaked bit is kept.
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_HALF_LANDED_OFF=1 (as before): U
# disables repair and keeps the leaked bit.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
HPOKE="$(ct_helper half_born_poke)"
BGPOKE="$(ct_helper bg_poke)"
BMP="$(ct_helper bmap_poke)"
MNT="$(ct_mnt fhl)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
export CETRAFS_PEER_PROBE_SECS=3
LEAKBIT=8000
SLOT=50
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <U|N> <off 0|1> -> RES
round() {
    local img dev n d0 bm leakbit out out2 rc2=0
    img="$(ct_image 560 "fhl$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    head -c 4096 /dev/urandom >"$MNT/n"
    sync
    n="$(stat -c %i "$MNT/n")"
    ct_umount "$MNT"
    if [ "$2" = U ]; then
        "$HPOKE" "$img" "$SLOT" --landed >/dev/null || { fail "setup: half_born_poke --landed $SLOT"; ct_exit; }
    else
        "$HPOKE" "$img" "$n" --landed >/dev/null || { fail "setup: half_born_poke --landed $n"; ct_exit; }
    fi
    d0="$("$BGPOKE" "$dev" 0 --dump)"
    bm=$(( $(grep -oP 'start_block=\K[0-9]+' <<<"$d0") + $(grep -oP 'off_data_bmap=\K[0-9]+' <<<"$d0") ))
    "$BMP" "$img" "$bm" "$LEAKBIT" 1
    blockdev --flushbufs "$dev"
    if [ "$3" = 1 ]; then
        out="$(CETRAFS_TEST_FSCK_HALF_LANDED_OFF=1 "$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    else
        out="$("$ROOT/userspace/fsck.cetra" -r "$dev" 2>&1 || true)"
    fi
    blockdev --flushbufs "$dev"
    leakbit="$("$BMP" "$img" "$bm" "$LEAKBIT")"
    out2="$("$ROOT/userspace/fsck.cetra" "$dev" 2>&1)" || rc2=$?
    RES="landed=$(grep -c 'different generations' <<<"$out" || true) blocked=$(grep -c 'repair is disabled' <<<"$out" || true)"
    RES="$RES named=$(grep -c "names inode .*different generations" <<<"$out" || true) leakbit=$leakbit"
    RES="$RES rc2=$rc2 again=$(grep -c 'different generations\|leaked\|checksum is wrong' <<<"$out2" || true)"
    if [ -n "${DEBUG_FHL:-}" ]; then printf '%s\n--\n%s\n' "$out" "$out2" >&2; fi
}

round uc U 1
C="$RES"
log "U control (as before): $C"
round uf U 0
R="$RES"
log "U fixed: $R"
round nf N 0
N="$RES"
log "N named: $N"

[ "$(get landed "$R")" -ge 1 ] && [ "$(get landed "$C")" = 0 ] ||
    { fail "setup: the half-landed record was not seen ($R / $C)"; ct_exit; }
[ "$(get blocked "$R")" = 0 ] && pass "U1: an unnamed half-landed record left repair enabled" || fail "U1: $R"
[ "$(get leakbit "$R")" = 0 ] && pass "U2: the leaked block was cleared in the same run" || fail "U2: $R"
[ "$(get rc2 "$R")" = 0 ] && [ "$(get again "$R")" = 0 ] &&
    pass "U3: a second fsck finds the volume clean -- the record was cleared" || fail "U3: $R"
[ "$(get blocked "$C")" -ge 1 ] && [ "$(get leakbit "$C")" = 1 ] &&
    pass "control: as before, the record disabled repair and the leak stayed" ||
    fail "control: repair ran without the change -- the suite does not reach it: $C"
[ "$(get named "$N")" -ge 1 ] && [ "$(get blocked "$N")" -ge 1 ] && [ "$(get leakbit "$N")" = 1 ] &&
    pass "N: a named half-landed record still disables repair, the leaked bit kept" || fail "N: $N"
ct_exit
