#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a read-only mount follows the cluster's file-lock mode and never sets it
#
# The first mounter's row sets the cluster's file-lock mode; every node
# after it inherits it, and a nofilelock mount against a lock-on cluster
# is refused. A read-only mount advertised its mode like a writer, so an
# observer mounted first fixed the cluster at file_lock=on and refused
# every nofilelock writer after it (audit 2026-11-15 BM-42). Now:
#   1. a read-only mount with no peer advertises no mode (row mode 0),
#      and says it sets none;
#   2. a read-only mount still follows an established mode (inherits off);
#   3. a read-write mount still leads (row mode 1).
#
# DISCRIMINATION: ro_mount_leads=1 -- the read-only mount's row says 1,
# the mode every later mounter would inherit.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_mode_own # mounts with its own options
NPOKE="$(ct_helper node_poke)"
IMG="$(ct_image 560 rolead)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rolead)"
ct_track mnt "$MNT"
ct_param_set ro_mount_leads 0
ct_param_set force_cluster_flock_mode -1
ct_mkfs_small "$DEV" >/dev/null
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# <opts> -> RES: "mode=<own row's advertised mode> lock=<info file_lock>"
round() {
    local me
    mount -t cetrafs -o "$1" "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    me="$(info this_node_id)"
    RES="mode=$(field mode "$("$NPOKE" "$DEV" "$me")") lock=$(info file_lock)"
    umount "$MNT"
}

MARK="$(dmesg_mark)"
round ro
R1="$RES"
log "1: ro, no peer: $R1"
[ "$(field mode "$R1")" = 0 ] && dmesg_since "$MARK" | grep -q "read-only, so this node sets no mode" &&
    pass "1: a read-only first mounter advertises no mode, and says so ($R1)" || fail "1: $R1"

ct_param_set force_cluster_flock_mode 2
round ro
R2="$RES"
ct_param_set force_cluster_flock_mode -1
[ "$(field lock "$R2")" = off ] && [ "$(field mode "$R2")" = 0 ] &&
    pass "2: a read-only mount follows an established mode and still advertises none ($R2)" || fail "2: $R2"

round rw
R3="$RES"
[ "$(field mode "$R3")" = 1 ] && pass "3: a read-write first mounter still leads ($R3)" || fail "3: $R3"

ct_param_set ro_mount_leads 1
round ro
C="$RES"
ct_param_set ro_mount_leads 0
[ "$(field mode "$C")" = 1 ] && pass "control: as before, the read-only mount's row set the mode ($C)" ||
    fail "control: $C -- the suite does not reach the advertised mode"
ct_exit
