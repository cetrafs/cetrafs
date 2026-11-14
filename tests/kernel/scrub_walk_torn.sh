#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub's leaf walk never reads an extent entry half edited
#
# The scrub frees every allocated block its walk does not report, so
# its walk of a file's extent leaf must see each entry whole. An entry's
# front shrink (a conversion of the first block of a preallocated run)
# is three stores: the logical start and length move, then the physical
# start follows. A walk that reads the leaf with no buffer lock, while
# that edit is held half done, sees the new length on the old physical
# start: the run's last block is reported nowhere, and a live,
# bitmap-allocated block with no reference is exactly what the scrub
# frees (CLAUDE.md rule 6).
#
# The walk takes the buffer lock, so an edit in progress is waited out.
# Staging: a spilled leaf of eight preallocated three-block runs. Each
# attempt makes a buffered write of a run's first block and fsyncs it,
# and the conversion that the fsync runs is held half done
# (leaf_front_shrink_stall_ms). The scrub's walks pause between reading
# the leaf and taking the lock (scrub_walk_pause_ms), so an edit that
# starts in that pause is in progress when the walk reads.
#
# The observable is a probe, not a free: scrub_walk_expect_sum prints
# the sum of the extent lengths each walk reports, against the sum the
# leaf holds at rest. A walk that sees the half-moved entry sums to one
# block less. Fix round: no walk ever sums wrong, and some walks ran
# during an edit. Control round (scrub_walk_unlocked): the walk reads
# with no lock, and a walk sums wrong.
#
# Known limit: a walk is only in a race if an edit starts inside a
# pause, and the scrub's cycle is not timed to the edit. Each round makes
# up to four attempts; a round in which no walk ran during an edit fails
# as setup rather than passing.
# ct-timeout: 400
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in scrub_walk_pause_ms scrub_walk_unlocked scrub_walk_expect_sum leaf_front_shrink_stall_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LPOKE="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 scrubwalk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubwalk)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_param_set scrub 1
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_floor_secs 1
ct_param_set scrub_gap_secs 1
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
F="$MNT/victim"

# Eight runs: fallocate of four blocks at 99, 199, ..., 799, the first
# written, so each run of three uninit blocks starts at 100, 200, ...
# Then six written blocks behind spacers: a depth-1 leaf.
python3 - "$MNT" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
v = os.open(sys.argv[1] + "/victim", os.O_RDWR | os.O_CREAT, 0o644)
s = os.open(sys.argv[1] + "/spacer", os.O_WRONLY | os.O_CREAT, 0o644)
for base in range(99, 900, 100):
    if libc.fallocate(v, 0, ctypes.c_long(base * 4096), ctypes.c_long(4 * 4096)):
        sys.exit("fallocate failed: %d" % ctypes.get_errno())
    os.pwrite(v, b"N" * 4096, base * 4096); os.fsync(v)
for i in range(6):
    os.pwrite(s, b"s" * 4096, i * 4096); os.fsync(s)
    os.pwrite(v, (b"%d" % i) * 4096, (i + 900) * 4096); os.fsync(v)
os.close(s); os.close(v)
PY
sync
INO="$(stat -c %i "$F")"
SHOW="$("$LPOKE" "$IMG" show "$INO" 2>&1 || true)"
NENT="$(grep -c '^ent ' <<<"$SHOW" || true)"
# The sum of the lengths at rest, from the device's leaf.
SUM="$(awk '/^ent /{for(i=1;i<=NF;i++) if ($i ~ /^len=/){split($i,l,"="); s+=l[2]}} END{print s+0}' <<<"$SHOW")"
if [ "$NENT" -lt 5 ] || [ "$SUM" -lt 30 ] || ! grep -q 'block=100 .*len=3 .*uninit=1' <<<"$SHOW"; then
    fail "setup: the victim's leaf is not a spilled leaf of runs ($NENT entries, sum $SUM): $(tr '\n' ' ' <<<"$SHOW")"
    ct_exit
fi
pass "setup: a spilled leaf ($NENT entries) whose entries sum to $SUM blocks"

ct_param_set scrub_walk_expect_sum "$SUM"
ct_param_set scrub_walk_pause_ms 1000

# attempt <run start>: one buffered write of the run's first block,
# fsynced with its conversion held half done. Prints "torn=<n> ok=<n>":
# the probe lines of the walks that ran while it was held.
attempt() {
    local MARK OUT T O PID
    MARK="$(dmesg_mark)"
    ct_param_set leaf_front_shrink_stall_ms 3000
    python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.pwrite(fd, b"D" * 4096, int(sys.argv[2]) * 4096)
os.fsync(fd)
os.close(fd)' "$F" "$1" &
    PID=$!
    wait "$PID" || true
    ct_param_set leaf_front_shrink_stall_ms 0
    OUT="$(dmesg_since "$MARK" | grep 'scrub walk probe' || true)"
    T="$(grep -c 'sums to' <<<"$OUT" || true)"
    O="$(grep -c "sums to $SUM," <<<"$OUT" || true)"
    ATT_RES="torn=$((T - O)) ok=$O"
}

# round <unlocked 0|1> <run starts...>: attempts until the runs run out.
# Sets ROUND_OK (walks during an edit that summed right) and ROUND_TORN.
round() {
    local U="$1" b R t o
    shift
    ct_param_set scrub_walk_unlocked "$U"
    ROUND_OK=0; ROUND_TORN=0
    for b in "$@"; do
        attempt "$b"
        R="$ATT_RES"
        t="$(sed -n 's/^torn=\([0-9]*\).*/\1/p' <<<"$R")"
        o="$(sed -n 's/.* ok=\([0-9]*\)$/\1/p' <<<"$R")"
        log "unlocked=$U: edit at block $b: $R"
        ROUND_TORN=$((ROUND_TORN + t))
        ROUND_OK=$((ROUND_OK + o))
    done
    ct_param_set scrub_walk_unlocked 0
}

round 0 100 200 300 400
if [ "$ROUND_OK" -gt 0 ]; then
    pass "the leaf walk ran during the edits ($ROUND_OK walks)"
else
    fail "setup: no leaf walk ran during an edit -- nothing raced"
fi
if [ "$ROUND_TORN" -eq 0 ]; then
    pass "no walk summed a half-moved entry"
else
    fail "$ROUND_TORN walk(s) summed a half-moved entry: the walk read the leaf while an edit was in progress"
fi

round 1 500 600 700 800
if [ "$ROUND_TORN" -gt 0 ]; then
    pass "control: the unlocked walk summed a half-moved entry ($ROUND_TORN walk(s)) -- the probe sees the tear"
else
    fail "control: no unlocked walk summed wrong ($ROUND_OK walks ran during edits) -- the probe does not see the tear"
fi

ct_param_set scrub_walk_pause_ms 0
ct_param_set scrub_walk_expect_sum 0
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -qE '^ERR' <<<"$OUT"; then fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"; else pass "fsck clean"; fi
ct_exit
