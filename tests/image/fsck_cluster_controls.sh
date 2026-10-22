#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's cluster-metadata checks really fire
#
# The journal and the pending-free queues are the two structures a
# PEER's crash leaves behind, and fsck is what reads them when nobody is
# running. Both are applied blindly at replay/drain time, so a bad entry
# is not a reporting problem: a journal entry naming block 0 destroys
# the superblock when replay copies its payload there, and a
# pending-free entry naming another ZG's blocks clears bits in a bitmap
# this node does not own.
#
# Three of these had controls already (target out of range, payload CRC,
# wrong ZG). The rest did not. No module, nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
JPOKE="$(ct_helper journal_poke)"
PPOKE="$(ct_helper pending_poke)"
NPOKE="$(ct_helper node_poke)"
CPOKE="$(ct_helper csum_poke)"

IMG="$(ct_image 560 cluster)"
DEV="$(ct_loop "$IMG")"
PAY="$(ct_tmp payload)"
head -c 4096 /dev/zero >"$PAY"

build() { ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null; }

check() { # <label> <expected regex>
    blockdev --flushbufs "$DEV"
    local out rc=0
    out="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" = "0" ]; then
        fail "$1: fsck called the volume CLEAN with the fault injected"
    elif echo "$out" | grep -qE "$2"; then
        pass "$1: detected"
    else
        fail "$1: failed for another reason -- wanted /$2/, got: $(echo "$out" | grep -E '^(ERR|WARN)' | head -2 | tr '\n' ' ')"
    fi
}

log "a healthy volume passes first"
build
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 &&
    pass "the control image is clean before anything is poked" ||
    fail "a freshly-made image is already reported corrupt"

log "journal entries, which replay applies blindly"
build
"$JPOKE" "$DEV" 0 0 0 "$PAY" >/dev/null 2>&1
check "a journal entry targeting block 0" "targets block 0|outside every BG data region"

build
"$JPOKE" "$DEV" 0 0 2000 "$PAY" >/dev/null 2>&1
check "a DIRTY journal is reported" "DIRTY"

log "pending-free entries, which the owner applies blindly"
# lba 0 is how an UNUSED slot is spelled, not a fault -- fsck skips it
# and so does the kernel's drain (zonegroup.c checks `lba == 0` before
# the magic). Asserted because the two must agree: if fsck ever started
# reporting it, every volume with a partly-used queue would be called
# corrupt.
build
"$PPOKE" "$DEV" add 0 0 1 >/dev/null 2>&1
blockdev --flushbufs "$DEV"
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 &&
    pass "a queue slot with lba 0 is read as unused, matching the kernel's drain" ||
    fail "fsck reports an lba-0 slot as a fault; the kernel treats it as empty, so every partly-used queue would fail"

build
"$PPOKE" "$DEV" add 0 2000 0 >/dev/null 2>&1
check "an entry with a zero count" "count 0"

build
"$PPOKE" "$DEV" add 0 99999999 1 >/dev/null 2>&1
check "an entry past the end of the device" "outside every BG data region|names blocks"

log "node registry rows"
build
"$NPOKE" "$DEV" 0 7 ee 0 >/dev/null 2>&1
check "a row in an unrecognized state" "unrecognized state"

ct_exit
