#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r survives an interrupted and a partial read and write
#
# fsck's pwrite_all() was one pwrite: a short write ended the repair with
# the block half-written, and pread_all() treated EINTR as fatal (audit
# 2026-11-05, section 3). Both are allowed by POSIX, if rare on a block
# device. growfs already looped and retried; fsck now does too.
#
# io_shim (LD_PRELOAD) makes every pread/pwrite inside the Block Group
# table fail once with EINTR and then transfer only half of what it is
# asked. A BG free count is drifted (the convergence suite's fault); the
# shimmed fsck -r must repair it, and an unshimmed fsck must find the
# volume clean.
#
# DISCRIMINATION: proven 2026-11-05 against the old helpers: the shimmed
# repair stops at its first BG table read (EINTR) -- and, with the read
# fixed, at its first partial write. The zero-progress case printed
# "pwrite (repair): Success".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
BG_POKE="$(ct_helper bg_poke)"
SBP="$(ct_helper sb_poke)"
SHIM="$(ct_tmp io-shim).so"
cc -shared -fPIC -O2 -o "$SHIM" "$CT_TESTS/helpers/io_shim.c" -ldl || { fail "setup: the shim does not build"; ct_exit; }

IMG="$(ct_image 560 fsckio)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
BASE="$("$BG_POKE" "$DEV" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9][0-9]*\).*/\1/p')"
"$BG_POKE" "$DEV" 0 $((BASE - 64)) >/dev/null
blockdev --flushbufs "$DEV"
BGT="$("$SBP" "$IMG" | sed -n 's/^bg_table_start[ =:]*\([0-9][0-9]*\).*/\1/p')"
[ -n "$BGT" ] || { fail "setup: sb_poke printed no bg_table_start"; ct_exit; }
LO=$((BGT * 4096))
HI=$(((BGT + 1) * 4096))

OUT="$(SHIM_LO=$LO SHIM_HI=$HI LD_PRELOAD="$SHIM" "$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
log "shimmed fsck -r: rc=$RC; $(grep -E 'io_shim|pread|pwrite' <<<"$OUT" | tr '\n' ';')"
SH_LINE="$(grep '^io_shim:' <<<"$OUT" | tail -1)"
case "$SH_LINE" in
*"eintr_r=1"*) ;;
*) fail "setup: the shim never reached the BG table ($SH_LINE) -- nothing was tested"; ct_exit ;;
esac
if [ "$RC" -le 1 ]; then
    pass "the shimmed repair ran to completion (rc $RC)"
    case "$SH_LINE" in
    *"eintr_w=1"*) pass "setup: its BG table write was interrupted and split too ($SH_LINE)" ;;
    *) fail "setup: the repair wrote no BG descriptor through the shim ($SH_LINE)"; ct_exit ;;
    esac
else
    fail "the shimmed repair stopped (rc $RC): $(grep -vE '^io_shim' <<<"$OUT" | grep -iE 'pread|pwrite|interrupt' | head -2)"
    ct_exit
fi
ct_fsck "$DEV" >/dev/null 2>&1 && pass "and the volume is clean afterwards" ||
    fail "fsck after the shimmed repair: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
[ "$("$BG_POKE" "$DEV" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9][0-9]*\).*/\1/p')" = "$BASE" ] &&
    pass "the repaired count is whole, not half-written" ||
    fail "the repaired descriptor reads $("$BG_POKE" "$DEV" 0 --dump)"

# A write that makes no progress and sets no errno: the repair must stop
# and say what happened, not print "pwrite (repair): Success".
"$BG_POKE" "$DEV" 0 $((BASE - 64)) >/dev/null
blockdev --flushbufs "$DEV"
OUT="$(SHIM_ZERO_W=1 SHIM_LO=$LO SHIM_HI=$HI LD_PRELOAD="$SHIM" "$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
log "zero-progress fsck -r: rc=$RC; $(grep -iE 'pwrite' <<<"$OUT" | tr '\n' ';')"
grep -q "pwrite (repair)" <<<"$OUT" || { fail "setup: the repair never reached the zero-progress write (rc $RC)"; ct_exit; }
[ "$RC" -gt 1 ] && pass "a write that wrote nothing stops the repair (rc $RC)" ||
    fail "a write that wrote nothing was accepted (rc $RC)"
grep -q "pwrite (repair): wrote nothing at offset" <<<"$OUT" && ! grep -q "Success" <<<"$OUT" &&
    pass "and it is reported as no progress, not \"Success\"" ||
    fail "a zero-progress write was reported as: $(grep 'pwrite (repair)' <<<"$OUT" | head -1)"
ct_exit
