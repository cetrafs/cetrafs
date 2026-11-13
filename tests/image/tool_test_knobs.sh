#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the tools' test-only environment knobs are never silent and never unbounded
#
# fsck, growfs and the shared devutil code honour a dozen CETRAFS_TEST_*
# variables. They were read with getenv + atoi: a malformed value became
# whatever atoi made of it ("-1" hold seconds = a 136-year sleep holding
# a repair claim, "1x" a real shift), and nothing in the output said a
# knob was in effect -- CETRAFS_PEER_PROBE_SECS shrinks the live-peer
# window, and a production run inheriting it from a test shell looked
# normal (audit 2026-11-11 G2). Now every knob goes through
# cetrafs_test_env(): announced on stderr, and a numeric one outside
# its range refuses the run with exit 2.
#
#  1. fsck -r with a negative hold refuses (exit 2), at once, and
#     releases its claim (a plain fsck afterwards is clean).
#  2. growfs with a malformed shift refuses (exit 2) and grows nothing.
#  3. a set boolean knob is announced on stderr, once.
#  4. a well-formed knob still works: the hold holds.
#  5. a knob that damages the volume (growfs CLOBBER_*, SKIP_BG_HEADERS,
#     NO_AGGREGATE) refuses the run on anything but an image file, a
#     loop device or a dm stack over loops; on a loop device it runs.
#
# DISCRIMINATION (2026-11-11, devutil.h/fsck.c/growfs.c before this
# fix): 1 sleeps until the timeout (124); 2 reads "1x" as a shift of 1
# BG and goes on with it (that grow then dies on its own, exit 1); 3 and
# 4 announce nothing -- five failures.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
FSCK="$ROOT/userspace/fsck.cetra"
GROW="$ROOT/userspace/growfs.cetra"
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 600 knobs)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

log "1: fsck -r, CETRAFS_TEST_REPAIR_HOLD_SECS=-1"
rc=0; OUT="$(CETRAFS_TEST_REPAIR_HOLD_SECS=-1 timeout 20 "$FSCK" -r "$DEV" 2>&1)" || rc=$?
grep -q "claimed registry row" <<<"$OUT" || { fail "1 setup: the repair never reached its claim: $(tail -2 <<<"$OUT")"; ct_exit; }
[ "$rc" = 2 ] && pass "1: refused, exit 2" || fail "1: exit $rc (124 = it slept on atoi(-1))"
grep -q "TEST KNOB CETRAFS_TEST_REPAIR_HOLD_SECS=-1 is not an integer" <<<"$OUT" && pass "1: and says why" ||
    fail "1: no refusal message: $(tail -2 <<<"$OUT")"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "1: the claim was released, plain fsck clean" || fail "1: fsck after the refusal fails"

log "2: growfs, CETRAFS_GROWFS_TEST_BG_OFFSET=1x"
losetup -d "$DEV"; truncate -s 1200M "$IMG"; DEV="$(ct_loop "$IMG")"
BGC0="$("$SBPOKE" "$DEV" | sed -n 's/^block_group_count=//p')"
[ -n "$BGC0" ] || { fail "2 setup: sb_poke prints no block_group_count"; ct_exit; }
rc=0; OUT="$(CETRAFS_GROWFS_TEST_BG_OFFSET=1x timeout 60 "$GROW" "$DEV" 2>&1)" || rc=$?
[ "$rc" = 2 ] && pass "2: refused, exit 2" || fail "2: exit $rc: $(tail -2 <<<"$OUT")"
BGC1="$("$SBPOKE" "$DEV" | sed -n 's/^block_group_count=//p')"
[ "$BGC1" = "$BGC0" ] && pass "2: and grew nothing ($BGC0 BGs)" || fail "2: BG count $BGC0 -> $BGC1 under a malformed knob"
OUT="$("$GROW" "$DEV" 2>&1)" || { fail "2 setup: the clean grow fails: $(tail -2 <<<"$OUT")"; ct_exit; }
BGC2="$("$SBPOKE" "$DEV" | sed -n 's/^block_group_count=//p')"
[ "$BGC2" -gt "$BGC0" ] && pass "2: without the knob it grows ($BGC0 -> $BGC2)" || fail "2: the clean grow left $BGC2 BGs"

log "3: CETRAFS_FSCK_DUMP_REFS=1 is announced, once"
OUT="$(CETRAFS_FSCK_DUMP_REFS=1 "$FSCK" "$DEV" 2>&1 >/dev/null)" || true
N="$(grep -c "TEST KNOB CETRAFS_FSCK_DUMP_REFS=1 is set" <<<"$OUT" || true)"
[ "$N" = 1 ] && pass "3: announced once on stderr" || fail "3: announced $N times"

log "4: CETRAFS_TEST_REPAIR_HOLD_SECS=3 still holds"
s=$(date +%s); OUT="$(CETRAFS_TEST_REPAIR_HOLD_SECS=3 "$FSCK" -r "$DEV" 2>&1)" || true; e=$(date +%s)
[ $((e - s)) -ge 3 ] && pass "4: held $((e - s)) s" || fail "4: held $((e - s)) s"
grep -q "TEST KNOB CETRAFS_TEST_REPAIR_HOLD_SECS=3 is set" <<<"$OUT" && pass "4: and announced it" || fail "4: not announced"

log "5: a knob that damages the volume is refused off a test device"
DMG="damages the volume and is honoured only on"
rc=0; OUT="$(CETRAFS_GROWFS_TEST_CLOBBER_JOURNAL=1 timeout 20 "$GROW" /dev/zero 2>&1)" || rc=$?
[ "$rc" = 2 ] && grep -q "$DMG" <<<"$OUT" && pass "5: refused on a non-test device, exit 2" ||
    fail "5: exit $rc: $(tail -2 <<<"$OUT")"
OUT="$(CETRAFS_GROWFS_TEST_NO_AGGREGATE=1 timeout 60 "$GROW" "$DEV" 2>&1)" || true
! grep -q "$DMG" <<<"$OUT" && grep -q "TEST KNOB CETRAFS_GROWFS_TEST_NO_AGGREGATE=1 is set" <<<"$OUT" &&
    pass "5: honoured, and announced, on a loop device" || fail "5: on the loop device: $(tail -2 <<<"$OUT")"
losetup -d "$DEV"
ct_exit
