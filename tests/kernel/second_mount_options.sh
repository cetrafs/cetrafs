#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount never silently runs without what it asked for
#
# A. A second mount of a device that is already mounted gets the first
#    mount's superblock, and its own options were dropped without a word:
#    `-o nofilelock`, `errors=panic`, `corruption=stop` all accepted and
#    none in force (audit L29). One that STATES an option the mount does
#    not have is now refused, as the VFS refuses one that disagrees about
#    read-only; one that agrees, or states nothing, still mounts. A
#    remount cannot apply them either, and now says so.
# B. The per-peer liveness watch is allocated at mount; its allocation
#    failing was accepted, and every peer then read "cannot judge, assume
#    alive" for the life of the mount -- no dead peer ever reclaimed, and
#    nothing said so (L30). The mount now fails instead.
#
# DISCRIMINATION: against the old code A's disagreeing mounts succeed and
# B mounts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fill_fail_peers_alloc ] || { skip "fill_fail_peers_alloc is missing"; ct_exit; }

DEV="$(ct_dev 560 secmnt)"
M1="$(ct_mnt secmnt1)"
M2="$(ct_mnt secmnt2)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$M1"
ct_track mnt "$M2"
ct_mount "$DEV" "$M1"
require_cetrafs_mount "$M1"

second() { # <opts>: 0 if a second mount with <opts> succeeded (and is undone)
    if mount -t cetrafs ${1:+-o "$1"} "$DEV" "$M2" 2>/dev/null; then
        umount "$M2"
        return 0
    fi
    return 1
}

second "" && pass "A: a second mount asking for nothing different mounts" ||
    fail "A: a plain second mount was refused -- the check is too strict"
for o in nofilelock errors=panic corruption=stop; do
    MARK="$(dmesg_mark)"
    if second "$o"; then
        fail "A: a second mount with -o $o succeeded, and the option is not in force"
    else
        dmesg_since "$MARK" | grep -q "already mounted without $o" &&
            pass "A: a second mount with -o $o is refused, and says why" ||
            fail "A: -o $o was refused without the reason"
    fi
done
ct_umount "$M1"

# The other way round: first mounted nofilelock, second asks for the default.
mount -t cetrafs -o nofilelock "$DEV" "$M1"
second "nofilelock" && pass "A: a second nofilelock mount of a nofilelock mount mounts" ||
    fail "A: a matching nofilelock second mount was refused"
second "" && pass "A: a second mount stating nothing mounts on a nofilelock mount" ||
    fail "A: a second mount that asked for nothing was refused"
ct_umount "$M1"
mount -t cetrafs -o errors=panic "$DEV" "$M1"
second "errors=stop" && fail "A: errors=stop was accepted on an errors=panic mount" ||
    pass "A: a second mount stating errors=stop on an errors=panic mount is refused"
MARK="$(dmesg_mark)"
mount -o remount,corruption=stop "$M1" 2>/dev/null || true
dmesg_since "$MARK" | grep -q "remount asked for corruption=stop, which is fixed at mount time" &&
    pass "A: a remount stating an option it cannot apply says so" ||
    fail "A: a remount took corruption=stop in silence"
ct_umount "$M1"

ct_param_set fill_fail_peers_alloc 1
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$M1" 2>/dev/null; then
    ct_param_set fill_fail_peers_alloc 0
    umount "$M1"
    fail "B: the mount went on without its peer liveness watch"
else
    ct_param_set fill_fail_peers_alloc 0
    pass "B: a mount whose peer liveness watch cannot be allocated is refused"
fi
ct_mount "$DEV" "$M1"
require_cetrafs_mount "$M1"
pass "B: and the volume mounts normally afterwards"
ct_umount "$M1"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
