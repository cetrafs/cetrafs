#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a stale in-core object for a reused number cannot take the namespace lock the fresh one holds
#
# The namespace-lock acquire treats a record already locked by this node
# as leftover state and takes it back: the per-inode local mutex rules
# out a live local holder. But a reused number can have TWO in-core
# objects -- the stale one kept alive by an open fd, and the fresh one --
# each with its own mutex. The acquire took the generation from the
# record, so the stale object's acquire matched, adopted the lock the
# fresh object's operation held, failed its own generation check and
# released it under that operation (audit 2026-11-06 L5).
#
# Staged on the device: an open fd on f keeps its object; the record is
# then re-stamped as a peer's reuse of the number (new generation) and
# marked locked by THIS node, standing for the fresh object's operation.
# A setxattr through the old fd must fail, and leave the lock where it
# was.
#
# DISCRIMINATION: with the record's generation, the stale setxattr's
# acquire takes the lock and its release clears it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 nsstale)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nsstale)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ME="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
echo x >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
FIFO="$(ct_tmp nsstale-fifo)"; rm -f "$FIFO"; mkfifo "$FIFO"
OUT="$(ct_tmp nsstale-out)"
# Holds the fd open, waits for the go, then setxattrs through it.
python3 - "$MNT/f" "$FIFO" "$OUT" <<'PY' &
import errno, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
open(sys.argv[2]).read()
try:
    os.setxattr(fd, "user.k", b"v")
    r = "ok"
except OSError as e:
    r = errno.errorcode.get(e.errno, str(e.errno))
open(sys.argv[3], "w").write(r)
os.close(fd)
PY
PID=$!
sleep 1
"$IPOKE" "$IMG" reuse "$INO" 99999 7 2>/dev/null
"$LPOKE" "$IMG" "$INO" --ns "$ME" >/dev/null
sync
[ "$("$LPOKE" "$IMG" "$INO" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p')" = "$ME" ] ||
    { fail "setup: the record is not marked locked by this node"; echo go >"$FIFO"; wait "$PID" || true; ct_umount "$MNT"; ct_exit; }
echo go >"$FIFO"
wait "$PID" || true
R="$(cat "$OUT")"
NS="$("$LPOKE" "$IMG" "$INO" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p')"
log "stale setxattr: $R; ns_owner after: $NS"
[ "$R" != ok ] && pass "the stale object's setxattr was refused ($R)" || fail "the stale object's setxattr succeeded on a reused number"
[ "$NS" = "$ME" ] && pass "the lock the fresh object holds is still held" ||
    fail "the stale object released the fresh object's namespace lock (ns_owner=$NS)"
"$LPOKE" "$IMG" "$INO" --ns 65535 >/dev/null # hand it back (NONE) before unmount
ct_umount "$MNT"
ct_exit
