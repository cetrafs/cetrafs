#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# claiming a free Block Group drops every free queued before the claim
#
# A queued free carries its group's free_gen, and the drain applies it
# only while the stamp still matches. The scrub raises free_gen before it
# frees; the claim of a free group did not, so a late queue copy from
# before a release still matched after the group was claimed again --
# by the same Zone Group or any -- and freed a block the new tenure had
# handed to a file (audit 2026-11-14 A8). The claim swap now raises it.
#
# Block Group 1 is made unowned, and its free_gen noted. Block Group 0
# is filled, so the allocator claims 1 and gives its first data block L
# to a file. A late copy of a free of L is then queued under the noted
# stamp, as one from before the claim would be, and a drain runs. fsck must find every referenced block allocated.
#
# DISCRIMINATION: bg_claim_keeps_free_gen leaves the stamp alone, as
# before; the drain then frees L under its file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in bg_claim_keeps_free_gen pf_drain_min_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"
BGPOKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
MNT="$(ct_mnt bcfg)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set alloc_run_blocks 0
ct_param_set bg_claim_keeps_free_gen 0
ct_param_set pf_drain_min_ms 600000
P=/sys/module/cetrafs/parameters

# <keeps 0|1> -> "<BG1 claimed yes|no> <L referenced yes|no> <fsck ERR lines>"
probe() {
    local img dev d st off L gen owner refd out
    img="$(ct_image 1200 "bcfg$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    "$BGPOKE" "$img" 1 --owner 65535 >/dev/null
    d="$("$BGPOKE" "$img" 1 --dump)"
    st="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d")"
    off="$(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d")"
    L=$((st + off))
    gen="$(sed -n 's/.*free_gen=\([0-9]*\).*/\1/p' <<<"$d")" # BG 1's stamp while unowned
    ct_mount "$dev" "$MNT"
    echo "$1" >$P/bg_claim_keeps_free_gen
    dd if=/dev/zero of="$MNT/fill" bs=1M count=600 conv=fsync status=none 2>/dev/null || true
    echo 0 >$P/bg_claim_keeps_free_gen
    # A late copy of a free from before the claim: queued now, under the
    # stamp the group had then.
    "$PP" "$img" add 0 "$L" 1 "$gen" >/dev/null
    owner="$("$MAP" "$img" | awk '$1 == "bg" && $2 == 1 { split($3, a, "="); print a[2] }')"
    # The drain: allocation is a drain point once the interval allows.
    echo 0 >$P/pf_drain_min_ms
    dd if=/dev/urandom of="$MNT/later" bs=4096 count=1 conv=fsync status=none
    echo 600000 >$P/pf_drain_min_ms
    refd=no
    python3 - "$MNT/fill" "$L" <<'PY' && refd=yes
import fcntl, struct, sys
L = int(sys.argv[2]) * 4096
fd = open(sys.argv[1], "rb")
n = 64
buf = bytearray(struct.pack("QQIIII", 0, 2**64 - 1, 0, 0, n, 0) + bytes(56 * n))
fcntl.ioctl(fd, 0xC020660B, buf)
cnt = struct.unpack_from("I", buf, 20)[0]
for i in range(cnt):
    lo, ph, ln = struct.unpack_from("QQQ", buf, 32 + 56 * i)
    if ph <= L < ph + ln:
        sys.exit(0)
sys.exit(1)
PY
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    [ "$owner" = 0 ] && owner=yes || owner=no
    echo "$owner $refd $(grep -c '^ERR' <<<"$out" || true)"
}

read -r C R N <<<"$(probe 0)"
log "claimed=$C, L in the file=$R, fsck ERR lines=$N"
[ "$C" = yes ] && [ "$R" = yes ] || fail "setup: BG 1 claimed=$C, L given to the file=$R -- nothing to protect"
[ "$N" = 0 ] && pass "the free queued before the claim was dropped: fsck clean" ||
    fail "fsck reports $N error(s): the stale free was applied under the file"
read -r C0 R0 N0 <<<"$(probe 1)"
log "control: claimed=$C0, L in the file=$R0, fsck ERR lines=$N0"
[ "$C0" = yes ] && [ "$R0" = yes ] && [ "$N0" -gt 0 ] &&
    pass "control: with the stamp unchanged the drain frees L under its file -- the suite discriminates" ||
    fail "control: claimed=$C0 L=$R0 fsck=$N0 -- the suite cannot tell"
ct_exit
