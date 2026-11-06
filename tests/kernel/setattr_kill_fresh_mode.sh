#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write's setuid kill sees a peer's chmod that raced the open
#
# The VFS decides a write's setuid/setgid kill from the IN-CORE mode.
# While a file is open a peer's chmod is refused (presence or the lock),
# but before the open publishes there was a gap: a peer's chmod +s after
# this node's lookup refreshed the inode left the cached mode without
# the bit, and an unprivileged write then kept it -- a setuid file whose
# contents a non-owner had just changed (audit follow-up 2026-11-05).
#
# Two halves, one case each:
#  A. the opener: a write-open re-reads mode/uid/gid after publishing.
#     Staged with open_publish_stall_ms holding the open between lookup
#     and publish while the record is set to 6777 on the device; a write
#     by nobody through that fd must leave 0777.
#  B. the chmod: its swap re-asks the foreign-user check. Staged with
#     setattr_guard_stall_ms holding a chmod between its check and its
#     swap while a foreign presence bit is set on the device; the chmod
#     must fail ETXTBSY and leave the mode as it was.
#
# DISCRIMINATION: proven 2026-11-05 with kmod/file.c without either
# half: A keeps 6777 after the write, B's chmod succeeds (4755).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v python3 >/dev/null || { skip "needs python3"; ct_exit; }
for k in open_publish_stall_ms setattr_guard_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
POKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 skfm)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt skfm)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
OUT="$(ct_tmp skfm-out)"

# --- A: the opener adopts a chmod that landed before its publish
printf 'a' >"$MNT/a"
chmod 0777 "$MNT/a"
sync
AINO="$(stat -c %i "$MNT/a")"
stat "$MNT/a" >/dev/null # the lookup's refresh: in-core 0777
ct_param_set open_publish_stall_ms 1500
python3 - "$MNT/a" >"$OUT" 2>&1 <<'PY' &
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)      # stalls before its publish
os.setgroups([]); os.setgid(65534); os.setuid(65534)   # no CAP_FSETID
os.pwrite(fd, b'z', 0)                       # owes a kill if the mode has it
os.close(fd)
print("OK")
PY
PID=$!
sleep 0.5
"$POKE" "$IMG" setmode "$AINO" 0106777 >/dev/null || { fail "setup: the mode poke failed"; ct_exit; }
wait "$PID" || true
ct_param_set open_publish_stall_ms 0
grep -q '^OK' "$OUT" || { fail "setup: the write-open script did not finish: $(tr '\n' ';' <"$OUT")"; ct_exit; }
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
AM="$(stat -c %a "$MNT/a")"
[ "$(head -c1 "$MNT/a")" = z ] || fail "setup: the unprivileged write did not land"
case "$AM" in
777) pass "A: a write after a raced chmod +s dropped the bits it saw on the device (mode $AM)" ;;
6777) fail "A: the write kept setuid/setgid set by a chmod that landed before the open published (mode $AM)" ;;
*) fail "A: unexpected mode $AM (want 777)" ;;
esac

# --- B: the chmod refuses a peer that opened after its check
printf 'b' >"$MNT/b"
chmod 0644 "$MNT/b"
sync
BINO="$(stat -c %i "$MNT/b")"
ct_param_set setattr_guard_stall_ms 1500
(chmod 4755 "$MNT/b" 2>"$OUT.chmod" && echo OK >>"$OUT.chmod" || echo "RC $?" >>"$OUT.chmod") &
PID=$!
sleep 0.5
"$LPOKE" "$IMG" "$BINO" --reader 5 >/dev/null || { fail "setup: the presence poke failed"; ct_exit; }
wait "$PID" || true
ct_param_set setattr_guard_stall_ms 0
"$LPOKE" "$IMG" "$BINO" --unreader 5 >/dev/null || fail "setup: could not clear the planted presence bit"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
BM="$(stat -c %a "$MNT/b")"
if grep -q "busy" "$OUT.chmod" && [ "$BM" = 644 ]; then
    pass "B: a chmod whose file was opened by a peer after its check was refused (ETXTBSY, mode $BM)"
else
    fail "B: the chmod went through over a peer's new presence: $(tr '\n' ' ' <"$OUT.chmod") mode $BM"
fi

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null && pass "fsck clean" || fail "fsck reported damage"
ct_exit
