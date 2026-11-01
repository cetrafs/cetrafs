#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node label that fills its field with no NUL is printed as its field, never past it
#
# The Node Registry row's label is a fixed 32-byte field, "NUL-terminated"
# by the convention of whoever wrote it -- and the row is written by
# every peer and by the offline tools. The procfs `cluster` file printed
# it with %s, so a full field ran on into the checksum and whatever
# followed until a zero byte. The row's CRC proves the row is the one
# written, not that its label ends.
#
# Played here by a VALID (restamped) peer row whose label fills the
# field; the label printed must be exactly the field.
#
# DISCRIMINATION (measured on the unfixed code): the printed label is
# longer than 32 bytes.
set -euo pipefail
export LC_ALL=C # byte lengths, and the over-read is binary
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 nodelabel)"
MNT="$(ct_mnt nodelabel)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CL="$(ct_procdir "$DEV")/cluster"

# A live-looking peer in row 1, its label all 'Q', no terminator.
"$NPOKE" "$DEV" 1 1 cd "$(date +%s)" >/dev/null
"$NPOKE" "$DEV" 1 --label Q >/dev/null
out="$(cat "$CL")"
line="$(grep -aE '^node 1:' <<<"$out" || true)"
[ -n "$line" ] && pass "setup: the peer row is listed" ||
    { fail "setup: row 1 is not in the cluster file: $out"; ct_umount "$MNT"; ct_exit; }
lab="$(sed -E 's/.* label=(.*) caps=0x.*/\1/' <<<"$line")"
grep -q '^Q\{32\}' <<<"$lab" && pass "setup: the unterminated label reached the reader" ||
    { fail "setup: label '$lab' is not the poked one"; ct_umount "$MNT"; ct_exit; }
[ "${#lab}" = 32 ] && pass "the label printed is exactly its 32-byte field" ||
    fail "the label printed ran to ${#lab} bytes out of a 32-byte field: $(printf '%q' "$lab")"

# The offline repairer's form of the same row.
"$NPOKE" "$DEV" 1 2 cd "$(date +%s)" >/dev/null
"$NPOKE" "$DEV" 1 --label Q >/dev/null
line="$(grep -aE '^row=1 REPAIR' "$CL" || true)"
lab="$(sed -E 's/.* label=(.*)$/\1/' <<<"$line")"
[ -n "$line" ] && [ "${#lab}" = 32 ] && pass "a REPAIR row's label is printed as its field too" ||
    fail "REPAIR row label: '$(printf '%q' "$lab")' (${#lab} bytes)"

"$NPOKE" "$DEV" 1 0 00 0 >/dev/null
ct_umount "$MNT"

# fsck reports a STALE repair claim the same way, from userspace.
"$NPOKE" "$DEV" 1 2 cd $(($(date +%s) - 3600)) >/dev/null
"$NPOKE" "$DEV" 1 --label Q >/dev/null
out="$(ct_fsck "$DEV" 2>&1 || true)"
line="$(grep -aE 'holds a repair claim' <<<"$out" || true)"
lab="$(sed -E 's/.*ago \((.*)\)$/\1/' <<<"$line")"
[ -n "$line" ] && [ "${#lab}" = 32 ] && pass "fsck prints a stale repair claim's label as its field" ||
    fail "fsck repair-claim label: '$(printf '%q' "$lab")' (${#lab} bytes) from: $(printf '%q' "$line")"
ct_exit
