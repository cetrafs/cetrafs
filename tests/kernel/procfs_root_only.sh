#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# procfs info and cluster, which read the device on every read, are root's
#
# Every read of info or cluster does uncached device reads (descriptor
# sweeps, registry rows), and both were world-readable: an unprivileged
# loop reading them generated steady SAN I/O (audit 2026-11-14 L6). They
# are now 0400; properties, computed in memory, stays readable.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v setpriv >/dev/null || { skip "setpriv is missing"; ct_exit; }
DEV="$(ct_loop "$(ct_image 560 prr)")"
MNT="$(ct_mnt prr)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
PD="$(ct_procdir "$DEV")"
asnobody() { setpriv --reuid=65534 --regid=65534 --clear-groups cat "$1" >/dev/null 2>&1; }
for f in info cluster; do
    [ -n "$(cat "$PD/$f")" ] || fail "setup: root cannot read $f"
    asnobody "$PD/$f" && fail "$f is readable by an unprivileged user" ||
        pass "$f is refused to an unprivileged user"
done
asnobody "$PD/properties" && pass "properties stays readable by everyone" ||
    fail "properties is refused to an unprivileged user"
ct_umount "$MNT"
ct_exit
