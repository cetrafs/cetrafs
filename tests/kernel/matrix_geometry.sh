#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the configuration matrix's overrides produced the geometry and lock mode they name (zone groups, Block Group size, file-lock mode)
# ct-timeout: 300
#
# tests/matrix.sh runs the same suites under different mkfs geometry and
# mount options, through CT_MKFS_EXTRA, CT_IMG_MIN_MB and CT_MOUNT_OPTS.
# A configuration that silently fell back to the default volume would
# show green results that mean nothing about the geometry it names. This
# suite asks the mounted volume itself (/proc/fs/cetrafs/<dev>/info) and
# requires it to match what the configuration asked for.
#
# The expectation is taken from the environment, the way mkfs and mount
# take it: the LAST -z and -b in CT_MKFS_EXTRA win, as getopt makes them,
# and nofilelock in CT_MOUNT_OPTS means the lock is off. Nothing is read
# back from the filesystem to set it.
#
# NEGATIVE CONTROL: a second volume is formatted and mounted WITHOUT the
# overrides, and must be reported as mismatched against the same
# expectation -- whenever the configuration asks for anything other than
# the default (the base configuration has nothing to discriminate and the
# control says so instead of passing).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# The last "-<letter> VALUE" in CT_MKFS_EXTRA, else the default.
want_opt() {
    local want="$2" prev="" tok
    for tok in ${CT_MKFS_EXTRA:-}; do
        [ "$prev" = "-$1" ] && want="$tok"
        prev="$tok"
    done
    echo "$want"
}
EXP_Z="$(want_opt z 1)"
EXP_B="$(want_opt b 512)"
EXP_LOCK=on
case " ${CT_MOUNT_OPTS:-} " in *nofilelock*) EXP_LOCK=off ;; esac
DEFAULTISH=0
if [ "$EXP_Z" = 1 ] && [ "$EXP_B" = 512 ] && [ "$EXP_LOCK" = on ]; then
    DEFAULTISH=1
fi
log "matrix expectation: zone groups=$EXP_Z, Block Group=${EXP_B} MiB, file lock=$EXP_LOCK"

# check_info <procfs info file> -> one line per mismatch, nothing if all match
check_info() {
    local info="$1" got
    got="$(sed -n 's/^zone_group_count: //p' "$info")"
    [ "$got" = "$EXP_Z" ] || echo "zone_group_count is ${got:-missing}, the configuration asks for $EXP_Z"
    got="$(sed -n 's/^bg_size_blocks: //p' "$info")"
    [ "$got" = "$((EXP_B * 256))" ] ||
        echo "bg_size_blocks is ${got:-missing}, the configuration asks for $((EXP_B * 256)) (${EXP_B} MiB of 4 KiB blocks)"
    got="$(sed -n 's/^block_group_count: //p' "$info")"
    [ "${got:-0}" -ge "$EXP_Z" ] ||
        echo "block_group_count is ${got:-missing}, fewer than the $EXP_Z zone group(s) asked for"
    if [ "$EXP_B" -ge 1024 ] && [ "${got:-0}" -lt 2 ]; then
        echo "block_group_count is ${got:-missing}: a ${EXP_B} MiB Block Group configuration needs two Block Groups to mean anything"
    fi
    got="$(sed -n 's/^file_lock: //p' "$info")"
    [ "$got" = "$EXP_LOCK" ] || echo "file_lock is ${got:-missing}, the configuration asks for $EXP_LOCK"
}

# ------------------------------------------------------------- the real volume
DEV="$(ct_big_dev 1536 geom)"
MNT="$(ct_mnt geom)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
MISS="$(check_info "$PROC/info")" || true
if [ -z "$MISS" ]; then
    pass "the mounted volume has the geometry and lock mode the configuration names"
else
    fail "the configuration did not produce what it names: $MISS"
fi
log "volume: $(sed -n 's/^zone_group_count: /zone groups /p;s/^block_group_count: /block groups /p' "$PROC/info" | tr '\n' ' ')"

# ------------------------------------------------------------- the control
if [ "$DEFAULTISH" = 1 ]; then
    skip "negative control: the base configuration asks for the default geometry, so a default volume cannot be told apart from it"
else
    DEV2="$(ct_big_dev 1536 geomctl)"
    MNT2="$(ct_mnt geomctl)"
    # Formatted and mounted the way the suite would WITHOUT the matrix: no
    # CT_MKFS_EXTRA, no CT_MOUNT_OPTS.
    "$ROOT/userspace/mkfs.cetra" "$DEV2" -z 1 -b 512 -J 1 -N 1024 -f >/dev/null
    mount -t cetrafs "$DEV2" "$MNT2"
    ct_track mnt "$MNT2"
    require_cetrafs_mount "$MNT2"
    CMISS="$(check_info "$(ct_procdir "$DEV2")/info")" || true
    if [ -n "$CMISS" ]; then
        pass "negative control: a volume without the overrides is reported as mismatched: $(head -1 <<<"$CMISS")"
    else
        fail "negative control NOT caught: a volume built without the overrides matched a configuration that asks for them"
    fi
fi

ct_exit
