#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a cold mark that lands during a reconcile is not settled by it
#
# When a node learns that a peer may have changed a file's layout it
# marks the cached extent tree cold, and a work item drops the tree and
# settles the mark. The settle was a plain "cold = false" at the end of
# the work -- which also cleared any mark that landed WHILE the work
# ran, after its drop. A leaf loaded in that window described the file
# before the peer's change, and was then trusted as current until the
# next reconcile got round to dropping it.
#
# Driven deterministically with cold_work_stall_ms, which holds the work
# before its drop and again before its settle:
#   1. a held O_DIRECT reader caches the victim's leaf;
#   2. a refresh (stat) marks the tree cold -- reconcile W1 starts;
#   3. after W1's drop, the reader reloads the leaf (still the old map);
#   4. the device changes block 0's mapping, and a second stat marks the
#      tree cold again -- W2 is queued behind W1;
#   5. W1 settles; while W2 is still held before ITS drop, the reader
#      reads block 0 again. It must see the device's mapping, not the
#      leaf loaded in step 3.
#
# DISCRIMINATION (measured on the unfixed code): step 5 reads the old
# block through the stale leaf.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/cold_work_stall_ms ] || { skip "cold_work_stall_ms is missing"; ct_exit; }
LEAF_POKE="$(ct_helper leaf_poke)"
EXTENT_POKE="$(ct_helper pending_poke)"

IMG="$(ct_image 560 cmr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt cmr)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

printf 'DONORDONOR' >"$MNT/donor"
sync "$MNT/donor"
DONOR_PHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c '%i' "$MNT/donor")" | cut -d' ' -f1)"
# A spilled (depth-1) victim: five blocks that cannot merge, so block 0
# is mapped through an external leaf the poke can repoint.
for i in 0 1 2 3 4; do
    printf 'VICTIM%04d' "$i" | dd of="$MNT/v" bs=4096 seek="$i" count=1 conv=notrunc 2>/dev/null
    [ "$i" -lt 4 ] && printf x >"$MNT/v_f$i"
done
sync "$MNT/v"
INO="$(stat -c '%i' "$MNT/v")"

# The reader: one O_DIRECT fd held throughout, reading block 0 each time
# a go-file appears, so no open() refreshes anything behind our back.
STEP="$(ct_tmp)"
rm -f "$STEP"
OUT="$(ct_tmp)"
python3 -I - "$MNT/v" "$STEP" >"$OUT" 2>&1 <<'PY' &
import mmap, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
for n in range(3):
    while not os.path.exists("%s.%d" % (sys.argv[2], n)):
        time.sleep(0.02)
    os.preadv(fd, [buf], 0)
    print("read%d %s" % (n, buf[:10].decode(errors="replace")), flush=True)
os.close(fd)
PY
READER=$!
go() { : >"$STEP.$1"; for _ in $(seq 1 100); do grep -q "^read$1 " "$OUT" && return; sleep 0.05; done; }
got() { sed -n "s/^read$1 //p" "$OUT"; }

go 0
[ "$(got 0)" = VICTIM0000 ] || { fail "setup: the first read was '$(got 0)', expected VICTIM0000"; ct_exit; }

S=3000
ct_param_set cold_work_stall_ms "$S"
stat "$MNT/v" >/dev/null # mark 1: W1 holds [0,3s), drops, holds [3s,6s), settles
sleep 4
go 1 # inside W1's second hold: cold, so this reloads the leaf -- the old map
"$LEAF_POKE" "$IMG" setphys "$INO" 0 "$DONOR_PHYS" >/dev/null
stat "$MNT/v" >/dev/null # mark 2, during W1: W2 queued behind it
sleep 3                  # past W1's settle (~6s), inside W2's first hold
go 2
wait "$READER" 2>/dev/null || true
rm -f "$STEP".[0-9] # the harness tracks $STEP only
ct_param_set cold_work_stall_ms 0
# Let W2 finish before anything else touches the file.
sleep $((S * 2 / 1000 + 1))

[ "$(got 1)" = VICTIM0000 ] || { fail "setup: the read inside W1 was '$(got 1)', expected VICTIM0000"; ct_exit; }
pass "setup: a leaf describing the old map was loaded after W1's drop"
[ "$(got 2)" = DONORDONOR ] &&
    pass "a mark during the reconcile kept the tree cold: the read followed the device's map" ||
    fail "the read returned '$(got 2)' through the leaf loaded before the change -- W1 settled a mark it never covered"

# No fsck: block 0 of the victim now shares the donor's block on purpose.
ct_exit
