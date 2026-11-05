#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a read-only mount gives back the Zone Groups its node owned before
#
# Unmount leaves a node's Zone Groups owned by its departed row, for a
# peer to take; a crash leaves them owned by a dead one. When the same
# node then mounts READ-ONLY its row is live again, so no peer may take
# them -- and the observer neither allocates from them nor drains the
# frees peers queue against them. The capacity was out of the cluster
# for as long as it stayed mounted (audit L35). Now a read-only mount
# hands them back.
#
# DISCRIMINATION: without the hand-back the read-only mount's own procfs
# lists the Zone Groups as "(this node)".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 rdozg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rdozg)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/f" bs=1M count=4 conv=fsync status=none
INFO="$(ct_procdir "$DEV")/info"
OWNED="$(grep -c '(this node)' "$INFO" || true)"
[ "$OWNED" -ge 1 ] || { fail "setup: the read-write mount owns no Zone Group"; ct_exit; }
pass "setup: the read-write mount owns $OWNED Zone Group(s)"
ct_umount "$MNT"

mount -t cetrafs -o ro "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
N="$(grep -c '(this node)' "$INFO" || true)"
log "Zone Groups owned by this node under the read-only mount: $N"
[ "$N" = 0 ] && pass "the read-only mount handed back every Zone Group it owned" ||
    fail "the read-only mount still owns $N Zone Group(s): $(grep '(this node)' "$INFO" | tr '\n' ';')"
cmp -s <(head -c 4096 "$MNT/f") <(head -c 4096 /dev/zero) && pass "and the data is still readable" ||
    fail "the file no longer reads back"
dmesg | tail -20 | grep -q "handed back" && pass "and said so" || fail "no hand-back message"
ct_umount "$MNT"

# A read-write mount takes capacity again and the volume is clean.
ct_mount "$DEV" "$MNT"
dd if=/dev/zero of="$MNT/g" bs=1M count=1 conv=fsync status=none && pass "a read-write mount allocates again" ||
    fail "a read-write mount could not allocate after the hand-back"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
