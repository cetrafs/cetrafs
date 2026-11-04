#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs looks for a mounted node only after its own claim is down
#
# growfs asked the device whether any node was alive, THEN claimed the
# volume. A node mounting between the two passed its own checks (there
# was no claim yet) and was never looked for again: the grow relocated
# the tables that node was allocating from. fsck -r always did it the
# other way round -- claim, then look -- and growfs now does too.
#
# Staged: a live node (a registry row that keeps beating). growfs must
# refuse it, and must have taken its claim before it did -- the order is
# the fix, so the order is what is asserted.
#
# DISCRIMINATION: probing before the claim, growfs refuses without ever
# printing that it claimed a row.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"

IMG="$(ct_image 600 growprobe)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
losetup -d "$DEV"
truncate -s 1200M "$IMG"
DEV="$(ct_loop "$IMG")"
"$NPOKE" "$DEV" 2 1 bb "$(date +%s)" >/dev/null
blockdev --flushbufs "$DEV"
( for _ in $(seq 1 90); do "$NPOKE" "$IMG" 2 --beat >/dev/null 2>&1 || true; sleep 1; done ) &
BEAT=$!
ct_track cmd "kill $BEAT"
H0="$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum)"
rc=0; out="$("$ROOT/userspace/growfs.cetra" "$DEV" 2>&1)" || rc=$?
kill "$BEAT" 2>/dev/null || true; wait "$BEAT" 2>/dev/null || true
H1="$(dd if="$DEV" bs=4096 count=1 status=none | sha256sum)"
log "$(grep -E 'claimed registry row|mounted by another node' <<<"$out" | tr '\n' ' ')"
[ "$rc" != 0 ] && grep -q "mounted by another node" <<<"$out" && pass "growfs refused the volume a live node holds" ||
    fail "growfs did not refuse the live node (rc=$rc): $(tail -1 <<<"$out")"
grep -q "claimed registry row" <<<"$out" && pass "and it looked only after its claim was down" ||
    fail "it looked BEFORE claiming -- a node mounting in between would never be seen"
[ "$H0" = "$H1" ] && pass "the superblock is untouched" || fail "growfs rewrote the superblock of a volume it refused"
"$NPOKE" "$DEV" 2 0 00 0 >/dev/null 2>&1 || true
ct_exit
