#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs and the tools' mount check fail closed when they cannot see: an unreadable block 0, an unreadable mount table
#
# Two "cannot tell" answers were taken for "safe":
#   * mkfs without -f refuses a device that holds data, judged by
#     reading block 0 and a few after it. A FAILED read of block 0 fell
#     through to the scan, and the scan stopped at its first error, so a
#     device whose first blocks could not be read was "empty" and was
#     formatted. Now an unreadable block 0, or an I/O error in the scan,
#     is "not empty".
#   * mkfs, fsck and growfs refuse a device this system has mounted by
#     reading /proc/self/mounts. When that could not be opened they
#     carried on as if nothing was mounted. Now they refuse.
#
# DISCRIMINATION: without the changes, mkfs reports success on the
# device with an unreadable block 0 (it formats over it -- dm-error
# fails only reads of those sectors here), and the tools carry on with
# /proc hidden.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
command -v dmsetup >/dev/null 2>&1 || { skip "dmsetup not available"; ct_exit; }
command -v unshare >/dev/null 2>&1 || { skip "unshare not available"; ct_exit; }
MKFS="$ROOT/userspace/mkfs.cetra"

log "1: block 0 cannot be read"
IMG="$(ct_image 560 mkfsr)"
LOOP="$(ct_loop "$IMG")"
dd if=/dev/urandom of="$LOOP" bs=4096 count=1 seek=0 conv=notrunc status=none # data the operator wants kept
SECT=$(blockdev --getsz "$LOOP")
NAME="ctmkfsr$$"
# Reads of block 0 fail; everything else maps through. Writes to block 0
# fail too, so mkfs cannot succeed by accident on that sector -- what is
# asserted is that it REFUSES, with the non-empty message, before trying.
dmsetup create "$NAME" --table "0 8 error
8 $((SECT - 8)) linear $LOOP 8"
ct_track dm "$NAME"
OUT="$("$MKFS" "/dev/mapper/$NAME" 2>&1)" && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q "Refusing to format non-empty device" <<<"$OUT" &&
    pass "1: mkfs refuses a device whose block 0 it cannot read" ||
    fail "1: rc=$RC: $(tail -2 <<<"$OUT" | tr '\n' ' ')"

log "2: /proc/self/mounts cannot be read"
IMG2="$(ct_image 560 mkfsm)"
LOOP2="$(ct_loop "$IMG2")"
OUT="$(unshare -m sh -c "mount -t tmpfs none /proc && '$MKFS' '$LOOP2' -z 1 -b 512 -J 0 -N 1024 -f" 2>&1)" && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q "unknown: /proc/self/mounts unreadable" <<<"$OUT" &&
    pass "2: mkfs -f refuses when it cannot read the mount table" ||
    fail "2: rc=$RC: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
OUT="$("$MKFS" "$LOOP2" -z 1 -b 512 -J 0 -N 1024 -f 2>&1)" && pass "2: and formats normally when it can" ||
    fail "2: mkfs -f failed with /proc visible: $(tail -1 <<<"$OUT")"
ct_exit
