#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two machines with one identity registering at the same time do not become one node
#
# node_uuid_twin.sh covers a twin that is ALREADY mounted: its row beats
# while the newcomer watches. Two clones of one VM booting together never
# meet that check:
#
#  D. the row was left cleanly (last_seen 0), so neither watches; both
#     re-attached to the same row by a CAS that only asked "is it still
#     ours?" -- and it is, for both;
#  E. no row carried the identity yet; each claimed its own free row,
#     and every later check skips rows with our own UUID.
#
# Either way two machines ran as one node: the same Zone Groups, locks
# and journal. The race is played by register_twin_race, which lands the
# twin's re-attach or claim inside this mount's registration.
#
# DISCRIMINATION: proven 2026-11-05 with the re-attach's hb_seq check and
# the post-claim twin scan removed: both D and E mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
# The twin left row 1 registered in E; the control's mkfs then sees a
# live-looking row and watches it for the longest stale window a node may
# use (240 s, devutil.h) -- not what this suite tests;
# tool_probe_stale_window.sh tests that.
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
[ -w /sys/module/cetrafs/parameters/register_twin_race ] || { skip "register_twin_race is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 uuidrace)"
MNT="$(ct_mnt uuidrace)"
compress_timing

try_mount() { # <label> -> refused?
    local mark rc=0
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] && grep -q "another machine is registering" <<<"$(dmesg_since "$mark")"; then
        pass "$1: the mount was refused, naming the twin"
    else
        [ "$rc" = 0 ] && umount "$MNT"
        fail "$1: mount rc=$rc -- two machines with one identity registered as one node"
    fi
}

log "D: row left cleanly; the twin re-attaches between our scan and our swap"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
grep -q '^state=1 .*last_seen=0 ' <<<"$("$NODE_POKE" "$DEV" 0)" ||
    { fail "setup: row 0 was not left cleanly: $("$NODE_POKE" "$DEV" 0)"; ct_exit; }
pass "setup: row 0 is ours, left cleanly"
ct_param_set register_twin_race 1
try_mount D
ct_param_set register_twin_race 0

log "E: no row yet; the twin claims its own row just after ours"
ct_mkfs_small "$DEV" >/dev/null
grep -q '^state=0 ' <<<"$("$NODE_POKE" "$DEV" 0)" ||
    { fail "setup: row 0 is not free after mkfs: $("$NODE_POKE" "$DEV" 0)"; ct_exit; }
ct_param_set register_twin_race 1
try_mount E
ct_param_set register_twin_race 0
R0="$("$NODE_POKE" "$DEV" 0)"
R1="$("$NODE_POKE" "$DEV" 1)"
grep -q '^state=1 ' <<<"$R1" && pass "E: setup: the twin holds row 1" ||
    fail "E: setup: the twin's claim did not land: row 1: $R1"
grep -q '^state=0 ' <<<"$R0" && pass "E: the refused mount gave its own row back" ||
    fail "E: the refused mount left its row registered: row 0: $R0"

log "control: no twin -- a fresh volume mounts"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
pass "control: mounted"
ct_umount "$MNT"
ct_exit
