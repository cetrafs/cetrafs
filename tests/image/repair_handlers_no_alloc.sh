#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the repair tools' signal handlers never call the heap allocator
#
# fsck -r and growfs renew their registry claim from a SIGALRM handler
# and release it from a SIGTERM/SIGINT/... handler. Both read the row
# through cetrafs_pread_device(), which on a block device took its
# bounce buffer from posix_memalign() and gave it back with free() on
# every call (and formatted a path with snprintf() on first use). The
# renewal tick fires every 5 s whatever the main line is doing; one that
# lands inside the main line's malloc() or free() -- fsck and growfs
# allocate constantly -- re-enters the allocator: heap corruption or a
# deadlock, and in the stop handler, which runs with every signal
# blocked, a hang only SIGKILL ends (audit 2026-11-22 N-2).
#
# A preload shim (sigalloc_shim.c) runs every installed handler inside a
# trampoline and reports any allocator call made inside one. On a loop
# device, so the reads take the O_DIRECT path:
#   1. fsck -r is held in a quiet phase for 12 s; setup: the renewals
#      ran (hb_seq moved), and none of them called the allocator;
#   2. a second fsck -r is stopped with SIGTERM while held; setup: the
#      claim was released, and the stop handler called no allocator.
#
# DISCRIMINATION (measured on the unfixed code): both checks report
# "SIGALLOC posix_memalign" and "SIGALLOC free".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
NPOKE="$(ct_helper node_poke)"
SHIM="$CT_BUILD/sigalloc_shim.so"
mkdir -p "$CT_BUILD"
if [ ! -f "$SHIM" ] || [ "$CT_TESTS/helpers/sigalloc_shim.c" -nt "$SHIM" ]; then
    cc -shared -fPIC -O1 -o "$SHIM" "$CT_TESTS/helpers/sigalloc_shim.c" -ldl ||
        { fail "setup: cannot build the preload shim"; ct_exit; }
fi

IMG="$(ct_image 560 sigalloc)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" >/dev/null
blockdev --flushbufs "$DEV"
hbseq() { sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p' <<<"$("$NPOKE" "$IMG" 0)"; }
state() { sed -n 's/.*state=\([0-9]*\).*/\1/p' <<<"$("$NPOKE" "$IMG" 0)" | head -1; }
ERR1="$(ct_tmp sigalloc1)" ERR2="$(ct_tmp sigalloc2)"

# The shim must see an allocation in a handler at all, or check 1 and 2
# pass on a shim that does nothing.
CTL="$(ct_tmp sigalloc-ctl)"
cat >"$CTL.c" <<'C'
#include <signal.h>
#include <stdlib.h>
#include <string.h>
static void h(int s) { (void) s; free(malloc(16)); }
int main(void) { struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = h; sigaction(SIGUSR1, &sa, 0); raise(SIGUSR1); return 0; }
C
cc -o "$CTL" "$CTL.c"
if LD_PRELOAD="$SHIM" "$CTL" 2>&1 | grep -q "SIGALLOC malloc sig=10"; then
    pass "control: the shim reports an allocation made inside a handler"
else
    fail "control: the shim does not see an allocation inside a handler -- the checks below cannot fail"
    ct_exit
fi

(CETRAFS_TEST_REPAIR_HOLD_SECS=14 LD_PRELOAD="$SHIM" exec "$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>"$ERR1") &
FPID=$!
for _ in $(seq 1 40); do [ "$(state)" = 2 ] && break; sleep 0.25; done
S1="$(hbseq)"
sleep 11 # two renewal ticks
S2="$(hbseq)"
wait "$FPID" || true
blockdev --flushbufs "$DEV"
if [ -z "$S2" ] || [ -z "$S1" ] || [ "$S2" -le "$S1" ]; then
    fail "1: setup: hb_seq $S1 -> $S2 while held -- the renewal tick did not run"
elif grep -q SIGALLOC "$ERR1"; then
    fail "1: a renewal tick called the allocator: $(grep -m2 SIGALLOC "$ERR1" | tr '\n' ' ')"
else
    pass "1: the renewal ticks ran (hb_seq $S1 -> $S2) and none called the allocator"
fi

(CETRAFS_TEST_REPAIR_HOLD_SECS=30 LD_PRELOAD="$SHIM" exec "$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>"$ERR2") &
FPID=$!
for _ in $(seq 1 40); do [ "$(state)" = 2 ] && break; sleep 0.25; done
[ "$(state)" = 2 ] || { fail "2: setup: fsck -r's claim never appeared"; kill "$FPID" 2>/dev/null; wait "$FPID" || true; ct_exit; }
sleep 1
kill -TERM "$FPID"
wait "$FPID" || true
blockdev --flushbufs "$DEV"
if [ "$(state)" != 0 ]; then
    fail "2: setup: the claim was not released by the stop handler (state $(state))"
elif grep -q SIGALLOC "$ERR2"; then
    fail "2: the stop handler called the allocator: $(grep -m2 SIGALLOC "$ERR2" | tr '\n' ' ')"
else
    pass "2: SIGTERM released the claim and the stop handler called no allocator"
fi
ct_exit
