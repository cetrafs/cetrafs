#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node label off the disk reaches the operator's terminal as text, never as escape sequences
#
# The tools name the node in their messages -- "mounted by another node
# (registry row 1, <label>, ...)" -- and printed the label field raw. It
# is whatever a node wrote, or whatever a damaged or hostile row holds,
# and on a terminal an ESC sequence in it is a command: retitle the
# window, rewrite the line above, worse on some emulators (audit
# 2026-11-11 F12). cetrafs_label_copy() now turns every non-printable
# byte into '?'.
#
#  1. a heartbeating node whose label is an OSC sequence: fsck's and
#     mkfs's refusals name it with no ESC or BEL byte, and as '?'s.
#  2. a stale repair claim with the same label: fsck's WARN about it
#     likewise.
#
# DISCRIMINATION (2026-11-11, devutil.h/fsck.c before this fix): every
# assertion finds the ESC byte in the output.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
export CETRAFS_PEER_PROBE_SECS=3
EVIL=$'\033]0;owned\007'

IMG="$(ct_image 560 label)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
SB="$IMG.sb"; ct_track file "$SB"
dd if="$DEV" of="$SB" bs=4096 count=1 status=none
clean() { # <label> <output>: no ESC, no BEL, and the label's text survives
    if grep -q $'[\033\007]' <<<"$2"; then fail "$1: an ESC/BEL byte reached the output"
    elif grep -q '?]0;owned?' <<<"$2"; then pass "$1: printed as text, '?' for the control bytes"
    else fail "$1: the label is not in the output: $(grep -m1 -E 'ERR|WARN' <<<"$2")"; fi
}

log "1: a live node labelled with an OSC sequence"
"$NPOKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null
"$NPOKE" "$DEV" 1 --label "$EVIL" >/dev/null
bash -c 'for _ in $(seq 1 16); do NODE_POKE_SB="$1" "$2" "$3" 1 --beat >/dev/null 2>&1 || true; sleep 1; done' _ "$SB" "$NPOKE" "$DEV" &
B=$!
OUT="$("$FSCK" "$DEV" 2>&1)" || true
grep -q "is mounted by another node" <<<"$OUT" || { fail "1 setup: fsck did not see the node: $(tail -1 <<<"$OUT")"; ct_exit; }
clean "1: fsck" "$OUT"
OUT="$("$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f 2>&1)" || true
grep -q "is mounted by another node" <<<"$OUT" || { fail "1 setup: mkfs did not see the node: $(tail -1 <<<"$OUT")"; ct_exit; }
clean "1: mkfs" "$OUT"
wait "$B" 2>/dev/null || true

log "2: a stale repair claim with the same label"
"$NPOKE" "$DEV" 1 2 cc $(($(date +%s) - 100000)) >/dev/null
"$NPOKE" "$DEV" 1 --label "$EVIL" >/dev/null
OUT="$("$FSCK" "$DEV" 2>&1)" || true
grep -q "holds a repair claim" <<<"$OUT" || { fail "2 setup: fsck did not report the claim: $(grep -m2 -E 'ERR|WARN' <<<"$OUT")"; ct_exit; }
clean "2: fsck's WARN" "$OUT"
losetup -d "$DEV"
ct_exit
