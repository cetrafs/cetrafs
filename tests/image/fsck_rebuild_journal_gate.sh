#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r rebuilds no group record that would let a mount reuse an unreplayed node's blocks
#
# fsck -r rebuilt a damaged Zone Group record (unowned) and a damaged
# Block Group descriptor (in the pool when its bitmap is empty) before it
# looked at the journals (audit 2026-11-15 F-49). A mount claims an
# unowned or pooled group at once, while a dead node's journal is
# replayed only once its row is stale -- so the dead node's blocks could
# be reused first, and the one redo prev_checksum cannot refuse (a
# reused block of the same kind) would then land on live data.
#
# Now the journals are read before any rebuild:
#   a. a descriptor whose group an unreplayed entry targets goes to a
#      Zone Group of that entry's node -- a claim of it replays that
#      node first -- never to the pool (control: no entry -> its
#      round-robin ZG1, kept for a discard as every empty group, F-50);
#   b. a Zone Group record is not rebuilt while any entry is unreplayed;
#      a mount skips a damaged record, so "mount once, then fsck -r"
#      is the order (control: no entry -> rebuilt);
#   c. an entry whose target already holds its payload gates nothing
#      (only its consume was lost) -> ZG1, as with no entry.
#
# The node is row 1, registered and silent (fsck's peer probe finds it
# not beating); ZG0 is made its own, so (a) also proves the owner is
# searched for, not taken as BG1's round-robin ZG1.
#
# DISCRIMINATION: with the gate removed from fsck.c, (a) prints "owner
# ZG1" and (b) "rebuilt the record" -- checked by reverting it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
POKE="$(ct_helper csum_poke)"
BG_POKE="$(ct_helper bg_poke)"
ZG_POKE="$(ct_helper zg_poke)"
NODE_POKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 jgate)"
DEV="$(ct_loop "$IMG")"
PAY="$(ct_tmp)"
head -c 4096 /dev/urandom >"$PAY"

# <entry: none|pending|landed> -> volume with row 1 dead, owning ZG0
build() {
    local d tgt
    ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    "$ZG_POKE" "$DEV" 0 1 >/dev/null
    d="$("$BG_POKE" "$DEV" 1 --dump)"
    tgt=$(($(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d") + $(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d") + 3))
    case "$1" in
    pending) "$JPOKE" "$DEV" 1 0 "$tgt" "$PAY" --guard-current >/dev/null ;;
    landed)
        "$JPOKE" "$DEV" 1 0 "$tgt" "$PAY" --guard-current >/dev/null
        dd if="$PAY" of="$DEV" bs=4096 seek="$tgt" count=1 conv=notrunc status=none
        ;;
    esac
    blockdev --flushbufs "$DEV"
}
repair() { "$FSCK" -r "$DEV" 2>&1 || true; }

build pending
"$POKE" "$DEV" bg-desc 1 >/dev/null
blockdev --flushbufs "$DEV"
out="$(repair)"
grep -q "rebuilt the descriptor of BG1: .*owner ZG0" <<<"$out" &&
    pass "a: an unreplayed entry's group went to its node's ZG0, not the pool" ||
    fail "a: $(grep -E 'rebuilt|BG1|ERR' <<<"$out" | head -3 | tr '\n' ' ')"

build none
"$POKE" "$DEV" bg-desc 1 >/dev/null
blockdev --flushbufs "$DEV"
out="$(repair)"
grep -q "rebuilt the descriptor of BG1: .*owner ZG1, " <<<"$out" &&
    pass "a control: with no entry the empty group goes to its round-robin ZG1" ||
    fail "a control: the setup does not reach the round-robin rebuild: $(grep -E 'rebuilt|ERR' <<<"$out" | head -3 | tr '\n' ' ')"

build pending
"$POKE" "$DEV" zg-hot 1 >/dev/null
blockdev --flushbufs "$DEV"
out="$(repair)"
grep -q "ZG1 not rebuilt yet" <<<"$out" && ! grep -q "rebuilt the record of ZG1" <<<"$out" &&
    pass "b: a Zone Group record is not rebuilt while an entry is unreplayed" ||
    fail "b: $(grep -E 'ZG1|ERR' <<<"$out" | head -3 | tr '\n' ' ')"

build none
"$POKE" "$DEV" zg-hot 1 >/dev/null
blockdev --flushbufs "$DEV"
out="$(repair)"
grep -q "rebuilt the record of ZG1" <<<"$out" &&
    pass "b control: with no entry the record is rebuilt" ||
    fail "b control: $(grep -E 'ZG1|ERR' <<<"$out" | head -3 | tr '\n' ' ')"

build landed
"$POKE" "$DEV" bg-desc 1 >/dev/null
blockdev --flushbufs "$DEV"
out="$(repair)"
grep -q "rebuilt the descriptor of BG1: .*owner ZG1, " <<<"$out" &&
    pass "c: an entry already on its target gates nothing" ||
    fail "c: $(grep -E 'rebuilt|BG1|ERR' <<<"$out" | head -3 | tr '\n' ' ')"
ct_exit
