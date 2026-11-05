#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck reports a suspended-writer mark with no presence bit under it
#
# suspended_writer_nodes says which of a file's read_open_nodes bits are
# a writer handing over rather than a reader, so it is always a subset
# of that mask. A mark left alone reads to the access rule as a writer
# that no node is, and nothing ever clears it; fsck examined neither
# field.
#
# DISCRIMINATION: without the check fsck says nothing about the root
# inode; the control (mark AND presence bit, a real handoff) must stay
# quiet.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 fsckmark)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" >/dev/null

"$LPOKE" "$DEV" 1 --suspended 3 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q 'suspended writers without' <<<"$OUT" &&
    fail "control: a mark WITH its presence bit was reported: $(grep 'suspended writers' <<<"$OUT")" ||
    pass "control: a writer mark over its presence bit is not reported"

"$LPOKE" "$DEV" 1 --mark-only 5 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q 'inode 1 marks node(s) 0x20 as suspended writers without' <<<"$OUT" &&
    pass "a mark with no presence bit under it is reported" ||
    fail "fsck said nothing about a lone suspended-writer mark: $(grep -iE 'WARN|ERR' <<<"$OUT" | head -3)"
ct_exit
