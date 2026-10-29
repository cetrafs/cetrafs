#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Background scrub reclaims leaked data blocks (bitmap set, no inode refs).
#
# The signature leak: a foreign free is dropped (a peer offline, its ZG's
# queue full), so a deleted file's data blocks stay marked allocated forever
# while referenced by no inode. fsck -r fixes it offline; the scrub does it
# online, in the background. The leak is simulated directly in the data bitmap
# (no file, no dirent -- exactly the end state of a dropped free: blocks
# allocated and counted used, but nothing points at them), then a scrub cycle
# must reclaim precisely those blocks.
#
# Discriminator: with the scrub disabled (or broken) the blocks stay leaked,
# scrub_reclaimed stays 0, free space never recovers, and fsck still flags it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAK="$(ct_helper data_leak_poke)"
NLEAK=40
OFFSET=100   # data-region offset well past the root directory's own block

IMG="$(mktemp /tmp/cetrafs-scrub-XXXXXX.img)"
truncate -s 560M "$IMG"
DEV="$(losetup --find --show "$IMG")"
MNT="$(mktemp -d /tmp/cetrafs-scrub-mnt-XXXXXX)"
PROC_DEV="$(basename "$DEV")"
ct_mkfs_small "$DEV" -z 1 >/dev/null

info() { cat "/proc/fs/cetrafs/$PROC_DEV/info"; }
free_blocks() { info | sed -n 's/^free_data_blocks: //p'; }
reclaimed() { info | sed -n 's/^scrub_reclaimed: //p'; }

# A fast scrub: a 2 s cycle with a 1 s two-pass gap (the default is 30 min).
# `scrub` itself is armed only AFTER the baseline below is captured.
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1

log "leak $NLEAK blocks directly in BG 0's data bitmap (no file references them)"
"$LEAK" "$DEV" 0 "$OFFSET" "$NLEAK" >/dev/null
# Capture fsck output first, then match (ct_fsck exits nonzero on finding the
# leak, so `ct_fsck | grep` under pipefail is the capture-first trap).
FSCK_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if echo "$FSCK_OUT" | grep "leaked" >/dev/null; then
    pass "setup: fsck confirms $NLEAK blocks leaked"
else
    fail "setup: fsck did not report the expected leak: $(echo "$FSCK_OUT" | grep -iE 'err|warn' | head -2)"
fi

log "mount with the fast scrub; it should reclaim the leaked blocks on its own"
mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
BEFORE="$(free_blocks)"

# scrub_reclaimed is a MODULE-GLOBAL cumulative counter (one atomic64 in
# scrub.c, never reset per mount), so it reads 0 only when this suite
# happens to be the first scrub of the module's life. Inside a full
# `make check` an earlier suite has already reclaimed blocks -- 64, from
# scrub_integrity -- and an absolute reading then failed all three
# assertions below while the scrub was working perfectly. Measure the
# DELTA, and arm the scrub only once the baseline is in hand so no cycle
# can land inside the measurement.
BASE="$(reclaimed)"
pass "baseline captured before the scrub is armed (scrub_reclaimed=$BASE, module-global)"
ct_param_set scrub 1

# One cycle is interval(2s) + gap(1s) + work; give it generous margin.
for i in $(seq 1 20); do
    [ "$(( $(reclaimed) - BASE ))" -gt 0 ] && break
    sleep 1
done
AFTER="$(free_blocks)"
REC="$(( $(reclaimed) - BASE ))"

[ "$REC" = "$NLEAK" ] \
    && pass "the scrub reclaimed exactly the leaked blocks (scrub_reclaimed=$REC)" \
    || fail "scrub_reclaimed=$REC, expected $NLEAK (over-freed is a BUG, under-freed means it missed the leak)"
[ "$((AFTER - BEFORE))" -ge "$NLEAK" ] \
    && pass "free space recovered by >=$NLEAK blocks ($BEFORE -> $AFTER)" \
    || fail "free space did not recover ($BEFORE -> $AFTER)"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 \
    && pass "fsck clean after the scrub (no leaked blocks remain)" \
    || fail "fsck still reports a problem: $(ct_fsck "$DEV" 2>&1 | grep -iE 'leak|err' | head -2)"

losetup -d "$DEV"
rmdir "$MNT"
rm -f "$IMG" "$LEAK"

ct_exit
