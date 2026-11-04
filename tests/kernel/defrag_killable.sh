#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag.cetra stops on SIGKILL, between steps, and leaves the file whole
#
# The manual defrag ioctl moves a file a step at a time, pinning it --
# every peer open refused -- for the whole pass, which on a VM image is
# minutes. Its step loop tested only "draining" and "fenced": SIGKILL
# was not looked at, so the tool could not be stopped and the file
# stayed pinned until the pass ended.
#
# Staged: a 1024-extent file (eight steps), defrag_step_delay_ms 3000
# (a ~24 s pass), SIGKILL two seconds in. The tool must be gone within
# about a step, the file's content unchanged, fsck clean.
#
# DISCRIMINATION: without the check the tool runs to the end of the pass.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/defrag_step_delay_ms ] || { skip "defrag_step_delay_ms is missing"; ct_exit; }

IMG="$(ct_image 560 dfkill)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfkill)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
f = os.open(d + "/frag", os.O_WRONLY | os.O_CREAT, 0o644)
g = os.open(d + "/filler", os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(1024):
    os.pwrite(f, bytes([i % 251]) * 4096, i * 4096); os.fsync(f)
    os.pwrite(g, b"f" * 4096, i * 4096); os.fsync(g)
os.close(f); os.close(g)
PY
sync
SUM="$(sha256sum <"$MNT/frag")"
EXT="$(filefrag "$MNT/frag" 2>/dev/null | sed -n 's/.*: \([0-9]*\) extents\? found/\1/p')"
[ "${EXT:-0}" -ge 512 ] || { fail "setup: the file has only ${EXT:-?} extents"; ct_exit; }
pass "setup: a file of $EXT extents"

ct_param_set defrag_step_delay_ms 3000
"$ROOT/userspace/defrag.cetra" "$MNT/frag" >/dev/null 2>&1 &
PID=$!
sleep 2
kill -0 "$PID" 2>/dev/null || { fail "setup: defrag.cetra finished before it could be killed"; ct_exit; }
T0="$(date +%s)"
kill -KILL "$PID"
GONE=""
for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || { GONE=1; break; }; sleep 0.25; done
T="$(( $(date +%s) - T0 ))"
ct_param_set defrag_step_delay_ms 0
wait "$PID" 2>/dev/null || true
[ -n "$GONE" ] && pass "defrag.cetra stopped ${T}s after SIGKILL" ||
    fail "defrag.cetra still running 10 s after SIGKILL -- it cannot be stopped, and the file stays pinned"

[ "$(sha256sum <"$MNT/frag")" = "$SUM" ] && pass "the file's content is unchanged" ||
    fail "the interrupted defrag changed the file's content"
echo more >>"$MNT/frag" && pass "the file opens for write afterwards (not pinned)" || fail "the file is still pinned"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
