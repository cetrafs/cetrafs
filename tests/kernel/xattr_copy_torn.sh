#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless getxattr never copies an xattr block halfway through a replace
#
# An in-place replace of an xattr entry is several stores: the key and
# the length are new, then the value is copied. This node's own writers
# hold the buffer lock across that edit. A lockless getxattr validates
# the block (cetrafs_blk_tail_bread()), then copies it under the same
# lock (cetrafs_bh_read_lock()). A copy taken mid-edit cannot pass its
# checksum (the stored one is the old image's), so it is never handed
# back: it is retried, and the retry waits for the edit. The lock is
# what keeps the torn copy from being made at all -- the checksum is a
# second line, and this suite tests the first.
#
# Staged: the getxattr validates the block and is paused before its copy
# (xattr_copy_pause_ms). While it is paused, a setxattr replacing a
# 64-byte value 'A' with 'B' starts, and its edit is held half done for
# three seconds (xattr_edit_stall_ms). The getxattr's copy then happens
# inside the edit. Fix: the copy waits for the edit and is whole, so it
# is never logged as torn (xattr_copy_probe). Control
# (xattr_copy_unlocked): the copy is taken as it stands, is logged as
# torn, and only the retry's wait gets the reader its whole value.
#
# The control's torn log line is itself the setup check: a copy that
# failed its checksum was taken inside the edit. (The reader returns
# after the edit, through the retry's wait, so the setxattr has finished
# by then and cannot be the check.)
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in xattr_edit_stall_ms xattr_copy_unlocked xattr_copy_pause_ms xattr_copy_probe; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

IMG="$(ct_image 560 xattrtorn)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xattrtorn)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
F="$MNT/victim"
echo x >"$F"
python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", b"A" * 64)' "$F"
sync

# round <unlocked 0|1>: sets ROUND_RES to "torn=<n> get=<result>".
round() {
    local GET SET GPID SPID MARK TORN
    ct_param_set xattr_copy_unlocked "$1"
    ct_param_set xattr_copy_probe 1
    ct_param_set xattr_copy_pause_ms 1500
    ct_param_set xattr_edit_stall_ms 3000
    GET="$(ct_tmp getxattr)"
    MARK="$(dmesg_mark)"
    # The getxattr: validates the block, pauses, then copies.
    python3 -c '
import errno, os, sys, time
t0 = time.time()
try:
    v = os.getxattr(sys.argv[1], "user.k")
    if v in (b"A" * 64, b"B" * 64):
        out = "whole:" + v[:1].decode()
    else:
        out = "other:len=%d" % len(v)
except OSError as e:
    out = "EIO" if e.errno == errno.EIO else "errno=%d" % e.errno
open(sys.argv[2], "w").write("get=%s took=%.2f\n" % (out, time.time() - t0))
' "$F" "$GET" &
    GPID=$!
    sleep 0.5
    python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", b"B" * 64)' "$F" &
    SPID=$!
    wait "$GPID" || true
    wait "$SPID" || true
    ct_param_set xattr_edit_stall_ms 0
    ct_param_set xattr_copy_pause_ms 0
    ct_param_set xattr_copy_unlocked 0
    ct_param_set xattr_copy_probe 0
    TORN="$(dmesg_since "$MARK" | grep -c 'xattr copy probe' || true)"
    ROUND_RES="torn=$TORN $(cat "$GET")"
}

round 0; R="$ROUND_RES"
log "fix round: $R"
case "$R" in
    *get=whole:B*) pass "the getxattr returned the whole new value" ;;
    *) fail "the getxattr returned '${R##* }' ($R)" ;;
esac
case "$R" in
    *torn=0*) pass "no xattr block copy was made torn: the copy waited out the replace" ;;
    *) fail "a copy of the block was made mid-replace ($R)" ;;
esac

round 1; R="$ROUND_RES"
log "control round: $R"
case "$R" in
    *torn=0*) fail "control: the unlocked copy was not logged as torn -- the copy did not meet the edit" ;;
    *torn=*) pass "control: with the copy unlocked, the block was copied mid-replace and failed its checksum" ;;
    *) fail "control: unexpected result ($R)" ;;
esac

AFTER="$(python3 -c 'import os, sys; v = os.getxattr(sys.argv[1], "user.k"); print("ok" if v == b"B" * 64 else "bad")' "$F")"
if [ "$AFTER" = ok ]; then pass "after the edit the value is the replacement"; else fail "after the edit the value is wrong"; fi
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -qE '^ERR' <<<"$OUT"; then fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"; else pass "fsck clean"; fi
ct_exit
