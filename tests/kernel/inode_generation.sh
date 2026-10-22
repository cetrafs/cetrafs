#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reused inode number is detected across nodes via the generation
#
# Inode numbers are freely reused, and a cache keyed by number alone
# cannot tell "same file, updated" from "new file, same number" --
# refreshing FIELDS on an object of the wrong IDENTITY is corruption, not
# staleness. Caught on real hardware as a cached symlink whose number a
# peer had reused for a regular file: the VFS walked the new file's data
# as a path.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking cross-node inode-number-reuse detection (generation, v0x0008)"

# The real two-node failure this guards: node A unlinks a SYMLINK and
# reuses its inode number for a regular file; node B's cached in-core
# object keeps the symlink's i_op, so B's VFS follows the "link" and
# walks the NEW file's data as a path -- persistent ENOENT for a file B
# can plainly see in readdir. v0x0008 stamps a generation at allocation;
# a cached object whose generation no longer matches the record is
# unhashed and re-instantiated with the new file's type. Simulated here
# by retyping a cached symlink's record (new generation, REG mode, valid
# checksum) on the loop device's BACKING file behind the live mount.
GEN_POKE="$(ct_helper inode_block_poke)"

GEN_IMG="$(mktemp /tmp/cetrafs-gen-XXXXXX.img)"
truncate -s 560M "$GEN_IMG"
GEN_LOOPDEV="$(losetup --find --show "$GEN_IMG")"
GEN_MNT="$(mktemp -d /tmp/cetrafs-gen-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$GEN_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$GEN_LOOPDEV" "$GEN_MNT"

ln -s "gen-target-content" "$GEN_MNT/genlink"
GEN_INO="$(stat -c '%i' "$GEN_MNT/genlink")"
readlink "$GEN_MNT/genlink" >/dev/null   # cache the in-core object as a SYMLINK

"$GEN_POKE" "$GEN_IMG" retype "$GEN_INO" 424242 2>/dev/null

GEN_TYPE="$(stat -c '%F' "$GEN_MNT/genlink")"
if [ "$GEN_TYPE" = "regular file" ]; then
    pass "generation: a reused inode number is re-instantiated with the new file's type"
else
    fail "generation: cached object kept the old type ('$GEN_TYPE', want 'regular file') despite a generation change"
fi
GEN_CONTENT="$(cat "$GEN_MNT/genlink")"
[ "$GEN_CONTENT" = "gen-target-content" ] &&
    pass "generation: the re-typed file's content reads through the fresh object" ||
    fail "generation: content read '$GEN_CONTENT', want 'gen-target-content'"

umount "$GEN_MNT"
rmdir "$GEN_MNT"
losetup -d "$GEN_LOOPDEV"
rm -f "$GEN_IMG" "$GEN_POKE"


ct_exit
