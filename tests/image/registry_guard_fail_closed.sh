#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the live-peer guard FAILS CLOSED when the Node Registry is unreadable
#
# mkfs and fsck -r are the two destructive tools, and the one thing
# standing between them and a volume some OTHER node has mounted is the
# Node Registry scan (devutil.h's cetrafs_find_live_peer). A row that
# could not be READ used to count as "not a live peer" -- an I/O error on
# the registry area silently weakened the destructive-tool gate to
# nothing. "Unreadable" is not "nobody": both tools now refuse (exit 3,
# could-not-examine) when the registry cannot be read.
#
# Real EIO, not a simulation: a device-mapper table serves the volume
# with the registry blocks replaced by the 'error' target. Discrimination:
# the old tools blundered past the guard and died later, mid-operation,
# with a generic write/read failure -- the exit-3 + named-reason
# assertions below fail against them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SB_POKE="$(ct_helper sb_poke)"

command -v dmsetup >/dev/null 2>&1 || skip "dmsetup not available"

IMG="$(ct_image 560 guardio)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

NT_START="$("$SB_POKE" "$DEV" | grep -oP "^node_table_start=\K[0-9]+")"
NT_BLOCKS="$("$SB_POKE" "$DEV" | grep -oP "^node_table_blocks=\K[0-9]+")"
SECT_START=$((NT_START * 8)) # 4KiB blocks -> 512B sectors
SECT_COUNT=$((NT_BLOCKS * 8))
TOTAL=$(blockdev --getsz "$DEV")
DM=cetrafs-guardio-$$

dmsetup create "$DM" <<EOF
0 $SECT_START linear $DEV 0
$SECT_START $SECT_COUNT error
$((SECT_START + SECT_COUNT)) $((TOTAL - SECT_START - SECT_COUNT)) linear $DEV $((SECT_START + SECT_COUNT))
EOF
MDEV=/dev/mapper/$DM

log "mkfs against a volume whose registry reads EIO"
set +e
MK_OUT="$("$ROOT/userspace/mkfs.cetra" "$MDEV" -z 1 -b 512 -J 0 -N 1024 -f 2>&1)"
MK_RC=$?
FS_OUT="$("$ROOT/userspace/fsck.cetra" "$MDEV" 2>&1)"
FS_RC=$?
set -e
dmsetup remove "$DM"

[ "$MK_RC" = 3 ] && echo "$MK_OUT" | grep -q "cannot read its Node Registry" &&
    pass "mkfs refuses up front: cannot prove no peer is mounted (exit 3)" ||
    fail "mkfs did not fail closed (exit $MK_RC):
$MK_OUT"
[ "$FS_RC" = 3 ] && echo "$FS_OUT" | grep -q "cannot read its Node Registry" &&
    pass "fsck refuses up front for the same reason (exit 3)" ||
    fail "fsck did not fail closed (exit $FS_RC):
$FS_OUT"

# And the refusals wrote NOTHING: the volume behind the mapper is intact.
ct_fsck "$DEV" >/dev/null 2>&1 && pass "the underlying volume is untouched (fsck clean)" ||
    fail "the refused tools modified the volume: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -2)"

ct_exit
