#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a run released between the scrub's verdict and its free is not freed from under the file that used it
#
# The scrub decides which blocks are leaked (pass 2, a fresh reference
# set) and then frees them. A live reservation -- a file's speculative
# run, a defrag's destination -- is exempt, checked at the moment of the
# free. But a run that is RELEASED in between has, by then, become the
# file's data: written into, published at close or committed by the
# defrag, and only then taken off the registry. The verdict predates the
# references, the exemption is gone, and the scrub frees blocks a file
# is using (CLAUDE.md rule 15: what runs between the check and the act).
# Nothing else catches it: consuming a reserved block allocates nothing,
# so the per-group allocation count the scrub watches does not move.
#
# The suite holds the scrub between its verdict and its frees
# (scrub_verdict_stall_ms) and, in that window, writes into an open
# file's run and closes the file.
#
# DISCRIMINATION (measured on the unfixed code): the scrub frees the
# written blocks and fsck reports them referenced but marked FREE.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 scrubrel)"
MNT="$(ct_mnt scrubrel)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set auto_defrag 0
ct_param_set alloc_run_blocks 256
ct_param_set alloc_run_max_blocks 256
ct_param_set scrub 0
ct_param_set scrub_interval_secs 2 # scheduled at mount: set before it
ct_param_set scrub_gap_secs 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
reclaim() { sed -n 's/^scrub_reclaimed: //p' "$PROC"; }

# An open file holding a run: one block written, 255 reserved behind it.
exec 7<>"$MNT/vm.img"
python3 -c 'import os,sys; os.pwrite(int(sys.argv[1]), b"a" * 4096, 0); os.fsync(int(sys.argv[1]))' 7
sync

R0="$(reclaim)"
DM="$(dmesg_mark)"
ct_param_set scrub_verdict_stall_ms 4000
ct_param_set scrub 1
wait_for 20 "dmesg_since '$DM' | grep -q 'scrub: holding the verdict'" ||
    { fail "setup: the scrub never reached its verdict"; exec 7>&-; ct_exit; }
pass "setup: the scrub has decided and is holding before its frees"

# In the window: the run becomes data, and the file is closed.
python3 -c '
import os, sys
for i in range(1, 33):
    os.pwrite(int(sys.argv[1]), bytes([i]) * 4096, i * 4096)' 7
exec 7>&-

wait_for 20 "dmesg_since '$DM' | grep -q 'scrub: verdict released'" || fail "setup: the scrub never resumed"
sleep 1
ct_param_set scrub 0
ct_param_set scrub_verdict_stall_ms 0
log "scrub reclaimed $(($(reclaim) - R0)) block(s) after the window"

bad="$(python3 - "$MNT/vm.img" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print(sum(1 for i in range(33) if d[i * 4096:(i + 1) * 4096] != (b"a" if i == 0 else bytes([i])) * 4096))
PY
)"
[ "$bad" = 0 ] && pass "the file reads back intact" || fail "$bad block(s) of the file read back wrong"
ct_umount "$MNT"
rc=0
fo="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean: no block the file uses was freed" ||
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$fo" | head -1)"
ct_exit
