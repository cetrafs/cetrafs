#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a time before 1970 does not win the "later time" merge
#
# A publish of a file's times merges against a peer's concurrent publish:
# when both changed a time, the later wins. The merge compared them as
# u64, and a time before 1970 is negative -- as a u64 it is enormous, so
# it beat every real time (audit 2026-11-05, section 3).
#
# Staged: with the file open, a "peer" publishes mtime 2000 on the
# device; futimens through the fd then sets 1960, and its publish merges
# against the peer's value. 2000 is the later and must be what the device
# keeps.
#
# DISCRIMINATION: proven 2026-11-05 with the unsigned compare: 1960 wins.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 mtsign)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mtsign)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo x >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"

# The fd is opened (this node's baseline: the current mtime) before the
# peer's publish lands, and futimens through it needs no lookup, so
# nothing refreshes that baseline: the publish's fresh read finds the
# peer's 2000 and merges our 1960 against it. (On the loop rig the CAS
# is read-fresh/mutate/write, so the peer's value must be on the device
# before that read, not during it.)
python3 - "$MNT/f" "$IPOKE" "$IMG" "$INO" <<'PY' || { fail "setup: the staging failed"; ct_exit; }
import os, subprocess, sys
f, poke, img, ino = sys.argv[1:5]
fd = os.open(f, os.O_RDWR)
os.fstat(fd)
subprocess.run([poke, img, "setmtime", ino, "946684800"], check=True, capture_output=True)  # the peer: 2000-01-01
os.utime(fd, (-315619200, -315619200))                                                    # ours: 1960
os.close(fd)
PY
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
M="$(stat -c %Y "$MNT/f")"
case "$M" in
946684800) pass "the later time (2000) won the merge" ;;
-315619200) fail "the 1960 time won the merge over 2000 -- compared unsigned" ;;
*) fail "setup: mtime is $M, neither side's -- the publish did not merge against the peer's value" ;;
esac
ct_umount "$MNT"
ct_exit
