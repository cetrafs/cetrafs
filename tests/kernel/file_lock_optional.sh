#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the cross-node exclusive open lock is optional: the nofilelock mount option
#
# On by default (file_lock.sh proves the default behaviour). A datastore
# whose upper layer coordinates sharing itself -- Proxmox/qemu LIVE migration,
# which must open the image on BOTH nodes during the handoff -- gets -ETXTBSY
# from the exclusive lock and cannot migrate. `mount -o nofilelock` turns the
# lock off: this node claims nothing and refuses no open; the caller owns
# "don't double-write". Mount-time only, status in procfs, defrag forced off.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 flopt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt flopt)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo "victim content" >"$MNT/victim"
INO="$(stat -c '%i' "$MNT/victim")"

grep -q '^file_lock: on$' "/proc/fs/cetrafs/$PROC_DEV/info" &&
    pass "default mount: procfs reports file_lock: on" ||
    fail "default mount: procfs did not report file_lock on ($(grep file_lock "/proc/fs/cetrafs/$PROC_DEV/info"))"
ct_umount "$MNT"

# A LIVE foreign exclusive lock on victim (owner = node 1), the same setup
# file_lock.sh uses: the node row is poked alive AFTER the mount (poking it
# before would trip the no-CAW mount gate's live-peer watch).
"$LOCK_POKE" "$DEV" "$INO" 1 1 >/dev/null   # owner node 1, EXCLUSIVE

log "default (lock on): a live foreign lock refuses the open -- the migration blocker"
mount -t cetrafs "$DEV" "$MNT"
"$NODE_POKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null
if cat "$MNT/victim" >/dev/null 2>&1; then
    fail "default: open of a foreign-locked file succeeded -- the lock is not enforced"
else
    pass "default: open of a foreign-locked file is rejected (this is what breaks live migration)"
fi
ct_umount "$MNT"
"$NODE_POKE" "$DEV" 1 0 bb 0 >/dev/null   # peer departs so the next mount gate does not wait a window

# What nofilelock turns off is the AUTOMATIC lock on open, NOT enforcement
# of a lock that is actually present -- a present lock is still honored in
# both modes (that is what makes the userspace explicit lock,
# flock(LOCK_EX), work cross-node; see file_explicit_lock.sh). A real live
# migration has NO lock on the image, so clear the poked one and test the
# case migration actually hits: an UNLOCKED file opens on both nodes, and a
# write-open does not auto-claim a lock.
"$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null   # clear the lock -> NONE
log "nofilelock: an unlocked file open-migrates, and a write-open claims NO lock (auto-claim off)"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
grep -q '^file_lock: off$' "/proc/fs/cetrafs/$PROC_DEV/info" &&
    pass "nofilelock mount: procfs reports file_lock: off" ||
    fail "nofilelock mount: procfs did not report file_lock off"
# ...and the standard place an operator looks. Without ->show_options the
# VFS prints only its own generic flags and NO cetrafs option ever
# appears, so /proc/mounts could not distinguish a lock-off node from a
# lock-on one -- on a cluster, the difference between "a peer cannot open
# this image" and "it can". The mode shown is the EFFECTIVE one, which on
# a joined cluster may be inherited rather than requested.
grep "$MNT " /proc/mounts | grep -q nofilelock &&
    pass "nofilelock mount: /proc/mounts shows it too" ||
    fail "nofilelock mount: /proc/mounts does not mention it: $(grep "$MNT " /proc/mounts)"
GOT="$(cat "$MNT/victim" 2>/dev/null || true)"
[ "$GOT" = "victim content" ] &&
    pass "nofilelock: an unlocked file opens for READ" ||
    fail "nofilelock: read blocked or wrong content: '$GOT'"
# The write-open is the one live migration actually needs. Hold it open and
# confirm it claimed no on-disk lock -- the discriminating difference from a
# default mount, which would show EXCLUSIVE here.
if exec 9>>"$MNT/victim"; then
    pass "nofilelock: WRITE-open of an unlocked file succeeds (the migration handoff case)"
    D="$("$LOCK_POKE" "$DEV" "$INO")"
    echo "$D" | grep -q 'mode=0' &&
        pass "nofilelock: the held write-open auto-claimed NO lock ($D)" ||
        fail "nofilelock: a write-open auto-claimed a lock under nofilelock ($D)"
    exec 9>&-
else
    fail "nofilelock: write-open of an unlocked file was rejected"
fi
ct_umount "$MNT"

log "with the lock off, the defragmenter is forced off (its safety rests on the lock)"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
: >"$MNT/df"
DOUT="$("$ROOT/userspace/defrag.cetra" "$MNT/df" 2>&1 || true)"
echo "$DOUT" | grep -qiE "not supported|disabled" &&
    pass "nofilelock: the defrag ioctl is declined (${DOUT#*: })" ||
    fail "nofilelock: defrag was not declined: $DOUT"
ct_umount "$MNT"

# Clear the poked claim so the volume is pristine, and prove a plain default
# mount still enforces the lock (the option really is per-mount, not sticky).
"$LOCK_POKE" "$DEV" "$INO" 65535 0 >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"
ct_exit
