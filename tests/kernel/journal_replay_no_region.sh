#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay refuses an entry whose region check answers "in no data region", and redoes it otherwise
#
# Replay looks a target up twice: once to learn its Block Group (which
# already refuses a target outside every group's span), and again, after
# the guard, in the freed-target check (journal_replay_freed_target.sh),
# which re-reads the group and asks whether the block lies in its data
# region. That second answer -EINVAL was not handled: replay fell through
# to the redo and wrote the entry's payload onto metadata (audit C5). The
# two reads normally agree, so the answer is reached only when the
# descriptor changes between them; the injection below stands in for that
# race. The entry is now refused and consumed; any other error from the
# check keeps the entry and leaves the area dirty.
#
# Staged single-node. Owner checking is switched off (journal_ignore_owner)
# so the region check is the only verdict in play.
#
# 1. the region check answers -EINVAL for a file's data block: refused, the
#    block is untouched, the entry is consumed (area CLEAN), dmesg says why.
# 2. control: the same entry, the check answering normally, is redone.
#
# DISCRIMINATION: with the -EINVAL fall-through (the pre-fix code) case 1
# writes the payload onto the data block and the block no longer matches.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_alloc_region_fail ] || { skip "journal_alloc_region_fail is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"
EPOKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 jrnoreg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrnoreg)"
ct_track mnt "$MNT"
PAY="$(ct_tmp jrnoreg-pay)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
dd if=/dev/zero of="$MNT/f" bs=4096 count=2 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
DATA="$("$EPOKE" "$IMG" extent "$INO" | cut -d' ' -f1)"
[ -n "$DATA" ] && [ "$DATA" -gt 0 ] || { fail "setup: no data block for f ($DATA)"; ct_exit; }
blk() { dd if="$IMG" bs=4096 skip="$DATA" count=1 status=none | md5sum | cut -d' ' -f1; }
head -c 4096 /dev/urandom >"$PAY"
WANT="$(md5sum <"$PAY" | cut -d' ' -f1)"
BEFORE="$(blk)"
[ "$BEFORE" != "$WANT" ] || { fail "setup: the data block already holds the payload"; ct_exit; }
ct_param_set journal_ignore_owner 1
# Both parameters go back at cleanup: ct_param_set records them.

# ------------------------------------------------------------------- 1
"$JPOKE" "$IMG" "$NID" 0 "$DATA" "$PAY" --guard-current >/dev/null
ct_param_set journal_alloc_region_fail 1
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then ct_umount "$MNT"; fi
LEFT="$(cat /sys/module/cetrafs/parameters/journal_alloc_region_fail)"
ct_param_set journal_alloc_region_fail 0
AFTER="$(blk)"
DUMP="$("$JPOKE" "$IMG" "$NID" --dump 2>/dev/null || true)"
[ "$LEFT" = 0 ] || { fail "setup: the region check was not reached"; ct_exit; }
dmesg_since "$MARK" | grep -q "target block $DATA lies in no data region" &&
    pass "1: the entry was refused for lying in no data region" ||
    fail "1: no 'lies in no data region' refusal in dmesg"
[ "$AFTER" = "$BEFORE" ] && pass "1: the block was not written" ||
    fail "1: replay wrote its payload onto block $DATA after the region check said it lies in no data region"
grep -q "^state=0 " <<<"$DUMP" && pass "1: the refused entry was consumed (area CLEAN)" ||
    fail "1: the area is still dirty after the refusal ($DUMP)"

# ------------------------------------------------------------------- 2
"$JPOKE" "$IMG" "$NID" 0 "$DATA" "$PAY" --guard-current >/dev/null
mount -t cetrafs "$DEV" "$MNT"
ct_umount "$MNT"
[ "$(blk)" = "$WANT" ] && pass "2: control: the same entry with the check answering normally is redone" ||
    fail "2: control: the data block was not redone -- 1 proves nothing"
ct_exit
