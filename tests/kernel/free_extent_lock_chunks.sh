#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# freeing a large extent lets go of alloc_mutex between chunks, and credits every block
#
# A data extent is freed bit by bit under alloc_mutex. Held across the
# whole extent -- up to a Block Group, 2^32 blocks at the format's limit
# -- it stopped every allocation on the node for the duration: about a
# tenth of a second per default 1 GiB group, minutes at the limit (audit
# 2026-11-06 L26). It is now released every 4096 blocks, each chunk's
# free count credited before.
#
# Staged: a ~480 MiB file in one extent, removed. A kprobe on
# cetrafs_sb_alloc_unlock() counts the releases during the remove; the
# suite skips where kprobes are unavailable. And the split credit must
# add up: statfs back where it started, fsck clean.
#
# DISCRIMINATION: one hold for the whole extent, a handful of releases.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 frchunk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt frchunk)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
F0="$(stat -f -c %f "$MNT")"
fallocate -l 480M "$MNT/big"
dd if=/dev/zero of="$MNT/big" bs=1M count=480 conv=notrunc,fsync status=none
sync
EXT="$("$IPOKE" "$IMG" extents "$(stat -c %i "$MNT/big")" 2>&1 | head -1)"
grep -qE "entries=1 " <<<"$EXT" || { fail "setup: the file is not one extent: $EXT"; ct_umount "$MNT"; ct_exit; }
BLOCKS=$((480 * 256))
log "big: $EXT"

T=/sys/kernel/tracing
# A kprobe records nothing with tracing switched off, which would read as
# "no hits": say so instead of passing.
[ "$(cat "$T/tracing_on" 2>/dev/null)" = 1 ] || { skip "tracing is off (tracing_on != 1): a kprobe would record nothing"; ct_exit; }
EV=cetrafs_frch_$$
kp_off() {
    echo 0 >"$T/events/kprobes/$EV/enable" 2>/dev/null || true
    echo "-:kprobes/$EV" >>"$T/kprobe_events" 2>/dev/null || true
}
echo "p:kprobes/$EV cetrafs:cetrafs_sb_alloc_unlock" >>"$T/kprobe_events" 2>/dev/null ||
    { skip "cannot place a kprobe on cetrafs_sb_alloc_unlock"; ct_umount "$MNT"; ct_exit; }
: >"$T/trace"
echo 1 >"$T/events/kprobes/$EV/enable"
rm -f "$MNT/big"
sync
sleep 1
REL="$(grep -c "$EV:" "$T/trace" || true)"
kp_off
F1="$(stat -f -c %f "$MNT")"
log "$REL alloc_mutex release(s) freeing $BLOCKS blocks; free $F0 -> $F1"
[ "$REL" -ge $((BLOCKS / 4096)) ] && pass "the free let go of alloc_mutex $REL times across the extent" ||
    fail "the free released alloc_mutex only $REL time(s) for $BLOCKS blocks -- held across the whole extent"
[ "$F1" = "$F0" ] && pass "and every block was credited back ($F1 free)" ||
    fail "free blocks $F1 after the remove, $F0 before"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
