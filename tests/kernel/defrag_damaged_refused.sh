#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag refuses a damaged inode: relocation is a write, and the write gate covers it
#
# A damaged inode refuses every write (EUCLEAN). The defrag ioctl and the
# background worker checked only the fence, so a file marked damaged
# while its fd was open was still relocated -- its record rewritten and
# every block moved on a tree already known to be wrong (audit
# 2026-11-06 L21).
#
# Two identically fragmented files. defrag.cetra on the first must
# relocate it (the setup: the file is one defrag would move). On the
# second, defrag_damage_ino marks it damaged as the ioctl starts, the way
# a read that found damage on the open file would have; the defrag must
# fail with EUCLEAN and leave the extents as they were.
#
# DISCRIMINATION: gated on the fence alone, the damaged file is relocated.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/defrag_damage_ino ] || { skip "defrag_damage_ino is missing"; ct_exit; }
ct_param_set alloc_run_blocks 0
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 dfdmg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfdmg)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
python3 - "$MNT/a" "$MNT/b" "$MNT/sep" <<'PY'
import os, sys
fds = [os.open(p, os.O_CREAT | os.O_WRONLY, 0o644) for p in sys.argv[1:]]
for i in range(12):
    for f in fds:
        os.pwrite(f, os.urandom(4096), i * 4096)
        os.fsync(f)
for f in fds:
    os.close(f)
PY
sync
ext() { "$IPOKE" "$IMG" extents "$(stat -c %i "$1")" 2>&1; }
A0="$(ext "$MNT/a")"
B0="$(ext "$MNT/b")"
SUM0="$(md5sum <"$MNT/b")"
log "a: $A0 / b: $B0"

"$ROOT/userspace/defrag.cetra" "$MNT/a" >/dev/null 2>&1 || true
sync
A1="$(ext "$MNT/a")"
[ "$A1" != "$A0" ] || { fail "setup: defrag did not relocate the healthy file ($A0)"; ct_umount "$MNT"; ct_exit; }
pass "setup: defrag relocates the healthy file ($A0 -> $A1)"

ct_param_set defrag_damage_ino "$(stat -c %i "$MNT/b")"
OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/b" 2>&1 || true)"
[ "$(cat /sys/module/cetrafs/parameters/defrag_damage_ino)" = 0 ] ||
    { fail "setup: the ioctl never reached the damage mark"; ct_param_set defrag_damage_ino 0; ct_umount "$MNT"; ct_exit; }
sync
B1="$(ext "$MNT/b")"
grep -qi "needs cleaning" <<<"$OUT" && pass "defrag of the damaged file failed with EUCLEAN" ||
    fail "defrag of the damaged file said: $OUT"
[ "$B1" = "$B0" ] && pass "and its extents were not moved" ||
    fail "the damaged file was relocated anyway ($B0 -> $B1)"
[ "$(md5sum <"$MNT/b")" = "$SUM0" ] || fail "the damaged file's content changed"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
