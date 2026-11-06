#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create does not adopt a free number whose record fails its checksum
#
# A create takes a free number's bit, reads its record, and claims it
# with a CAS seeded from that read. A record that was neither all-zero
# (never used) nor checksum-valid went to the claim anyway, and the claim
# stamps a fresh checksum over what it is given: damaged bytes came out
# VALID, under a new file (audit 2026-11-06 L11).
#
#  (1) Free number N's record is garbage: the create must take another
#      number and leave N for fsck.
#  (2) birth_seed_tear_once: the seed reads torn once, as a peer's write
#      caught mid-flight would. The re-read converges, and the create
#      takes N as usual.
#
# DISCRIMINATION: unchecked, (1)'s create is given N.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

DEV="$(ct_dev 560 birthseed)"
MNT="$(ct_mnt birthseed)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
touch "$MNT/probe"
N="$(stat -c %i "$MNT/probe")"
rm "$MNT/probe"
sync
ct_umount "$MNT"

# --- 1
"$IPOKE" "$DEV" poke "$N" 0x5a 2>/dev/null # garbage, not zero, checksum wrong
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
touch "$MNT/f" || { fail "1: the create failed outright"; ct_umount "$MNT"; ct_exit; }
GOT="$(stat -c %i "$MNT/f")"
[ "$GOT" != "$N" ] && pass "1: the create took another number ($GOT), not damaged $N" ||
    fail "1: the create adopted number $N, whose record failed its checksum"
dmesg_since "$MARK" | grep -q "ino=$N is free but its record fails its checksum" &&
    pass "1: and said why" || fail "1: no word about the damaged free record"
ct_umount "$MNT"

# --- 2
if [ -w /sys/module/cetrafs/parameters/birth_seed_tear_once ]; then
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    touch "$MNT/probe"
    N2="$(stat -c %i "$MNT/probe")"
    rm "$MNT/probe"
    sync
    ct_param_set birth_seed_tear_once 1
    touch "$MNT/g" || fail "2: the create failed"
    T="$(cat /sys/module/cetrafs/parameters/birth_seed_tear_once)"
    [ "$T" = N ] || fail "2: setup: the create never read a seed to tear"
    [ "$(stat -c %i "$MNT/g")" = "$N2" ] && pass "2: a seed torn once was re-read and number $N2 used" ||
        fail "2: a one-off tear cost number $N2 ($(stat -c %i "$MNT/g") taken instead)"
    ct_umount "$MNT"
    OUT="$(ct_fsck "$DEV" 2>&1)" && pass "2: fsck clean" || fail "2: fsck: $(grep -E '^ERR' <<<"$OUT" | head -2)"
else
    log "2: birth_seed_tear_once is missing -- the tear round needs it"
fi
ct_exit
