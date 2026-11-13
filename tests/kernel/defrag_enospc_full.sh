#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag on a full volume refuses with ENOSPC and leaves the file unchanged
#
# The defrag's destination is one contiguous run, reserved (with its span,
# under alloc_mutex) before any block moves: cetrafs_alloc_pick_run_resv(),
# the only ENOSPC site in defrag.c. A full volume must refuse there, before
# anything moved, so the file's bytes and extents are the same afterwards,
# fsck finds no leaked block, and the volume is still usable. Once the
# fillers are removed the same defrag must succeed and collapse the file.
#
# Setup: a 64-block victim interleaved with a pad file (so its extents are
# separated), the pad removed, then the volume filled to ENOSPC. The fill
# must stop on ENOSPC itself; any other error means nothing was arranged.
#
# Scope: the ENOSPC INSIDE the commit (the tree's meta blocks, the publish)
# is not reached: no knob injects ENOSPC there, and the run reservation
# comes first. That route is not covered here. No negative control: the
# refusal is the defrag's own check, and no knob makes it succeed on a full
# volume without moving bytes (a knob that did would be the thing to test).
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "defrag, which nofilelock refuses (no lock to pin)"

DEFRAG="$ROOT/userspace/defrag.cetra"
IMG="$(ct_image 560 defragfull)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt defragfull)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# 64 victim blocks, each followed by a pad block: the victim's extents are
# separated by the pad, then the pad is deleted, leaving 1-block holes.
python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
v = os.open(os.path.join(d, "victim"), os.O_WRONLY | os.O_CREAT, 0o644)
p = os.open(os.path.join(d, "pad"), os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(64):
    os.pwrite(v, bytes([i + 1]) * 4096, i * 4096)
    os.pwrite(p, bytes([0xEE]) * 4096, i * 4096)
os.fsync(v)
os.fsync(p)
os.close(v)
os.close(p)
PY
rm -f "$MNT/pad"
sync
SUM_BEFORE="$(sha256sum "$MNT/victim" | cut -d' ' -f1)"

# Fill the volume with fillers until ENOSPC; any other errno is a failure.
FILL="$(python3 - "$MNT" <<'PY'
import errno, os, sys
d = sys.argv[1]
n = 0
fd = os.open(os.path.join(d, "filler0"), os.O_WRONLY | os.O_CREAT, 0o644)
off = 0
try:
    while True:
        os.pwrite(fd, b"F" * 65536, off)
        off += 65536
        n += 1
except OSError as e:
    print("errno=%s" % errno.errorcode.get(e.errno, e.errno))
    sys.exit(0)
finally:
    os.fsync(fd)
    os.close(fd)
PY
)"
sync
log "fill: $FILL"
if [ "$FILL" != "errno=ENOSPC" ]; then
    fail "setup: the fill did not stop on ENOSPC ($FILL)"
    ct_umount "$MNT"
    ct_exit
fi

# Refused: nonzero, ENOSPC in the text, no byte moved.
OUT="$("$DEFRAG" "$MNT/victim" 2>&1)" && RC=0 || RC=$?
log "defrag on the full volume: rc=$RC $OUT"
if [ "$RC" != 0 ] && grep -qi "no space" <<<"$OUT"; then
    pass "defrag on the full volume refused with ENOSPC before any block moved"
else
    fail "defrag on the full volume: expected a refusal with ENOSPC (rc=$RC, $OUT)"
fi
[ "$(sha256sum "$MNT/victim" | cut -d' ' -f1)" = "$SUM_BEFORE" ] &&
    pass "the victim's bytes are unchanged after the refused defrag" ||
    fail "the victim's bytes changed after a refused defrag"

# Recovery: free the fillers, and the same defrag must now succeed.
rm -f "$MNT"/filler*
sync
OUT="$("$DEFRAG" "$MNT/victim" 2>&1)" && RC=0 || RC=$?
log "defrag after the fillers are gone: rc=$RC $OUT"
EXT_BEFORE="$(sed -n 's/.*extents \([0-9]*\) -> .*/\1/p' <<<"$OUT")"
if [ "$RC" = 0 ] && grep -qE 'extents [0-9]+ -> 1 ' <<<"$OUT" && [ "${EXT_BEFORE:-0}" -ge 5 ]; then
    pass "defrag after the fillers are removed collapsed the victim ($OUT)"
else
    fail "defrag after the fillers are removed did not collapse the victim (rc=$RC, $OUT)"
fi
[ "$(sha256sum "$MNT/victim" | cut -d' ' -f1)" = "$SUM_BEFORE" ] &&
    pass "the victim's bytes are unchanged by the successful defrag" ||
    fail "the victim's bytes changed by the successful defrag"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -qE '^ERR' <<<"$OUT"; then fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"; else pass "fsck clean (no leaked block)"; fi
ct_exit
