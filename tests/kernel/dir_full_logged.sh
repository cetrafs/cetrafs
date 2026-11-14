#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create that fails because its directory is full names the directory in the kernel log
#
# docs/internal/LIMITATIONS.md says a directory at its limit (254
# extents, or CETRAFS_DIR_MAX_BLOCKS) fails the create with ENOSPC "and
# the kernel log names the directory". Nothing printed it (re-audit of
# the 2026-11-14 fixes): an ENOSPC on a volume with free space was left
# unexplained.
#
# A directory is grown among other allocations -- one 4 KiB file
# written between dirent blocks -- so each of its blocks is an extent of
# its own and its tree fills at ~3,800 entries, with the volume nearly
# empty. The create that fails must return ENOSPC, and the log must
# name the directory's inode.
#
# DISCRIMINATION: on the unfixed module the same run fails the create
# with ENOSPC and logs nothing about the directory.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
DEV="$(ct_dev 1200 dfull)"
MNT="$(ct_mnt dfull)"
ct_mkfs "$DEV" -z 1 -J 0 -N 16384 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d" "$MNT/pad"
ino="$(stat -c %i "$MNT/d")"
res="$(python3 - "$MNT" <<'PY'
import os, sys, errno
m = sys.argv[1]
n = 0
while n < 8000:
    try:
        open(f"{m}/d/e{n:05d}", "w").close()
    except OSError as e:
        print(n, e.errno); sys.stdout.flush(); os._exit(0)
    n += 1
    if n % 15 == 0:
        with open(f"{m}/pad/p{n}", "wb") as f:
            f.write(b"x" * 4096)
            f.flush(); os.fsync(f.fileno())
print(n, 0); sys.stdout.flush()
PY
)"
# The tail, not dmesg_since: a debug build logs every create, ~4,000 of
# them wrap the ring and take a mark with them. The failing create is
# the last thing this suite did.
tail_log="$(dmesg | tail -n 40)"
read -r made err <<<"$res"
free="$(stat -f -c '%f' "$MNT")"
log "created $made entries, then errno $err; $free blocks free"
[ "$err" = 28 ] && [ "$free" -gt 100000 ] ||
    { fail "setup: the directory did not fill with the volume nearly empty (errno $err after $made, $free free)"; ct_exit; }
grep -q "dir ino=$ino \(is full\|cannot grow\)" <<<"$tail_log" &&
    pass "the full directory's ENOSPC is named in the log (ino $ino, after $made entries)" ||
    fail "ENOSPC after $made entries and the log does not name directory $ino"
# A failed growth keeps the block its tree may name; three more refused
# creates must not leave three more blocks referenced by nothing.
for x in 1 2 3; do : >"$MNT/d/more$x" 2>/dev/null || true; done
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean after the refused creates" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -3)"
ct_exit
