#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# every checksummed structure's verification really fires
#
# CRC32C on every major structure is the backbone of this filesystem's
# integrity claim -- kernel-enforced on read, and fsck's first line of
# defence offline. Almost none of those verifications had a control: a
# checker never seen to fail proves nothing, and N5 is the reason that
# is not a slogan here. That check (a directory's link count) was not
# merely uncovered -- it was WRONG, and condemned every healthy volume
# past 58 entries, for days, because nothing ever made it fire.
#
# Each case flips ONE BIT inside the checksummed region and leaves the
# stored checksum alone, which is what a torn write or a bad sector
# actually leaves. A bit rather than a byte set to a constant: a
# constant can coincide with what was already there and change nothing,
# and the control would then prove nothing while looking fine.
#
# No kernel module and nothing mounted: mkfs writes the structures, the
# poke corrupts one, fsck must report THAT fault.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper csum_poke)"

IMG="$(ct_image 560 csum)"
DEV="$(ct_loop "$IMG")"

# -z 1: this device only backs one Block Group at -b 512, and mkfs
# clamps -z to that -- asking for 2 would leave the second ZG id
# pointing at the BG table, so a "ZG 1" poke would corrupt a Block
# Group descriptor and the control would catch the wrong thing.
build() { ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null; }

# <label> <expected text> <poke args...>
expect_caught() {
    local label="$1" want="$2"
    shift 2
    build
    "$POKE" "$DEV" "$@" >/dev/null
    # The poke writes the BACKING FILE while fsck reads through the loop
    # device, which caches. Without this flush the corruption is seen
    # intermittently -- the same case passed and failed across
    # consecutive runs of this suite while it was being written, which
    # is worse than failing outright.
    blockdev --flushbufs "$DEV"
    local out rc
    # Captured, not piped: fsck exits nonzero exactly when it finds the
    # fault being looked for, and `set -o pipefail` would turn that into
    # a failed assertion however well the grep matched.
    out="$(ct_fsck "$DEV" 2>&1 || true)"
    rc=0
    ct_fsck "$DEV" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "0" ]; then
        fail "$label: fsck reported the volume CLEAN with the structure corrupted"
    elif echo "$out" | grep -qE "$want"; then
        pass "$label: detected ($(echo "$out" | grep -oE "$want" | head -1))"
    else
        fail "$label: fsck failed, but not for this reason -- wanted /$want/, got: $(echo "$out" | grep '^ERR' | head -2 | tr '\n' ' ')"
    fi
}

log "a healthy volume is clean to begin with"
build
ct_fsck "$DEV" >/dev/null 2>&1 &&
    pass "the control image passes before anything is corrupted" ||
    fail "the freshly-made image is already reported corrupt: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

log "the structures fsck checksums"
expect_caught "superblock"            "SB CRC mismatch"                  sb
expect_caught "zone group, hot half"  "ZG[0-9]+ hot-sector CRC mismatch"  zg-hot 0
expect_caught "zone group, cold half" "ZG[0-9]+ cold-region CRC mismatch" zg-cold 0
expect_caught "block group descriptor" "BG[0-9]+ descriptor CRC mismatch" bg-desc 0
expect_caught "block group header"    "BG[0-9]+ header CRC mismatch"      bg-hdr 0
build
"$(ct_helper node_poke)" "$IMG" 0 1 ee "$(date +%s)" >/dev/null 2>&1
"$POKE" "$DEV" node 0 >/dev/null
blockdev --flushbufs "$DEV"
NODE_OUT="$(ct_fsck "$DEV" 2>&1 || true)"
echo "$NODE_OUT" | grep -qE "node slot .* CRC mismatch" &&
    pass "node registry row: detected" ||
    fail "node registry row: wanted a CRC mismatch, got: $(echo "$NODE_OUT" | grep '^ERR' | head -2 | tr '\n' ' ')"
# ...and the reason it needed registering first is itself worth an
# assertion: a FREE row is zero-filled by mkfs and never stamped, so
# checking its checksum would condemn every fresh volume.
build
"$POKE" "$DEV" node 0 >/dev/null
blockdev --flushbufs "$DEV"
ct_fsck "$DEV" >/dev/null 2>&1 &&
    pass "node registry row: a FREE row's checksum is correctly NOT checked" ||
    fail "a corrupted FREE row was reported -- mkfs leaves them zeroed, so every fresh volume would fail"
expect_caught "root inode record"     "root inode CRC(/identity)? mismatch"          inode 1
expect_caught "root's dirent block"   "tail checksum"                    dirent-tail 1

ct_exit
