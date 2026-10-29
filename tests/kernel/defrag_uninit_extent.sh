#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag never publishes a preallocated extent's stale blocks
#
# fallocate(2) hands a file real blocks that it has never written. They
# read as zeros because the extent carries CETRAFS_EXT_UNINIT -- the
# blocks themselves still hold whatever their previous owner left there.
#
# The online defragmenter is a block-for-block mover that rebuilds the
# moved prefix as one plain, initialized extent. It surveyed the extent
# list through cetrafs_extent_len(), which MASKS the uninit bit off, so a
# preallocated extent was indistinguishable from data: the mover copied
# those blocks to the new run and published them as the file's content.
# Punch a hole, fallocate across it, defrag -- and the punched block came
# back. In general the block's previous owner is another file, which
# makes this disclosure, not just wrongness.
#
# Found by tests/kernel/churn_oracle.sh (reported as "HOLE HOLDS DATA"),
# which is why this suite exists as its own named regression.
#
# Discrimination: defrag_ignore_uninit=1 removes the refusal and nothing
# else. With it, the stale bytes MUST come back -- otherwise the refusal
# is not what protects the data and this suite proves nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PROBE="$(ct_helper uninit_defrag_probe)"
DEV="$(ct_dev 600 dfuninit)"
MNT="$(ct_mnt dfuninit)"

ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

OUT="$("$PROBE" "$MNT/f")"
echo "$OUT" | sed 's/^/    /'
val() { sed -n "s/^$1: //p" <<<"$OUT"; }

[ "$(val before)" = "zeros" ] &&
    pass "setup: the preallocated range over the punched hole reads zeros" ||
    { fail "setup: the range reads '$(val before)' before the defrag -- nothing below means anything"; ct_exit; }

case "$(val defrag)" in
Declined* | declined*) pass "defrag declined the file: $(val defrag)" ;;
*) fail "defrag ran on a file with a preallocated extent: $(val defrag)" ;;
esac

[ "$(val warm)" = "zeros" ] && pass "the preallocated range still reads zeros after the defrag" ||
    fail "the preallocated range reads '$(val warm)' after the defrag -- stale blocks published"
[ "$(val cold)" = "zeros" ] && pass "and still zeros cold, off the device" ||
    fail "the preallocated range reads '$(val cold)' cold -- the stale blocks are ON DISK"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck reports a problem"

# ---------------------------------------- is the refusal what protects it?
if [ -w /sys/module/cetrafs/parameters/defrag_ignore_uninit ]; then
    log "discrimination: defrag the same file with the refusal removed"
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_param_set defrag_ignore_uninit 1
    OUT="$("$PROBE" "$MNT/f")"
    echo "$OUT" | sed 's/^/    /'
    ct_param_set defrag_ignore_uninit 0
    ct_umount "$MNT"

    if [ "$(val cold)" = "data" ]; then
        pass "without the refusal the defrag published the stale blocks -- the refusal is what prevents it"
    else
        fail "even with the refusal removed the range read '$(val cold)' -- the refusal is not what protects the data, something else is"
    fi
else
    skip "defrag_ignore_uninit unavailable -- cannot measure what the refusal contributes"
fi

ct_exit
