#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a local write-open under this node's own move pin turns the lock back into a writer's
#
# The background defrag pins an idle file RELOCATING: held only to move
# it, which a peer's open may ask back (cetrafs_lock_wait_yield()). A
# local write-open arriving mid-move found the lock already this node's
# and skipped the claim, so the record went on saying RELOCATING while a
# real writer wrote under it. A peer then asked the move back and waited
# the whole lock_yield_wait_ms for a mover that -- with a local writer
# present -- reads its record cached and never sees the ask, and was
# refused after 10 s, with a warning blaming the move (review of
# a153015). The write-open now swaps the pin to EXCLUSIVE; the last
# writer's close demotes it again while the move runs.
#
# Staged: a 600-block file fragmented against a filler, the janitor
# slowed to one step per 3 s (defrag_step_delay_ms).
#
#  1. the janitor pins the file RELOCATING; a local write-open turns it
#     EXCLUSIVE; that writer's close turns it back to RELOCATING (the
#     move is still running); when the move ends the lock is gone and
#     the content is unchanged.
#  2. control (lock_open_no_promote=1): the write-open leaves it
#     RELOCATING.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in lock_open_no_promote defrag_step_delay_ms auto_defrag; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LPOKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 ownpin)"
MNT="$(ct_mnt ownpin)"
ct_track mnt "$MNT"
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_step_delay_ms 0
ct_param_set lock_open_no_promote 0
mode_of() { "$LPOKE" "$DEV" "$1" | sed -n 's/.*mode=\([0-9]*\).*/\1/p'; }
wait_mode() { # <ino> <mode> <secs>
    local i
    for i in $(seq 1 $(($3 * 4))); do [ "$(mode_of "$1")" = "$2" ] && return 0; sleep 0.25; done
    return 1
}

# <tag>: sets OPENED (mode with the writer open), CLOSED (after its close)
run() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 2 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    python3 - "$MNT/f" "$MNT/filler" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(sys.argv[2], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(600):
    os.pwrite(a, (b"%08d" % i) * 512, i * 4096); os.fsync(a)
    os.pwrite(b, b"f" * 4096, i * 4096); os.fsync(b)
PY
    INO="$(stat -c %i "$MNT/f")"
    SUM0="$(sha256sum "$MNT/f" | cut -d' ' -f1)"
    ct_param_set defrag_step_delay_ms 3000
    ct_param_set auto_defrag 1
    : >>"$MNT/f" # the last writer's close queues the janitor
    wait_mode "$INO" 2 30 || { fail "$1: setup: the janitor never pinned the file RELOCATING (mode $(mode_of "$INO"))"; ct_exit; }
    exec 7>>"$MNT/f"
    sleep 0.5
    OPENED="$(mode_of "$INO")"
    exec 7>&-
    sleep 0.5
    CLOSED="$(mode_of "$INO")"
    ct_param_set defrag_step_delay_ms 0
    wait_mode "$INO" 0 60 || fail "$1: the lock is still held (mode $(mode_of "$INO")) after the move"
    ct_param_set auto_defrag 0
    [ "$(sha256sum "$MNT/f" | cut -d' ' -f1)" = "$SUM0" ] || fail "$1: the content changed"
    ct_umount "$MNT"
    log "$1: RELOCATING -> $OPENED with a local writer -> $CLOSED after its close"
}

# ------------------------------------------------------------------ 2
log "2: control -- the write-open leaves the pin's label"
ct_param_set lock_open_no_promote 1
run control
ct_param_set lock_open_no_promote 0
[ "$OPENED" = 2 ] && pass "control: with a local writer the record still says RELOCATING" ||
    fail "control: the label was $OPENED -- the suite cannot tell the two apart"

# ------------------------------------------------------------------ 1
log "1: a local write-open under the move pin"
run fix
[ "$OPENED" = 1 ] && pass "1: with a local writer the record says EXCLUSIVE" ||
    fail "1: with a local writer the record says $OPENED (2 = RELOCATING)"
[ "$CLOSED" = 2 ] && pass "1: the writer's close hands it back to the move (RELOCATING)" ||
    fail "1: after the writer's close the record says $CLOSED"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
