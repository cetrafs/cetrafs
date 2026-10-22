#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# minimum claim at mount, one more ZG on demand, surplus released
#
# The first node to mount a fresh multi-ZG volume used to claim the
# ENTIRE disk, permanently starving every node that mounted later. Each
# node now takes the one ZG it needs, claims exactly one more only once
# every BG it owns is full, and gives back any ZG that comes back
# completely empty -- never below one.
#
# Uses bg_poke to fake "this BG is full" rather than writing hundreds of
# MiB for real.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
BG_POKE="$(ct_helper bg_poke)"

log "checking the minimum-claim / claim-on-demand ZG policy fix"
# Independent throwaway image/loop device with 3 Zone Groups -- same
# pattern as the LOCK_*/GATE_* blocks above. This is the actual
# regression this fix targets: zonegroup.c used to eagerly claim every
# unowned ZG at mount, so the first node to ever mount a multi-ZG volume
# walked away owning all of it, permanently starving every later node.
MULTIZG_IMG="$(mktemp /tmp/cetrafs-multizg-XXXXXX.img)"
truncate -s 1700M "$MULTIZG_IMG"
MULTIZG_LOOPDEV="$(losetup --find --show "$MULTIZG_IMG")"
MULTIZG_MNT="$(mktemp -d /tmp/cetrafs-multizg-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$MULTIZG_LOOPDEV" -z 3 -b 512 -J 0 -N 1024 -f >/dev/null

mount -t cetrafs "$MULTIZG_LOOPDEV" "$MULTIZG_MNT"
# A fixed recent-tail slice rather than a dmesg-linecount mark + "tail -n
# +N" diff: by this point in a long test run, the kernel ring buffer has
# likely already wrapped past whatever count was recorded earlier, which
# makes the usual mark/diff pattern (used safely in the other suites,
# closer to the start of the run) unreliable this late -- the line just
# logged is still safely within a generous trailing window regardless.
MZ_LOG="$(dmesg | tail -n 200)"

if echo "$MZ_LOG" | grep -q 'ZG claim: own 1 of 3 zone group(s)'; then
    pass "ZG claim: first mount on a fresh 3-ZG volume claims only 1 ZG, not all 3"
else
    fail "ZG claim: expected 'own 1 of 3 zone group(s)' on a fresh 3-ZG volume, got: $(echo "$MZ_LOG" | grep 'ZG claim:')"
fi

MZ_PROC_DEV="$(basename "$MULTIZG_LOOPDEV")"
MZ_INFO="$(cat "/proc/fs/cetrafs/$MZ_PROC_DEV/info")"
UNOWNED_COUNT="$(echo "$MZ_INFO" | grep -cP '^\s+zg [0-9]+: owner=none')"
[ "$UNOWNED_COUNT" = "2" ] && pass "proc info: the other 2 zone groups are left unowned for future nodes" ||
    fail "proc info: expected 2 unowned zone groups, got $UNOWNED_COUNT: $MZ_INFO"

# Simulate "this node's one owned ZG is completely full" by poking every
# BG it owns full (actually writing ~512 MiB of real data to exhaust a
# real BG is far too slow for a test; see tests/bg_poke.c).
#
# "fill-bitmap", not just a free count of 0: a mount
# reconciles a Block Group's cached count against its own bitmap, so a
# counter poked to 0 over an empty bitmap is corrected straight back and
# this scenario would quietly stop simulating anything -- the write
# below would succeed from the ZG it already owns and the on-demand
# claim this suite exists to test would never happen. Caught exactly
# that way when the reconcile landed. Filling the bitmap makes the BG
# genuinely full, which is what was meant all along.
# Then confirm a write that needs a new data block still succeeds, by
# claiming one of the other two still-unowned ZGs on demand instead of
# failing -ENOSPC outright with 2/3 of the volume sitting unclaimed.
ZG0_LINE="$(echo "$MZ_INFO" | grep -P '^\s+zg 0:')"
ZG0_FIRST_BG="$(echo "$ZG0_LINE" | grep -oP 'first_bg=\K[0-9]+')"
ZG0_BG_COUNT="$(echo "$ZG0_LINE" | grep -oP 'bg_count=\K[0-9]+')"

umount "$MULTIZG_MNT"
for ((bg = ZG0_FIRST_BG; bg < ZG0_FIRST_BG + ZG0_BG_COUNT; bg++)); do
    "$BG_POKE" "$MULTIZG_LOOPDEV" "$bg" 0 fill-bitmap >/dev/null
done

mount -t cetrafs "$MULTIZG_LOOPDEV" "$MULTIZG_MNT"

if dd if=/dev/zero of="$MULTIZG_MNT/probe" bs=4096 count=1 2>/dev/null; then
    pass "alloc: write to a new file succeeded by claiming an additional ZG on demand"
else
    fail "alloc: write to a new file unexpectedly failed (ENOSPC?) despite 2 ZGs still being unowned"
fi

MZ_LOG2="$(dmesg | tail -n 200)"
if echo "$MZ_LOG2" | grep -q 'alloc: ran out of space in owned zone group(s), claimed one more'; then
    pass "alloc: dmesg confirms the extra ZG was claimed on demand, not just coincidentally already owned"
else
    fail "alloc: expected an 'alloc: ran out of space ... claimed one more' dmesg line, got: $(echo "$MZ_LOG2" | grep 'alloc:')"
fi

MZ_INFO2="$(cat "/proc/fs/cetrafs/$MZ_PROC_DEV/info")"
OWNED_COUNT2="$(echo "$MZ_INFO2" | grep -cP '^\s+zg [0-9]+: owner=0 \(this node\)')"
[ "$OWNED_COUNT2" = "2" ] && pass "proc info: this node now owns 2 of 3 zone groups after running out of space in the first" ||
    fail "proc info: expected this node to own 2 zone groups after the on-demand claim, got $OWNED_COUNT2: $MZ_INFO2"

PROBE_SIZE="$(stat -c '%s' "$MULTIZG_MNT/probe" 2>/dev/null || echo 0)"
[ "$PROBE_SIZE" = "4096" ] && pass "alloc: the probe file's size is correct after the on-demand claim" ||
    fail "alloc: probe file size is '$PROBE_SIZE', expected 4096"

# --- voluntary surplus release (zonegroup.c's cetrafs_zg_release_surplus)
# A node that claims an extra ZG on demand must give it back once it no
# longer needs it, or one node ends up sitting on capacity a peer needs
# with no path back except going stale. This runs on the heartbeat tick,
# which makes it exactly the kind of BACKGROUND behaviour that can stop
# working silently -- it had no automated test at all until now (it was
# verified once by hand with an ad-hoc poke that was never kept), which
# is the same blind spot that let an auto-defrag regression through.
#
# State here is perfect for it: ZG0's BGs are poked to 0 free (so it
# stays legitimately in use and must NOT be released) and ZG1 holds
# nothing but the 4096-byte probe. Delete the probe and ZG1 is genuinely
# empty again.
rm -f "$MULTIZG_MNT/probe"
sync

MZ_RELEASED=no
for _ in $(seq 1 20); do
    sleep 3
    MZ_OWNED_NOW="$(grep -cP '^\s+zg [0-9]+: owner=0 \(this node\)' "/proc/fs/cetrafs/$MZ_PROC_DEV/info")"
    if [ "$MZ_OWNED_NOW" = "1" ]; then
        MZ_RELEASED=yes
        break
    fi
done
[ "$MZ_RELEASED" = yes ] &&
    pass "release surplus: the emptied extra ZG was given back on a heartbeat tick" ||
    fail "release surplus: still owns $MZ_OWNED_NOW ZGs after the extra one went empty"

# The floor matters as much as the release: a node must never give back
# its LAST zone group, or it would be left unable to allocate at all.
MZ_INFO3="$(cat "/proc/fs/cetrafs/$MZ_PROC_DEV/info")"
MZ_OWNED_FINAL="$(echo "$MZ_INFO3" | grep -cP '^\s+zg [0-9]+: owner=0 \(this node\)')"
[ "$MZ_OWNED_FINAL" = "1" ] &&
    pass "release surplus: the last owned ZG is kept, never released below one" ||
    fail "release surplus: expected exactly 1 owned ZG to remain, got $MZ_OWNED_FINAL: $MZ_INFO3"

# And it must still be usable -- releasing must not have left the
# allocator pointing at a ZG this node no longer owns.
if dd if=/dev/zero of="$MULTIZG_MNT/probe2" bs=4096 count=1 2>/dev/null; then
    pass "release surplus: the node can still allocate after giving a ZG back"
else
    fail "release surplus: allocation broke after the release"
fi
rm -f "$MULTIZG_MNT/probe2"

umount "$MULTIZG_MNT"
rmdir "$MULTIZG_MNT"
losetup -d "$MULTIZG_LOOPDEV"
rm -f "$MULTIZG_IMG"


ct_exit
