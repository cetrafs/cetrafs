#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mounted node advertises the stale window it is running in its registry row, and keeps it current
#
# The tools (mkfs, fsck, growfs) wait as long as the most patient live
# node before calling a registered row gone, and they learn that window
# from the row itself (cetrafs_node_entry_t.stale_secs, format 0x000A).
# That only works if the node writes it at registration and re-writes
# it when an operator changes stale_secs at runtime (procfs controls).
#
#  A. after mount the row carries the mount's stale_secs.
#  B. after `stale_secs=60` in controls, the next beats carry 60.
#
# DISCRIMINATION: without the kernel writing the field the row reads 0
# in A and B (checked 2026-11-10 by dropping the three writes in node.c).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 rowstale)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rowstale)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2 # read at mount
ct_mkfs_small "$DEV" -N 2048 >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="$(ct_procdir "$DEV")/controls"
ROW="$(sed -n 's/^node \([0-9]*\): .*(this node)$/\1/p' "$(ct_procdir "$DEV")/cluster")"
[ -n "$ROW" ] || { fail "setup: could not find this node's row"; ct_exit; }

row_stale() { blockdev --flushbufs "$DEV"; "$NPOKE" "$IMG" "$ROW" | sed -n 's/.* stale_secs=\([0-9]*\)$/\1/p'; }
mine() { sed -n 's/^stale_secs: //p' "$(ct_procdir "$DEV")/controls"; }

# ------------------------------------------------------------------- A
log "A: the row carries the mount's stale_secs"
S0="$(mine)"
[ -n "$S0" ] || { fail "setup: controls shows no stale_secs"; ct_exit; }
[ "$(row_stale)" = "$S0" ] && pass "A: row $ROW advertises $S0 s, the mount's window" ||
    fail "A: row $ROW advertises '$(row_stale)', the mount runs $S0"

# ------------------------------------------------------------------- B
log "B: a runtime change reaches the row on the next beats"
echo "stale_secs=60" >"$CTL"
[ "$(mine)" = 60 ] || { fail "setup: controls did not take stale_secs=60 (controls: $(mine))"; ct_exit; }
GOT=""
for _ in $(seq 1 10); do
    GOT="$(row_stale)"
    [ "$GOT" = 60 ] && break
    sleep 1
done
[ "$GOT" = 60 ] && pass "B: the row now advertises 60 s" || fail "B: the row still advertises '$GOT' after 10 s"

ct_umount "$MNT"
ct_exit
