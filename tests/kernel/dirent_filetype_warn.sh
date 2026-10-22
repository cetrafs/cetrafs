#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck WARNs when a dirent's file_type disagrees with the inode's mode
#
# A directory entry carries a file_type byte that readdir hands out as
# d_type. It is a COPY of the target inode's kind, and tools that trust
# d_type instead of stat (find -type, fts, rsync, tar) believe it -- N9
# found two kernel sites that once wrote the wrong byte. The inode mode is
# authoritative, so a mismatch is not corruption: fsck reports it as a WARN
# and still exits 0, rather than condemning an otherwise healthy volume.
#
# This needs a mount to set up (the entry must name a real file, which a
# root-only image cannot have), which is why it lives here and not in
# tests/image/fsck_negative_controls.sh with the other fsck controls.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CORRUPT="$(ct_helper corrupt_poke)"

FT_REG=1
FT_DIR=2

IMG="$(ct_image 560 ftwarn)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ftwarn)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo hello >"$MNT/reg"   # a regular file: its dirent's file_type is FT_REG
mkdir "$MNT/sub"         # a directory: its dirent's file_type is FT_DIR
ct_umount "$MNT"

# Capture fsck output + rc without aborting (a WARN-only volume exits 0,
# but capture rc explicitly so an unexpected ERR is visible, not swallowed).
fsck_capture() {
    blockdev --flushbufs "$DEV" 2>/dev/null || true
    set +e
    FSCK_OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)"
    FSCK_RC=$?
    set -e
}

log "baseline: a correctly-typed volume emits no file_type WARN"
fsck_capture
[ "$FSCK_RC" = 0 ] || fail "baseline: fsck exited $FSCK_RC ($(echo "$FSCK_OUT" | grep -E '^(ERR|WARN)' | head -1))"
if echo "$FSCK_OUT" | grep -E "file_type" >/dev/null; then
    fail "baseline already reports a file_type mismatch: $(echo "$FSCK_OUT" | grep file_type | head -1)"
else
    pass "baseline: fsck clean, no file_type WARN"
fi

log "a regular file's dirent claiming FT_DIR is WARNed (but not condemned)"
"$CORRUPT" "$DEV" filetype 1 reg "$FT_DIR" >/dev/null
fsck_capture
# A WARN must NOT fail the exit code: the inode mode is authoritative, the
# volume is usable.
[ "$FSCK_RC" = 0 ] || fail "a file_type mismatch wrongly made fsck exit $FSCK_RC (it must be a WARN, not an ERR)"
if echo "$FSCK_OUT" | grep -E "WARN:.*entry for inode.*file_type" >/dev/null; then
    pass "fsck WARNs: $(echo "$FSCK_OUT" | grep -E 'WARN:.*file_type' | head -1 | sed 's/^WARN: //')"
else
    fail "fsck did not WARN about the file_type mismatch: $(echo "$FSCK_OUT" | grep -E '^(ERR|WARN)' | head -2)"
fi

log "the reverse: a directory's dirent claiming FT_REG is WARNed too"
"$CORRUPT" "$DEV" filetype 1 reg "$FT_REG" >/dev/null   # put reg back first
"$CORRUPT" "$DEV" filetype 1 sub "$FT_REG" >/dev/null
fsck_capture
[ "$FSCK_RC" = 0 ] || fail "the sub-dir file_type WARN wrongly made fsck exit $FSCK_RC"
echo "$FSCK_OUT" | grep -E "WARN:.*file_type" >/dev/null &&
    pass "a directory entry typed as a regular file is WARNed" ||
    fail "no WARN for the directory-typed-as-regular case"

log "control: once every file_type matches its inode, the WARN is gone"
"$CORRUPT" "$DEV" filetype 1 sub "$FT_DIR" >/dev/null   # restore sub to FT_DIR
fsck_capture
[ "$FSCK_RC" = 0 ] || fail "control: fsck exited $FSCK_RC on a restored volume"
if echo "$FSCK_OUT" | grep -E "file_type" >/dev/null; then
    fail "control: a file_type WARN persists after restoring the correct types -- the check above proved nothing"
else
    pass "control: no file_type WARN once the bytes match the inodes"
fi

ct_exit
