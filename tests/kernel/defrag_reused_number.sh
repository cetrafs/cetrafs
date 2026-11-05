#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a queued background defrag never lands on a file that took its inode number
#
# The background defragmenter queues a request naming an inode NUMBER and
# holds no reference to the file. Deleted before the request runs, the
# number goes back to the allocator; the next file created can take it,
# and the worker then defragmented that file -- one nobody asked about,
# rewriting its extents and holding its lock (audit L2). The request now
# carries the generation and a mismatch is skipped.
#
# Staged: the ordered defrag queue is held by a first request
# (auto_defrag_begin_delay_ms), the victim's request queues behind it,
# the victim is deleted and a fragmented file is created on its number,
# with the queueing thresholds raised so that file never asks for a
# defrag itself.
#
# DISCRIMINATION: without the generation check the new file's extents
# are rebuilt (its extent count drops) and no stale request is counted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/auto_defrag_begin_delay_ms ] || { skip "auto_defrag_begin_delay_ms is missing"; ct_exit; }

IMG="$(ct_image 560 dfreuse)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfreuse)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
stale() { sed -n 's/^defrag_stale_requests: //p' "$PROC"; }
extents() { filefrag "$1" 2>/dev/null | sed -n 's/.*: \([0-9]*\) extents\{0,1\} found/\1/p'; }

# frag <name>: six one-block extents, interleaved with a spacer file.
frag() {
    python3 - "$MNT/$1" "$MNT/spacer_$1" <<'PY'
import os, sys
v = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
s = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(6):
    os.pwrite(s, b"s" * 4096, i * 4096); os.fsync(s)
    os.pwrite(v, bytes([65 + i]) * 4096, i * 4096); os.fsync(v)
os.close(s); os.close(v)
PY
}
frag blocker
frag victim
VINO="$(stat -c %i "$MNT/victim")"
S0="$(stale)"

ct_param_set auto_defrag_min_extents 2
ct_param_set auto_defrag_min_pct 0
ct_param_set auto_defrag_begin_delay_ms 6000
ct_param_set auto_defrag 1
: >>"$MNT/blocker"   # its request holds the ordered queue for 6 s
sleep 0.5
: >>"$MNT/victim"    # queued behind it
ct_param_set auto_defrag_begin_delay_ms 0
ct_param_set auto_defrag_min_extents 100000   # nothing else asks from here on

rm -f "$MNT/victim" "$MNT/spacer_victim"
sync
ZNAME=""
for i in $(seq 1 40); do
    : >"$MNT/c$i"
    if [ "$(stat -c %i "$MNT/c$i")" = "$VINO" ]; then ZNAME="c$i"; break; fi
done
[ -n "$ZNAME" ] || { fail "setup: no new file took the victim's inode number $VINO"; ct_exit; }
frag "$ZNAME"   # in place: it keeps the number
E0="$(extents "$MNT/$ZNAME")"
[ "${E0:-0}" -ge 4 ] || { fail "setup: the new file is not fragmented ($E0 extents)"; ct_exit; }
pass "setup: $ZNAME took number $VINO with $E0 extents while the victim's request waited"

sleep 10   # the blocker's 6 s, then the victim's request
ct_param_set auto_defrag 0
E1="$(extents "$MNT/$ZNAME")"
S1="$(stale)"
log "new file extents $E0 -> $E1; stale requests $S0 -> $S1"
[ "$E1" = "$E0" ] && pass "the file that took the number was left alone" ||
    fail "the victim's request defragmented a different file ($E0 -> $E1 extents)"
[ "$S1" -gt "$S0" ] && pass "and the request was counted as stale" ||
    fail "no stale request counted -- did the victim's request run at all?"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
