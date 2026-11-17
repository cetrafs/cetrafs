#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the heartbeat and stale-window module params reach a mount bounded, and setting them does not taint
#
# hb_interval_secs and stale_secs are the persistent defaults an
# operator sets in modprobe.d (README: a multipath queue longer than the
# default window needs a longer stale_secs), and the knobs the suites
# compress timing with. They used to be taken by every later mount as
# written: stale_secs=0 judged every peer dead at the floor of its
# advertised interval, and a large hb_interval_secs overflowed
# `secs * 1000` (audit 2026-11-05, N5).
#
# A mount takes the value clamped: 0/0 becomes a 1 s beat and a 3 s
# window; an overflowing beat and window become 30 s and 86400 s. The
# beat is capped where the controls file caps it, 30 s, because every
# observer clamps an advertised beat there: a 60 s beat with a 120 s
# window had peers call the node dead after max(120, 4 x 30) = 120 s
# while its lease ran 180 (audit 2026-11-14 C2). And the pair is held to
# the controls file's rule, stale >= 3 beats. Setting either is ordinary configuration: no TEST ONLY line, no
# kernel taint (0.9.4 tainted, which made the README's own advice taint
# every node that followed it).
#
# DISCRIMINATION: proven 2026-11-05 with unclamped seeding: the mount
# reports stale_secs 0 and the overflowing beat as written; with the
# per-value clamp alone, 3600/120 reaches the mount as 120. The 30 s cap
# proven 2026-11-14: with 3600, 60/120 reaches the mount as 60/180. The no-taint
# assertions fail against 0.9.4's cetrafs_test_param() declarations.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 tpb)"
MNT="$(ct_mnt tpb)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
PROC=""
info() { sed -n "s/^$1: //p" "$PROC/controls"; }

MARK="$(dmesg_mark)"
T0="$(cat /proc/sys/kernel/tainted)"
ct_param_set stale_secs 0
ct_param_set hb_interval_secs 0
dmesg_since "$MARK" | grep -qE "TEST ONLY parameter (stale_secs|hb_interval_secs)" &&
    fail "setting stale_secs/hb_interval_secs is logged as a TEST ONLY knob" ||
    pass "setting stale_secs/hb_interval_secs is not logged as a TEST ONLY knob"
if [ $((T0 & 64)) -ne 0 ]; then
    log "the kernel was already tainted (TAINT_USER) before these writes; the taint check proves nothing here"
else
    [ $(($(cat /proc/sys/kernel/tainted) & 64)) -eq 0 ] && pass "setting them does not taint the kernel" ||
        fail "setting stale_secs/hb_interval_secs tainted the kernel (TAINT_USER)"
fi
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
[ "$(info stale_secs)" = 3 ] && pass "stale_secs=0 reaches the mount as the 3 s floor" ||
    fail "stale_secs=0 reached the mount as $(info stale_secs)"
[ "$(info hb_interval_secs)" = 1 ] && pass "hb_interval_secs=0 reaches the mount as 1 s" ||
    fail "hb_interval_secs=0 reached the mount as $(info hb_interval_secs)"
ct_umount "$MNT"

# A window above 240 s is refused at the write since BM-41 (eacb980) --
# no peer honours one -- so the mount-side cap is reached only past that
# refusal, through its TEST ONLY switch.
(echo 4294967295 >/sys/module/cetrafs/parameters/stale_secs) 2>/dev/null &&
    fail "stale_secs=4294967295 was accepted at the write" ||
    pass "stale_secs above 240 is refused at the write"
ct_param_set stale_param_unbounded 1
ct_param_set stale_secs 4294967295
ct_param_set hb_interval_secs 4294967
ct_mount "$DEV" "$MNT"
[ "$(info hb_interval_secs)" = 30 ] && pass "an overflowing hb_interval_secs is capped at 30" ||
    fail "hb_interval_secs=4294967 reached the mount as $(info hb_interval_secs)"
[ "$(info stale_secs)" = 86400 ] && pass "an enormous stale_secs is capped at 86400" ||
    fail "stale_secs=4294967295 reached the mount as $(info stale_secs)"
ct_umount "$MNT"

ct_param_set stale_param_unbounded 0
ct_param_set stale_secs 120
ct_param_set hb_interval_secs 60
ct_mount "$DEV" "$MNT"
[ "$(info hb_interval_secs)" = 30 ] && [ "$(info stale_secs)" = 120 ] &&
    pass "hb_interval_secs=60 reaches the mount as the 30 s every observer clamps an advertised beat to" ||
    fail "hb_interval_secs=60 with stale_secs=120 reached the mount as $(info hb_interval_secs)/$(info stale_secs) -- a beat peers clamp, a lease they do not"
ct_umount "$MNT"

ct_param_set stale_secs 60
ct_param_set hb_interval_secs 30
ct_mount "$DEV" "$MNT"
[ "$(info stale_secs)" = 90 ] && pass "a window under three beats is raised to fit them (30/60 -> 90)" ||
    fail "hb_interval_secs=30 with stale_secs=60 reached the mount as a $(info stale_secs) s window"
ct_umount "$MNT"
ct_exit
