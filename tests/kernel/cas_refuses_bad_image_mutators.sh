#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the node row and Block Group descriptor swaps refuse a sector failing its checksum
#
# cas_refuses_bad_image covers the file-lock mutator. Two more compare-and-
# swap mutators stamp a fresh checksum over the image they are handed: the
# node row (heartbeat renew) and the Block Group descriptor (the free-count
# flush). Each must refuse an image that fails its own checksum, so damage
# is never blessed into a record every checker accepts (class 3, rule 3).
#
# Each part damages one stored checksum on the device behind a live mount
# (csum_poke flips the CRC; the content is untouched) at the point where
# the mutator will read the device image, drives the mutator, and requires:
#   * the refusal is counted as damage ("corruptions" rises), and
#   * fsck still reports the checksum afterwards.
#
# The control, per part, is the same run with that mutator's test knob
# (node_cas_skip_crc, bg_cas_skip_crc) restamping over the damage: fsck
# then finds the sector clean. That is the proof the refusal is what keeps
# the damage visible. (The control does not assert the counter: a READER of
# the same sector may count the damage on its own.)
#
# Staging, per mutator:
#   node  -- the renew reads the row fresh on every beat.
#   bg    -- the descriptor's delta is accrued in memory by a buffered
#            write held open, the descriptor is damaged, and the fsync
#            is the flush. (Damaged before the accrual the allocator's own
#            reader refuses first and no mutator is reached; flushed
#            before the damage there is nothing left to flush.)
#
#   stat  -- the stat publish's mutator (cetrafs_vfs_stat_cas_mutate). Its
#            file sector is read fresh by the publish's own reader, which
#            refuses damage first, so the damage is injected in the
#            mutator's OWN read of the image (stat_mutate_damage_once): the
#            first thing to see it is the mutator. The fsync that publishes
#            must then fail with EUCLEAN and the swap must not land. The
#            control restamps over the damage (stat_mutate_skip_crc) and
#            the fsync succeeds.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CPOKE="$(ct_helper csum_poke)"
for k in node_cas_skip_crc bg_cas_skip_crc; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

# Each part runs on a fresh volume and prints ONE line on stdout:
#   "<corruptions before> <corruptions after> <flagged|clean>"
# Everything else goes to stderr, so the caller can capture that line.
# (Parts run in a command substitution: they must not call fail/pass.)
VOL_N=0
new_vol() { # <tag>: sets IMG DEV MNT INFO
    VOL_N=$((VOL_N + 1))
    IMG="$(ct_image 560 casm$1$VOL_N)"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt casm$1$VOL_N)"
    ct_mkfs_small "$DEV" >/dev/null
    ct_param_set auto_defrag 0
    ct_track mnt "$MNT"
    ct_mount "$DEV" "$MNT" >&2
    require_cetrafs_mount "$MNT" >&2
    INFO="$(ct_procdir "$DEV")/info"
}
corr() { sed -n 's/^corruptions: //p' "$INFO"; }
settle_umount() { ct_umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true; }
# Whether fsck flags damage to a checksum matching $1 (an extended regex).
fsck_flags() {
    local OUT
    OUT="$(ct_fsck "$DEV" 2>&1 || true)"
    if grep -qiE "$1" <<<"$OUT"; then echo flagged; else echo clean; fi
}

node_part() { # <knob>
    new_vol n
    echo seed >"$MNT/seed"
    sync
    local ROW C0 C1
    ROW="$(sed -n 's/^this_node_id: //p' "$INFO")"
    ct_param_set node_cas_skip_crc "$1"
    C0="$(corr)"
    # Our own row, damaged behind the mount: the next heartbeat renew
    # reads it fresh and must refuse it.
    "$CPOKE" "$IMG" node "$ROW" >&2
    blockdev --flushbufs "$DEV"
    sleep 6 # heartbeat renews every 2 s (set in the run below)
    C1="$(corr)"
    ct_param_set node_cas_skip_crc 0
    settle_umount
    echo "$C0 $C1 $(fsck_flags 'node.*(checksum|crc)|(checksum|crc).*node')"
}

bg_part() { # <knob>
    new_vol b
    echo seed >"$MNT/seed"
    sync
    local NBG C0 C1 b
    NBG="$(sed -n 's/^block_group_count: //p' "$INFO")"
    ct_param_set bg_cas_skip_crc "$1"
    C0="$(corr)"
    # The buffered write is held open across the damage: its free-count
    # delta is still accrued in memory when the descriptors are damaged,
    # so the fsync's flush is the first thing to read them.
    python3 - "$MNT/burn" "$CPOKE" "$IMG" "$NBG" >&2 <<'PY'
import os, subprocess, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.write(fd, b"\0" * 4096 * 16)
for b in range(int(sys.argv[4])):
    subprocess.run([sys.argv[2], sys.argv[3], "bg-desc", str(b)], check=True)
os.fsync(fd)
os.close(fd)
PY
    sync
    C1="$(corr)"
    ct_param_set bg_cas_skip_crc 0
    settle_umount
    echo "$C0 $C1 $(fsck_flags 'BG|block.?group.*(checksum|crc)|(checksum|crc).*(BG|block.?group)')"
}

# Compressed timing: the node part sees renews within its sleep, and fsck
# does not wait out a production staleness window for the row a damaged
# departure left REGISTERED (its probe for a free row is the knob below).
compress_timing
export CETRAFS_PEER_PROBE_SECS=3

# stat: the file sector damage is armed for the mutator alone, then one
# fsync publishes. Prints "<fsync errno or 0> <corruptions delta>".
stat_part() { # <knob>
    new_vol s
    ct_param_set stat_mutate_skip_crc "$1"
    ct_param_set stat_mutate_damage_once 1
    local OUT
    OUT="$(python3 - "$MNT/st" 2>&1 <<'PY' || true
import errno, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.pwrite(fd, b"S" * 4096, 0)
try:
    os.fsync(fd)
    print("rc=0")
except OSError as e:
    print("rc=%d" % e.errno)
os.close(fd)
PY
)"
    ct_param_set stat_mutate_damage_once 0
    ct_param_set stat_mutate_skip_crc 0
    local RC
    RC="$(sed -n 's/^rc=//p' <<<"$OUT" | tail -1)"
    settle_umount
    echo "${RC:-none}"
}

# part <name> <function>: the refusal run, then the control run.
part() {
    local R C0 C1 F
    log "$1"
    R="$($2 0)"
    read -r C0 C1 F <<<"$R"
    if [ -z "${F:-}" ]; then
        fail "$1: the part did not run (got '$R')"
        return 0
    fi
    if [ "$C1" -gt "$C0" ] && [ "$F" = flagged ]; then
        pass "$1: the swap refused the damaged sector -- counted as damage ($C0 -> $C1), fsck still flags it"
    else
        fail "$1: no refusal: corruptions $C0 -> $C1, fsck $F"
    fi

    R="$($2 1)"
    read -r C0 C1 F <<<"$R"
    if [ -z "${F:-}" ]; then
        fail "$1 control: the part did not run (got '$R')"
        return 0
    fi
    if [ "$F" = clean ]; then
        pass "$1 control: restamped over the damage, fsck finds the sector clean"
    else
        fail "$1 control: the damage survived the swap ($C0 -> $C1, fsck $F) -- the knob does not reach this mutator"
    fi
}

part "node row (heartbeat renew)" node_part
part "Block Group descriptor (free-count flush)" bg_part

# The stat-publish mutator: refusal is an EUCLEAN from the fsync that
# publishes, the swap does not land; the control's fsync succeeds.
log "stat publish mutator (file sector, checked in the mutator's own read)"
R="$(stat_part 0)"
if [ "$R" = 117 ]; then
    pass "stat publish: the mutator refused the damaged file sector -- fsync returned EUCLEAN"
else
    fail "stat publish: no refusal (fsync returned '$R', expected EUCLEAN=117)"
fi
R="$(stat_part 1)"
if [ "$R" = 0 ]; then
    pass "stat publish control: restamped over the damage, fsync succeeds"
else
    fail "stat publish control: fsync returned '$R' with the check skipped -- the knob does not reach the mutator"
fi

ct_exit
