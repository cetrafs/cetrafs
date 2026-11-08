#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a process killed while its CAS waits for a multipath path resolution dies at once
#
# On a dm multipath volume each COMPARE AND WRITE goes down a SCSI path
# under the dm node (dmpath.c). When another caller is already resolving
# one, the next waits for its answer -- up to 15 s -- and that wait was
# not killable: a process killed there hung on until the resolution
# ended. Now a CAS waits killably and, interrupted, returns -EINTR having
# issued nothing, which its caller handles as any command that did not
# happen. The give-backs that undo a reclaim (cetrafs_cas_record_nointr())
# still wait it out: abandoning one stops the mount.
#
# Staged on two LIO loopback disks under a dm multipath map, a real CAW:
#   caw_fail_path_once makes the next CAW report a timeout, which evicts
#   the cached path; dmpath_resolve_delay_ms makes the re-resolution take
#   8 s. Process A creates a file and becomes the resolver; process B
#   touches another file, its CAS waits on A's resolution, and B is
#   killed.
#   the check: B is gone within 2 s of the kill; A's create succeeds; the
#   mount did not stop; fsck is clean.
#
# DISCRIMINATION: with the wait not killable, B outlives the kill until
# A's resolution ends, about 6 s later.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
for p in caw_fail_path_once dmpath_resolve_delay_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done

IMG="$(ct_image 600 dmkill)"
DISKS="$(ct_lio_disks "$IMG" 2)" || { skip "no LIO loopback target here"; ct_exit; }
set -- $DISKS
[ $# -eq 2 ] || { fail "setup: expected two paths, got '$DISKS'"; ct_exit; }
D1="$1"; D2="$2"
NAME="ctdmkill$$"
SECTORS="$(blockdev --getsz "$D1")"
M1="$(lsblk -dno MAJ:MIN "$D1" | tr -d ' ')"
M2="$(lsblk -dno MAJ:MIN "$D2" | tr -d ' ')"
dmsetup create "$NAME" --table "0 $SECTORS multipath 0 0 1 1 round-robin 0 2 1 $M1 1000 $M2 1000" ||
    { skip "dm-multipath is not available"; ct_exit; }
ct_track dm "$NAME"
DEV="/dev/mapper/$NAME"
udevadm settle 2>/dev/null || true
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
MNT="$(ct_mnt dmkill)"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -q "dm path: .* sending COMPARE AND WRITE via" ||
    { fail "setup: the mount found no CAW path"; ct_exit; }
ct_param_set scrub 0
mkdir "$MNT/a" "$MNT/b"
: >"$MNT/b/existing"
sync

MARK="$(dmesg_mark)"
ct_param_set dmpath_resolve_delay_ms 8000
ct_param_set caw_fail_path_once 1
: >"$MNT/a/created" &
AP=$!
sleep 1.5
touch -d '2020-01-01' "$MNT/b/existing" &
BP=$!
sleep 1.5
kill -0 "$BP" 2>/dev/null ||
    { wait "$AP" || true; ct_param_set dmpath_resolve_delay_ms 0; ct_param_set caw_fail_path_once 0
      fail "setup: B finished before the kill -- it never waited on A's resolution"; ct_exit; }
T0="$(date +%s.%N)"
kill -9 "$BP"
wait "$BP" 2>/dev/null || true
T1="$(date +%s.%N)"
DT="$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%.1f", b - a }')"
wait "$AP" && AR=0 || AR=$?
ct_param_set dmpath_resolve_delay_ms 0
ct_param_set caw_fail_path_once 0
dmesg_since "$MARK" | grep -q 'dm path: .* sending COMPARE AND WRITE via' &&
    pass "setup: the path was evicted and re-resolved while B waited" ||
    fail "setup: no re-resolution happened (the injected path failure did not fire)"
awk -v t="$DT" 'BEGIN { exit !(t < 2.0) }' && pass "the killed process was gone ${DT}s after the kill" ||
    fail "the killed process outlived the kill by ${DT}s -- it waited out the resolution"
[ "$AR" = 0 ] && [ -e "$MNT/a/created" ] && pass "the resolver's own create succeeded" ||
    fail "the resolver's create failed (rc $AR)"
dmesg_since "$MARK" | grep -q 'STOPPED' && fail "the mount stopped: $(dmesg_since "$MARK" | grep -m1 STOPPED)" ||
    pass "the mount did not stop"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
