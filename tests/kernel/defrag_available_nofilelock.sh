#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# procfs says defrag is unavailable on a nofilelock mount, where every defrag is refused
#
# The controls file showed "defrag: on" on a nofilelock mount, where the
# defragmenter has no file lock to pin and cetrafs_lock_defrag_begin()
# refuses every run -- an operator was told it would work (audit
# 2026-11-06 L26). The switch still reads back as set; a read-only
# defrag_available line beside it says what will happen.
#
# Both mounts: the default one must say yes, the nofilelock one no, and
# defrag.cetra must really be refused there (the line is only worth
# having if it agrees with the refusal).
#
# DISCRIMINATION: without the line, both assertions on it fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
ct_param_set alloc_run_blocks 0

frag() { # a 12-extent file, so a defrag has something to do
    python3 - "$1" "$1.sep" <<'PY'
import os, sys
fds = [os.open(p, os.O_CREAT | os.O_WRONLY, 0o644) for p in sys.argv[1:]]
for i in range(12):
    for f in fds:
        os.pwrite(f, os.urandom(4096), i * 4096)
        os.fsync(f)
for f in fds:
    os.close(f)
PY
}
avail() { sed -n 's/^defrag_available: //p' "$(ct_procdir "$1")/controls"; }

for mode in default nofilelock; do
    DEV="$(ct_dev 560 "dfav$mode")"
    MNT="$(ct_mnt "dfav$mode")"
    ct_mkfs_small "$DEV" >/dev/null
    if [ "$mode" = nofilelock ]; then mount -t cetrafs -o nofilelock "$DEV" "$MNT"; ct_track mnt "$MNT"; else ct_mount "$DEV" "$MNT"; fi
    require_cetrafs_mount "$MNT"
    ct_param_set auto_defrag 0
    grep -q "^defrag: on$" "$(ct_procdir "$DEV")/controls" || fail "$mode: the defrag switch is not on"
    frag "$MNT/f"
    OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/f" 2>&1)" && RAN=1 || RAN=0
    A="$(avail "$DEV")"
    log "$mode: defrag_available='$A', defrag.cetra: $OUT"
    if [ "$mode" = default ]; then
        [ "$RAN" = 1 ] || fail "setup: defrag was refused on a default mount: $OUT"
        [ "$A" = yes ] && pass "default mount: defrag_available says yes, and defrag ran" ||
            fail "default mount: defrag_available is '$A'"
    else
        [ "$RAN" = 0 ] || fail "setup: defrag ran on a nofilelock mount: $OUT"
        case "$A" in
        no*) pass "nofilelock mount: defrag_available says no, and defrag was refused" ;;
        *) fail "nofilelock mount: defrag_available is '$A' while defrag is refused" ;;
        esac
    fi
    ct_umount "$MNT"
done
ct_exit
