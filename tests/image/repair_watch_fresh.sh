#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair claim's heartbeat watch re-reads the registry past this host's cache
#
# fsck -r and growfs hold a registry claim (state REPAIR) and watch every
# other REGISTERED row for a beat. The watch's baseline is read when the
# claim is taken, and each tick compares the row to it. A peer on another
# host beats straight to the device, so this host sees the beat only if
# the tick's read is not served from this host's page cache. The tick
# read the cache, and every tick after the first saw the baseline forever:
# a node that got past the mount gate was never noticed, and the repair
# went on under a mounted volume (audit 2026-11-14 U1).
#
# The probe arms the watch through the device, so this host's cache holds
# the registry as it was. The peer's beat then reaches the backing file --
# the loop device's cache is not told, exactly as with a peer on another
# host -- and the tick must see it. The probe's own cached read is printed
# first as proof the cache really was stale.
#
# DISCRIMINATION: with the tick reading through the cache, the tick sees
# the cached hb_seq and reports no beat (watch_beat=0).
#
# No kernel module and nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NODE_POKE="$(ct_helper node_poke)"

# Built here, not through ct_helper: the property lives in devutil.h,
# which ct_helper's rebuild check does not look at.
PROBE="$(ct_tmp repairwatch-probe)"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$PROBE" "$CT_TESTS/helpers/repair_watch_probe.c" || { fail "setup: the probe does not build"; ct_exit; }

IMG="$(ct_image 560 repairwatch)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
"$NODE_POKE" "$IMG" 1 1 bb "$(date +%s)" >/dev/null
blockdev --flushbufs "$DEV"
grep -q '^state=1 ' <<<"$("$NODE_POKE" "$IMG" 1)" ||
    { fail "setup: row 1 was not planted as a registered node"; ct_exit; }

rc=0
OUT="$("$PROBE" "$DEV" "$IMG" 2>&1)" || rc=$?
log "probe: $OUT (rc $rc)"
[ "$rc" = 0 ] || { fail "setup: the probe failed (rc $rc)"; ct_exit; }
case "$OUT" in *cached_hb=1\ *) ;; *) fail "setup: the probe's first read was not the planted row ($OUT)"; ct_exit ;; esac
case "$OUT" in *watch_beat=1*) pass "the watch saw a peer's beat that reached the device past this host's cache" ;;
    *) fail "the watch did not see the peer's beat: the tick was served from this host's cache ($OUT)" ;; esac

ct_exit
