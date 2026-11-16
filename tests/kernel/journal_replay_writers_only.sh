#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock: a live READER does not keep a dead node's journal entry back
#
# Replay keeps an entry whose file a live node has open (audit 2026-11-15
# M-20), so the live node's writes cannot be buried under the dead node's
# older image. But presence did not tell a reader from a writer, and a
# reader cannot write the block: one node merely reading a VM image held
# the dead node's redo -- and the open of its file elsewhere -- back for
# as long as it read (F-37). A nofilelock write-open now also publishes
# its bit in write_open_nodes, and only a writer (or a suspended writer,
# or a lock holder) keeps the entry.
#
#   W. this node's write-open sets its writer bit, a read-open does not,
#      and the last writer's close clears it while a reader keeps the
#      presence;
#   R/X/K. node 1 dead with an entry for v's leaf; node 2 live with v
#      open for READ: redone; for WRITE: kept; holding the lock: kept.
#
# DISCRIMINATION: open_writer_bit_off=1: W's write-open sets no bit.
# journal_any_opener=1 (any opener counts, as before): R is kept.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LFPOKE="$(ct_helper leaf_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt jrwo)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set journal_live_opener_off 0
ct_param_set journal_any_opener 0
ct_param_set open_writer_bit_off 0
ct_param_set hb_replay_sweep_off 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }
sha() { dd if="$1" bs=4096 skip="$2" count=1 status=none | sha256sum | cut -d' ' -f1; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
wo() { "$LPOKE" "$DEV" --wo "$1" | sed -n 's/^writers=\(0x[0-9a-f]*\) readers=\(0x[0-9a-f]*\)$/w\1r\2/p'; }

# <tag> <writer_bit_off> -> RES: the record's masks at each step
round_w() {
    local img ino a b c d
    img="$(ct_image 560 "jrwo$1")"
    DEV="$(ct_loop "$img")"
    ct_mkfs "$DEV" -z 1 -f >/dev/null
    nfmount "$DEV" "$MNT"
    echo x >"$MNT/f"
    sync
    ino="$(stat -c %i "$MNT/f")"
    echo "$2" >$P/open_writer_bit_off
    exec 7<"$MNT/f"
    a="$(wo "$ino")"   # reader only
    exec 8>>"$MNT/f"
    b="$(wo "$ino")"   # reader + writer (the bit set on its own)
    exec 8>&-
    c="$(wo "$ino")"   # the writer closed, the reader stays
    exec 7<&-
    exec 8>>"$MNT/f"
    d="$(wo "$ino")"   # a first opener that writes (the bit in the presence swap)
    exec 8>&-
    echo 0 >$P/open_writer_bit_off
    RES="read=$a rw=$b closed=$c first=$d end=$(wo "$ino")"
    umount "$MNT"
}

# <tag> <reader|writer|lock> <any_opener 0|1> -> RES
round_r() {
    local img dir ino p a b ent ph mark k0 now
    img="$(ct_image 560 "jrwo$1")"
    DEV="$(ct_loop "$img")"
    dir="$(ct_tmp "jrwo-$1")"
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
    poke_dead_peer "$DEV" 2 bb
    "$(ct_helper node_poke)" "$DEV" 2 --mode 2 >/dev/null
    case "$2" in
        reader) "$LPOKE" "$DEV" "$ino" --reader 2 >/dev/null ;;
        writer) "$LPOKE" "$DEV" "$ino" --writer 2 >/dev/null ;;
        lock) "$LPOKE" "$DEV" "$ino" 2 1 >/dev/null ;;
    esac
    blockdev --flushbufs "$DEV"
    echo "$3" >$P/journal_any_opener
    echo 1 >$P/hb_replay_sweep_off # held off until node 2 beats
    mark="$(dmesg_mark)"
    nfmount "$DEV" "$MNT"
    ct_beat_row "$DEV" 2
    k0="$(info journal_replay_live_kept)"
    echo 0 >$P/hb_replay_sweep_off
    wait_for 60 "dmesg_since '$mark' | grep -q 'journal replay: node 1\|is open on a live node'" ||
        { fail "setup: the sweep never reached node 1's journal"; ct_exit; }
    sleep 2
    RES="kept=$(($(info journal_replay_live_kept) - k0))"
    ct_unbeat
    echo 0 >$P/journal_any_opener
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    reset_stale_window
    now="$(sha "$img" "$p")"
    if [ "$now" = "$(sha256sum <"$b" | cut -d' ' -f1)" ]; then now=applied
    elif [ "$now" = "$(sha256sum <"$a" | cut -d' ' -f1)" ]; then now=untouched
    else now=other; fi
    RES="$RES leaf=$now"
}

round_w w 0
W="$RES"
log "W: $W"
round_w wc 1
WC="$RES"
log "W control (no writer bit): $WC"
round_r r reader 0
R="$RES"
log "R (node 2 reads v): $R"
round_r x writer 0
X="$RES"
log "X (node 2 writes v): $X"
round_r k lock 0
K="$RES"
log "K (node 2 holds v's lock): $K"
round_r c reader 1
C="$RES"
log "R control (any opener counts): $C"

[ "$(get read "$W")" = w0x0r0x1 ] && pass "W: a read-open sets no writer bit" || fail "W: $W"
[ "$(get rw "$W")" = w0x1r0x1 ] && pass "W: a write-open beside a reader sets it" || fail "W: $W"
[ "$(get closed "$W")" = w0x0r0x1 ] &&
    pass "W: the last writer's close clears it, the reader keeps the presence" || fail "W: $W"
[ "$(get first "$W")" = w0x1r0x1 ] && pass "W: a first opener that writes sets both in one swap" || fail "W: $W"
[ "$(get end "$W")" = w0x0r0x0 ] && pass "W: nothing left once all closed" || fail "W: $W"
[ "$(get rw "$WC")" = w0x0r0x1 ] && [ "$(get first "$WC")" = w0x0r0x1 ] &&
    pass "W control: with the bit off, a write-open reads as a reader" ||
    fail "W control: the bit was set anyway -- the suite does not reach the publish: $WC"
[ "$(get leaf "$R")" = applied ] && [ "$(get kept "$R")" = 0 ] &&
    pass "R: a live reader does not keep the entry -- redone" || fail "R: $R"
[ "$(get leaf "$X")" = untouched ] && [ "$(get kept "$X")" -ge 1 ] &&
    pass "X: a live writer keeps it -- the leaf untouched" || fail "X: $X"
[ "$(get leaf "$K")" = untouched ] && [ "$(get kept "$K")" -ge 1 ] &&
    pass "K: a live lock holder keeps it" || fail "K: $K"
[ "$(get leaf "$C")" = untouched ] &&
    pass "R control: as before, the reader kept the entry" ||
    fail "R control: redone without the change -- the suite does not reach it: $C"
ct_exit
