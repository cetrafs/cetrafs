#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a main-line lease renewal is never interleaved with the timer's
#
# fsck -r and growfs renew their registry claim from the work loop AND
# from a SIGALRM timer, through the same cetrafs_repair_renew() and the
# same static CAW buffer. A tick landing between the main line's read
# and its CAW rewrote the row under it, the main CAW miscompared, and a
# long repair stopped with "this repair's registry claim was taken away"
# for nothing (audit 2026-11-05, N7). Fails safe, but kills the repair.
#
# The miscompare itself needs a device with COMPARE AND WRITE (only
# tests/device reaches one); what is checked here is the property that
# prevents it, with the tick delivered at the worst moment on demand:
# renew_mask_probe raises SIGALRM inside the renewal's own read, and the
# handler must not run until the renewal has returned.
#
# DISCRIMINATION: proven 2026-11-05 against the unmasked renewal: the
# handler runs inside it (inside=1).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

# Built here, not through ct_helper: the property lives in devutil.h,
# which ct_helper's rebuild check does not look at.
PROBE="$(ct_tmp renewmask-probe)"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$PROBE" "$CT_TESTS/helpers/renew_mask_probe.c" || { fail "setup: the probe does not build"; ct_exit; }
IMG="$(ct_image 560 renewmask)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" >/dev/null
rc=0
OUT="$("$PROBE" "$IMG")" || rc=$?
log "probe: $OUT (rc $rc)"
[ "$rc" = 0 ] || { fail "setup: the renewal never reached its read (rc $rc) -- nothing was probed"; ct_exit; }
case "$OUT" in *fired=1*) ;; *) fail "setup: the tick was never delivered ($OUT)"; ct_exit ;; esac
[ "$OUT" = "inside=0 fired=1" ] && pass "a tick raised inside a renewal waits until the renewal returns" ||
    fail "the timer's handler ran inside a main-line renewal ($OUT) -- the two share one CAW buffer"
ct_exit
