#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck judges the device, not this machine's stale page cache of it
#
# fsck reads through the block device's page cache, and only the
# live-peer probe ever dropped it -- when a registry row existed. With
# the device held open by anyone else (multipathd, udev, a tool), the
# cache outlives the last close, and a peer's writes since it filled
# are invisible: fsck examined the volume as it had been (audit
# 2026-11-11 F7).
#
# The rig: hold the loop device open (fd 7) and fill its cache with a
# clean volume; then damage Zone Group 0 in the BACKING FILE, which a
# peer's write is to this machine's cache -- the device has it, the
# cache does not.
#
#  1. fsck reports the damage and exits nonzero.
#
# DISCRIMINATION (2026-11-11, fsck.c before this fix): 1 reads the
# cached clean block and exits 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"
unset CETRAFS_PEER_PROBE_SECS

IMG="$(ct_image 560 fsckdev)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the fresh volume is not clean"; ct_exit; }
ZGT="$("$SBPOKE" "$IMG" | sed -n 's/^zg_table_start=//p')"
[ -n "$ZGT" ] || { fail "setup: sb_poke prints no zg_table_start"; ct_exit; }

exec 7<"$DEV"
dd if="$DEV" of=/dev/null bs=1M count=64 status=none
dd if=/dev/zero bs=4096 count=1 seek="$ZGT" of="$IMG" conv=notrunc,fsync status=none
[ "$(dd if="$DEV" bs=4096 skip="$ZGT" count=1 status=none | tr -d '\0' | wc -c)" != 0 ] ||
    { fail "setup: the cache did not keep the clean ZG block (nothing to be stale)"; ct_exit; }
[ "$(dd if="$DEV" bs=4096 skip="$ZGT" count=1 iflag=direct status=none | tr -d '\0' | wc -c)" = 0 ] ||
    { fail "setup: the device does not have the damage"; ct_exit; }
pass "setup: the cache holds the clean ZG 0, the device the zeroed one"

rc=0; OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || rc=$?
[ "$rc" != 0 ] && grep -q "ZG" <<<"$OUT" && pass "1: fsck reports the zeroed ZG (exit $rc)" ||
    fail "1: fsck exit $rc, judged the cached copy: $(tail -1 <<<"$OUT")"
exec 7<&-
losetup -d "$DEV"
ct_exit
