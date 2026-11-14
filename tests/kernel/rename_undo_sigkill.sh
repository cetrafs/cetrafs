#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a SIGKILL during a directory rename never leaves the directory unnamed
#
# A directory moving to another parent loses its old name first, then
# gains the new one; if the new one fails, the old one is given back.
# The directory scans became killable (audit 2026-11-14 RT-3), and the
# give-back runs through the same scans: a SIGKILL that stopped the
# forward add stopped the give-back as well, and the directory was left
# with no name until fsck (re-audit of the fixes, 2026-11-14). The
# give-back now ignores a pending fatal signal.
#
# `mv src/d dst/` is held after the old name is removed (ns_step_gap_ms)
# and killed there; the forward add then sees the signal and fails:
#   1. the rename failed (the process was killed);
#   2. src/d is still there, with its contents; dst/d is not;
#   3. fsck is clean.
#
# DISCRIMINATION: rename_undo_killable lets the signal stop the give-back
# too, as before; d then has no name and fsck finds it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in rename_undo_killable ns_step_gap_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt rus)"
ct_track mnt "$MNT"
ct_param_set rename_undo_killable 0
ct_param_set ns_step_gap_ms 0
P=/sys/module/cetrafs/parameters

# <killable 0|1> -> "<src/d present yes|no> <dst/d present yes|no> <payload ok|bad|-> <fsck ok|bad>"
probe() {
    local img dev pid src dst pay ok
    img="$(ct_image 560 "rus$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir -p "$MNT/src/d" "$MNT/dst"
    echo payload >"$MNT/src/d/f"
    sync
    echo "$1" >$P/rename_undo_killable
    echo 2000 >$P/ns_step_gap_ms
    python3 -c 'import os,sys; os.rename(sys.argv[1], sys.argv[2])' "$MNT/src/d" "$MNT/dst/d" 2>/dev/null &
    pid=$!
    sleep 0.7
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo 0 >$P/ns_step_gap_ms
    echo 0 >$P/rename_undo_killable
    [ -d "$MNT/src/d" ] && src=yes || src=no
    [ -d "$MNT/dst/d" ] && dst=yes || dst=no
    if [ "$src" = yes ]; then pay="$(cat "$MNT/src/d/f" 2>/dev/null || echo bad)"; else pay=-; fi
    [ "$pay" = payload ] && pay=ok
    ct_umount "$MNT" >/dev/null
    ct_fsck "$dev" >/dev/null 2>&1 && ok=ok || ok=bad
    echo "$src $dst $pay $ok"
}
read -r S D PAY OK <<<"$(probe 0)"
read -r S0 D0 PAY0 OK0 <<<"$(probe 1)"
log "fixed: src/d=$S dst/d=$D payload=$PAY fsck=$OK; give-back killable: src/d=$S0 dst/d=$D0 fsck=$OK0"
[ "$D" = no ] && pass "1: the killed rename did not complete" || fail "setup: the rename completed before the kill landed"
[ "$S" = yes ] && [ "$PAY" = ok ] && pass "2: the directory kept its old name and its contents" ||
    fail "2: the directory lost its name ($S, payload $PAY)"
[ "$OK" = ok ] && pass "3: fsck is clean" || fail "3: fsck is not clean"
[ "$S0" = no ] && [ "$D0" = no ] && pass "control: a killable give-back leaves it unnamed -- the suite discriminates" ||
    fail "control: src/d=$S0 dst/d=$D0 with a killable give-back -- the suite cannot tell"
ct_exit
