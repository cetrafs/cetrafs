#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock: a dead node's presence bit stays until its journal is replayed
#
# Under nofilelock the next open of a file a dead node had open replays
# that node's journal first -- and what sends it there is the dead
# node's presence bit on the file. Any path asking "is a peer using
# this?" (setxattr, truncate, unlink, flock, defrag) cleared a stale
# node's bit after fencing it, journal or no journal. The next open then
# saw nobody, skipped the replay and ran past the dead node's last tree
# writes, and the heartbeat's redo later landed on top of its own (audit
# 2026-11-15 M-20, F-37). The bit now stays, counted as a reader, while
# the dead node's journal is dirty.
#
# Node 1 is dead with one entry for file v's extent leaf and its bit on
# v; the heartbeat's sweep is held off. A setxattr of v by path asks the
# question, then a read-open of v:
#   fixed:   the bit is still there, and the open replays the entry;
#   control: reader_clear_dirty_ok=1 -- the bit cleared, the open
#            replays nothing and the leaf is the dead node's old view.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LFPOKE="$(ct_helper leaf_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt drbr)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set reader_clear_dirty_ok 0
ct_param_set hb_replay_sweep_off 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }
sha() { dd if="$1" bs=4096 skip="$2" count=1 status=none | sha256sum | cut -d' ' -f1; }

# <tag> <clear_dirty_ok 0|1> -> RES
round() {
    local img dir ino p a b ent ph bit now
    img="$(ct_image 560 "drbr$1")"
    DEV="$(ct_loop "$img")"
    dir="$(ct_tmp "drbr-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    nfmount "$DEV" "$MNT"
    dd if=/dev/urandom of="$MNT/v" bs=4096 count=60 conv=fsync status=none
    for i in $(seq 1 2 59); do fallocate -p -o $((i * 4096)) -l 4096 "$MNT/v"; done
    sync
    ino="$(stat -c %i "$MNT/v")"
    umount "$MNT"
    p="$("$IPOKE" "$img" leaf "$ino" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
    [ -n "$p" ] || { fail "setup: v has no external leaf"; ct_exit; }
    a="$dir/a" b="$dir/b"
    dd if="$img" of="$a" bs=4096 skip="$p" count=1 status=none
    ent="$("$LFPOKE" "$img" show "$ino" | awk '$3 == "block=0" { print $2; exit }')"
    ph="$("$LFPOKE" "$img" show "$ino" | awk '$3 == "block=0" { sub("phys=", "", $4); print $4; exit }')"
    "$LFPOKE" "$img" setphys "$ino" "$ent" $((ph + 1)) >/dev/null
    dd if="$img" of="$b" bs=4096 skip="$p" count=1 status=none
    dd if="$a" of="$img" bs=4096 seek="$p" count=1 conv=notrunc status=none
    cmp -s "$a" "$b" && { fail "setup: the dead node's image is the leaf as it is"; ct_exit; }
    compress_timing
    poke_dead_peer "$DEV" 1 aa
    "$(ct_helper node_poke)" "$DEV" 1 --mode 2 >/dev/null
    "$JPOKE" "$DEV" 1 0 "$p" "$b" --guard-current >/dev/null
    "$LPOKE" "$DEV" "$ino" --reader 1 >/dev/null
    blockdev --flushbufs "$DEV"
    echo "$2" >$P/reader_clear_dirty_ok
    echo 1 >$P/hb_replay_sweep_off # only the open may replay
    nfmount "$DEV" "$MNT"
    wait_out_stale_window
    python3 -c 'import os, sys
try: os.setxattr(sys.argv[1], "user.k", b"1")
except OSError: pass' "$MNT/v"
    bit="$("$LPOKE" "$DEV" --sw "$ino" | sed -n 's/.*readers=\(0x[0-9a-f]*\)$/\1/p')"
    cat "$MNT/v" >/dev/null 2>&1 || true
    echo 0 >$P/reader_clear_dirty_ok
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/hb_replay_sweep_off
    reset_stale_window
    now="$(sha "$img" "$p")"
    if [ "$now" = "$(sha256sum <"$b" | cut -d' ' -f1)" ]; then now=applied
    elif [ "$now" = "$(sha256sum <"$a" | cut -d' ' -f1)" ]; then now=untouched
    else now=other; fi
    RES="bit=$bit leaf=$now"
}

round f 0
F="$RES"
log "fixed: $F"
round c 1
C="$RES"
log "control (bit cleared past a dirty journal): $C"
[ "$(get bit "$F")" = 0x2 ] && pass "the dead node's bit outlived the setxattr's check" || fail "fixed: $F"
[ "$(get leaf "$F")" = applied ] && pass "and the open replayed its entry first" || fail "fixed: $F"
[ "$(get bit "$C")" = 0x0 ] && [ "$(get leaf "$C")" = untouched ] &&
    pass "control: as before, the bit was cleared and the open ran past the entry" ||
    fail "control: the hazard did not reproduce -- the suite does not reach it: $C"
ct_exit
