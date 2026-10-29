#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the operations this filesystem does NOT implement must refuse cleanly
#
# Every gap here is a deliberate one, and the question for each is the
# same: does it fail, or does it quietly do something wrong? A refusal
# is a supported answer; silently mishandling is not.
#
# The one that was not a clean refusal: cetrafs_iget() chose i_op/i_fop
# by testing for directory and symlink and treating EVERYTHING ELSE as a
# regular file. The format defines FIFO, socket and device entries (and
# since N9 cetrafs_dirent_type() maps them), so a record carrying such a
# mode -- corruption, or another implementation's work -- was given
# cetrafs_file_ops and cetrafs_aops, and a device node would be READ as
# a file: its extent tree walked and whatever blocks it names served up
# as contents.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 unsup)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt unsup)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "the deliberate gaps refuse rather than misbehave"
mknod "$MNT/fifo" p 2>/dev/null && fail "mknod created a FIFO on a filesystem with no .mknod" ||
    pass "mknod is refused (no .mknod, deliberate)"
mknod "$MNT/chr" c 1 3 2>/dev/null && fail "mknod created a character device" ||
    pass "mknod of a device node is refused"
OUT="$(python3 - "$MNT" <<'PY'
import os, sys, errno
try:
    fd = os.open(sys.argv[1], os.O_TMPFILE | os.O_RDWR, 0o600)
    os.close(fd)
    print("created")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
PY
)"
[ "$OUT" = "created" ] && fail "O_TMPFILE succeeded with no .tmpfile" ||
    pass "O_TMPFILE is refused with $OUT (no .tmpfile, deliberate)"
: >"$MNT/f"
chattr +i "$MNT/f" 2>/dev/null && { chattr -i "$MNT/f" 2>/dev/null || true; fail "chattr set an attribute"; } ||
    pass "chattr is refused (no .fileattr_set, deliberate)"
# security.* is deliberately handled (SELinux labelling, kmod/xattr.c);
# what has NO handler is the system.* namespace (no ACLs). Asserted via
# python: the old setfattr call passed vacuously wherever the attr
# package was missing -- "command not found" with stderr suppressed
# reads exactly like a refusal (2026-10-29).
python3 -c "
import errno, os, sys
try:
    os.setxattr(sys.argv[1] + '/f', b'system.no_such_handler', b'x')
except OSError as e:
    sys.exit(0 if e.errno == errno.EOPNOTSUPP else 1)
sys.exit(1)" "$MNT" &&
    pass "an unhandled xattr namespace (system.*) is refused with EOPNOTSUPP" ||
    fail "a system.* xattr was accepted (or refused with the wrong errno)"

log "what IS reachable through the generic paths still works"
# No .setattr on a symlink inode (page_symlink_inode_operations has
# none), so lchown and utimes land in simple_setattr -- which only
# persists because cetrafs_write_vfs_inode() picks the change up from
# write-back. Checked across a remount, which is the only way to tell.
ln -s f "$MNT/s"
chown -h 7:9 "$MNT/s"
touch -h -d '2001-02-03 04:05:06' "$MNT/s"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c '%u:%g' "$MNT/s")" = "7:9" ] && pass "lchown on a symlink persists across a remount" ||
    fail "the symlink's owner is $(stat -c '%u:%g' "$MNT/s") after a remount, expected 7:9"
[ "$(stat -c '%y' "$MNT/s" | cut -c1-19)" = "2001-02-03 04:05:06" ] &&
    pass "utimes on a symlink persists across a remount" ||
    fail "the symlink's mtime is $(stat -c '%y' "$MNT/s" | cut -c1-19) after a remount"

log "a record of a type this build cannot represent is refused, not guessed"
echo "this must not be served as file contents" >"$MNT/victim"
VINO="$(stat -c '%i' "$MNT/victim")"
ct_umount "$MNT"
for spec in "020600 character device" "010600 FIFO" "0140600 socket"; do
    set -- $spec
    MODE="$1"
    shift
    WHAT="$*"
    "$POKE" "$IMG" setmode "$VINO" "$MODE" >/dev/null 2>&1
    ct_mount "$DEV" "$MNT"
    if OUT="$(cat "$MNT/victim" 2>&1)"; then
        fail "a $WHAT record was read as a regular file: '$OUT'"
    else
        pass "a $WHAT record is refused ($(echo "$OUT" | sed 's/.*: //'))"
    fi
    ct_umount "$MNT"
done

log "control: the same inode with its real type reads normally"
"$POKE" "$IMG" setmode "$VINO" 0100644 >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
[ "$(cat "$MNT/victim")" = "this must not be served as file contents" ] &&
    pass "control: as a regular file it reads correctly again" ||
    fail "control: the file does not read back even with its type restored"
ct_umount "$MNT"
ct_exit
