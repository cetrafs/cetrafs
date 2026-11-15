#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a failed release of this node's own replayed area is not left stale for the mount's life
#
# The mount replays this node's own journal area and parks it CLEAN with
# one swap that also drops the replay claim. A failed swap was queued
# for the heartbeat -- and the mount read the area's park_seq right
# after, still the claimed one. When the retry landed the area was one
# park later, and every DIRTY flip of the session failed -ESTALE: create,
# unlink, rename, every tree boundary, for as long as the node kept
# beating (audit 2026-11-14 B-5). The release is now retried at attach,
# and a mount whose own area cannot be parked fails.
#
# Staged: an entry planted in this node's own area, the release failing
# once (journal_release_fail_once), a remount.
#   setup: the mount replayed the entry and the release failed once;
#   1. the mount succeeded;
#   2. after two heartbeats, creates, writes and fsyncs succeed, and the
#      journal never reports its area parked by someone else.
#
# DISCRIMINATION: journal_attach_release_async=1 (the old hand-off to the
# heartbeat): 2 fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_release_fail_once journal_attach_release_async; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
MNT="$(ct_mnt jrown)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set journal_release_fail_once 0
ct_param_set journal_attach_release_async 0

# <async 0|1> -> "failed=<0|1> mounted=<0|1> ops=<ok|errno> stale=<0|1>"
round() {
    local img dev nid pay mark failed=0 mounted=0 ops stale=0
    img="$(ct_image 560 "jrown$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    nid="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info")"
    ct_umount "$MNT"
    pay="$(ct_tmp jrown-pay)"; head -c 4096 /dev/zero >"$pay"
    "$JPOKE" "$img" "$nid" 0 60001 "$pay" >/dev/null 2>&1
    echo "$1" >/sys/module/cetrafs/parameters/journal_attach_release_async
    echo 1 >/sys/module/cetrafs/parameters/journal_release_fail_once
    mark="$(dmesg_mark)"
    mount -t cetrafs "$dev" "$MNT" 2>/dev/null && mounted=1
    echo 0 >/sys/module/cetrafs/parameters/journal_release_fail_once
    dmesg_since "$mark" | grep -q "failed to release the replay claim.*node $nid" && failed=1
    if [ "$mounted" = 1 ]; then
        sleep 5 # two heartbeats: a queued release has landed by now
        ops="$(python3 -I - "$MNT" <<'PY'
import os, sys, errno
d = sys.argv[1]
try:
    os.mkdir(os.path.join(d, "dir"))
    for i in range(20):
        fd = os.open(os.path.join(d, "dir", "f%d" % i), os.O_CREAT | os.O_WRONLY, 0o644)
        os.write(fd, os.urandom(8192))
        os.fsync(fd)
        os.close(fd)
    os.rename(os.path.join(d, "dir", "f0"), os.path.join(d, "g0"))
    os.unlink(os.path.join(d, "dir", "f1"))
    print("ok")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
PY
)"
        dmesg_since "$mark" | grep -q "parked by a peer since this session began" && stale=1
        umount "$MNT" 2>/dev/null || umount -l "$MNT"
    else
        ops=nomount
    fi
    echo 0 >/sys/module/cetrafs/parameters/journal_attach_release_async
    echo "failed=$failed mounted=$mounted ops=$ops stale=$stale"
}
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "retried at attach: $R"
C="$(round 1)"
log "control (left to the heartbeat): $C"
[ "$(get failed "$R")" = 1 ] && [ "$(get failed "$C")" = 1 ] ||
    { fail "setup: the own-area release never failed ($R | $C)"; ct_exit; }
pass "setup: the replay's release of the own area failed once"
[ "$(get mounted "$R")" = 1 ] && pass "1: the mount succeeded" || fail "1: the mount failed ($R)"
[ "$(get ops "$R")" = ok ] && [ "$(get stale "$R")" = 0 ] &&
    pass "2: creates, writes, fsyncs, rename and unlink all succeed" || fail "2: $R"
{ [ "$(get ops "$C")" != ok ] || [ "$(get stale "$C")" = 1 ]; } &&
    pass "control: left to the heartbeat, the session's journal flips fail ($(get ops "$C"))" ||
    fail "control: left to the heartbeat, nothing failed -- the suite does not reach the stale park_seq ($C)"
ct_exit
