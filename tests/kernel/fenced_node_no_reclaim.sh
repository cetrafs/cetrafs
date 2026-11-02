#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a self-fenced node does not fence peers or replay their journals
#
# A node whose own lease was revoked stops writing: every write path
# checks the fence. Reclaiming from a stale peer is writing too -- it
# bumps the peer's registry row and replays its journal over data-region
# blocks -- and the open path only checked the fence for a WRITE open. A
# read-only open of a file whose lock a stale peer held went on to fence
# that peer and replay its journal, from a node its own peers had
# already declared dead and were reclaiming from themselves.
#
# Played on one node: a stale peer (row 1) holding a file's exclusive
# lock, with a live entry in its journal over a zeroed directory block.
# This node is fenced by bumping its own epoch, then opens the file for
# reading. fence_peer_fail keeps the heartbeat's own sweep off node 1
# until this node is fenced (after which the sweep stops by itself).
#
# DISCRIMINATION (measured without the check): node 1's epoch moves and
# its journal entry is written over the directory block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_peer_fail ] || { skip "fence_peer_fail is missing"; ct_exit; }

JPOKE="$(ct_helper journal_poke)"
NODE_POKE="$(ct_helper node_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
EXTENT="$(ct_helper pending_poke)"
IMG="$(ct_image 560 fnr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fnr)"
PAYLOAD="$(ct_tmp fnr-payload)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
: >"$MNT/d/a"
echo content >"$MNT/victim"
sync
XINO="$(stat -c %i "$MNT/d")"
VINO="$(stat -c %i "$MNT/victim")"
ct_umount "$MNT"
BLK="$("$EXTENT" "$IMG" extent "$XINO" | cut -d' ' -f1)"
[ -n "$BLK" ] && [ "$BLK" -gt 0 ] || { fail "setup: no dirent block for directory ino $XINO"; ct_exit; }
blk_sum() { dd if="$DEV" bs=4096 skip="$BLK" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }
epoch() { "$NODE_POKE" "$DEV" "$1" | sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p'; }

dd if="$DEV" of="$PAYLOAD" bs=4096 skip="$BLK" count=1 status=none
dd if=/dev/zero of="$DEV" bs=4096 seek="$BLK" count=1 conv=notrunc oflag=direct status=none
compress_timing
poke_dead_peer "$DEV" 1 aa
"$LOCK_POKE" "$DEV" "$VINO" 1 1 >/dev/null
"$JPOKE" "$DEV" 1 0 "$BLK" "$PAYLOAD" --guard-current >/dev/null
ZERO="$(blk_sum)"

ct_param_set fence_peer_fail 1
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
MARK="$(dmesg_mark)"
"$NODE_POKE" "$DEV" 0 --bump-fence 1 >/dev/null
wait_for 15 "dmesg_since '$MARK' | grep -q SELF-FENCED" || { fail "setup: this node never self-fenced"; ct_exit; }
pass "setup: this node is fenced"
ct_param_set fence_peer_fail 0
wait_out_stale_window
[ "$(blk_sum)" = "$ZERO" ] || { fail "setup: node 1's journal was replayed before the test began"; ct_exit; }
E1="$(epoch 1)"

cat "$MNT/victim" >/dev/null 2>&1 || true
[ "$(epoch 1)" = "$E1" ] && pass "the fenced node did not revoke node 1's lease" ||
    fail "the fenced node bumped node 1's fence epoch ($E1 -> $(epoch 1))"
[ "$(blk_sum)" = "$ZERO" ] && pass "and did not replay node 1's journal" ||
    fail "the fenced node replayed node 1's journal over the directory block"

umount "$MNT" 2>/dev/null || true
ct_exit
