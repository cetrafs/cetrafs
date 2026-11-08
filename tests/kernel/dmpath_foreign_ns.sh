#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a multipath volume finds its COMPARE AND WRITE path whatever /sys the mounter sees
#
# On a dm node the CAW goes down one SCSI path underneath it, found by
# walking /sys/block/<dm>/slaves (dmpath.c). That walk opened its paths
# through the calling task's root, mount namespace and credentials (audit
# L31): a mount from a namespace whose /sys is not the host's -- a
# container, a chroot, an initramfs stage -- found no slaves, and the
# probe reported no CAW at all. Now the walk starts at init's root under
# kernel credentials.
#
# Staged: two LIO loopback disks over one image, a dm multipath map over
# them, mounted from a private mount namespace with /sys unmounted.
#
# DISCRIMINATION: the setup check requires the host-namespace mount to
# resolve a path first. With filp_open() restored the namespace mount
# resolves no CAW path (run 2026-11-08).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm_multipath 2>/dev/null || true
command -v unshare >/dev/null || { skip "unshare is not installed"; ct_exit; }

IMG="$(ct_image 600 dmns)"
DISKS="$(ct_lio_disks "$IMG" 2)" || { skip "no LIO loopback target here"; ct_exit; }
set -- $DISKS
[ $# -eq 2 ] || { fail "setup: expected two paths, got '$DISKS'"; ct_exit; }
D1="$1"; D2="$2"
NAME="ctdmns$$"
SECTORS="$(blockdev --getsz "$D1")"
M1="$(lsblk -dno MAJ:MIN "$D1" | tr -d ' ')"
M2="$(lsblk -dno MAJ:MIN "$D2" | tr -d ' ')"
dmsetup create "$NAME" --table "0 $SECTORS multipath 0 0 1 1 round-robin 0 2 1 $M1 1000 $M2 1000" ||
    { skip "dm-multipath is not available"; ct_exit; }
ct_track dm "$NAME"
DEV="/dev/mapper/$NAME"
udevadm settle 2>/dev/null || true
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -M 4 -N 1024 -f >/dev/null
MNT="$(ct_mnt dmns)"

# Host namespace first: proves the map resolves at all.
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
dmesg_since "$MARK" | grep -q "dm path: .* sending COMPARE AND WRITE via" ||
    { fail "setup: even the host-namespace mount found no CAW path: $(dmesg_since "$MARK" | grep -m2 -i 'caw\|dm path')"; ct_exit; }

# Unmount released the cached path (cetrafs_dmpath_forget()), so the
# namespace mount resolves from scratch.
MARK="$(dmesg_mark)"
OUT="$(unshare -m --propagation private sh -c "
    umount -l /sys || exit 3
    [ -e /sys/block ] && exit 4
    mount -t cetrafs '$DEV' '$MNT' || exit 5
    umount '$MNT'
" 2>&1)" && RC=0 || RC=$?
log "namespace mount: rc=$RC $OUT"
[ "$RC" = 3 ] || [ "$RC" = 4 ] && { fail "setup: could not hide /sys in the namespace (rc $RC)"; ct_exit; }
[ "$RC" = 0 ] && pass "a mount from a namespace with no /sys succeeds" || fail "the namespace mount failed (rc $RC): $OUT"
dmesg_since "$MARK" | grep -q "dm path: .* sending COMPARE AND WRITE via" &&
    pass "and it found the CAW path under the dm node" ||
    fail "the namespace mount resolved no CAW path: $(dmesg_since "$MARK" | grep -m2 -i 'caw\|dm path')"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
