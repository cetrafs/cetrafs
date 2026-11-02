#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# one writer and nobody else, or readers and no writer (docs/internal/BASICS.md)
#
# A read-open was refused while a peer held the write lock, but a
# write-open was NOT refused while a peer was reading: the claim looked at
# lock_mode only, and a reader is just a bit in read_open_nodes. The
# reader then saw the new writer's changes late and partially.
#
# The handoff (flock(LOCK_UN) on a default mount) is why the fix needs a
# second mask: the source keeps writing with only a presence bit on the
# device, exactly like a reader. suspended_writer_nodes marks it, so the
# destination may claim past a suspended writer but never past a reader,
# and a reader stays out while a suspended writer still writes.
#
# Peers are simulated with registry and record pokes, as read_presence.sh
# does; the races between two real opens run in ctest. Discrimination:
# lock_ignore_readers drops the rule and the refusals below must vanish.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { echo "SKIP: flock(1) not installed"; exit 0; }

LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 access)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt access)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

echo reader-held >"$MNT/r"
echo handed-over >"$MNT/s"
echo own >"$MNT/own"
R_INO="$(stat -c '%i' "$MNT/r")"
S_INO="$(stat -c '%i' "$MNT/s")"
OWN_INO="$(stat -c '%i' "$MNT/own")"

can_open() { # <file> <r|w> -> 0 if open succeeds
    python3 -c "import os,sys; os.close(os.open(sys.argv[1], os.O_RDONLY if sys.argv[2]=='r' else os.O_RDWR))" "$1" "$2" 2>/dev/null
}

# Node 1: a live peer reading 'r', and a live peer handing 's' over.
umount "$MNT"
"$LOCK_POKE" "$DEV" "$R_INO" --reader 1 >/dev/null
"$LOCK_POKE" "$DEV" "$S_INO" --suspended 1 >/dev/null
ct_mount "$DEV" "$MNT"
# After the mount: a row nobody has watched yet reads alive (read_presence.sh).
"$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null

log "a peer is reading"
can_open "$MNT/r" w &&
    fail "a write-open succeeded while a live peer has the file open for read" ||
    pass "write-open refused while a live peer reads"
can_open "$MNT/r" r && pass "a read-open still succeeds (readers share)" ||
    fail "a read-open was refused next to another reader"

log "a peer suspended its write lock for a handoff and still writes"
can_open "$MNT/s" r &&
    fail "a read-open succeeded while a peer is still writing (suspended for a handoff)" ||
    pass "read-open refused while a suspended writer is handing the file over"
can_open "$MNT/s" w && pass "the handoff's destination can still claim the file for write" ||
    fail "write-open refused past a SUSPENDED writer -- the handoff is broken"

log "control: with the rule off, the same opens go through"
ct_param_set lock_ignore_readers 1
can_open "$MNT/r" w && pass "control: write-open past a reader succeeds with lock_ignore_readers" ||
    fail "control: still refused with the rule off -- something else refuses it, the case proves nothing"
can_open "$MNT/s" r && pass "control: read-open past a suspended writer succeeds with lock_ignore_readers" ||
    fail "control: still refused with the rule off -- the case proves nothing"
ct_param_set lock_ignore_readers 0
"$NODE_POKE" "$DEV" 1 0 cc 0 >/dev/null 2>&1 || true

log "this node's own suspend marks it as a writer, and resume and close clear it"
sw() { "$LOCK_POKE" "$DEV" --sw "$OWN_INO"; }
exec 9<>"$MNT/own"
flock -u 9
case "$(sw)" in
    "suspended=0x1 readers=0x1") pass "suspend: presence published AS a writer" ;;
    *) fail "suspend left '$(sw)', expected suspended=0x1 readers=0x1" ;;
esac
flock -x -n 9
case "$(sw)" in
    "suspended=0x0 readers=0x0") pass "resume: the writer mark and presence are gone" ;;
    *) fail "resume left '$(sw)'" ;;
esac
flock -u 9
exec 9<&-
case "$(sw)" in
    "suspended=0x0 readers=0x0") pass "close while suspended: nothing left behind" ;;
    *) fail "close while suspended left '$(sw)'" ;;
esac

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null && pass "fsck clean" || fail "fsck reported errors"

ct_exit
