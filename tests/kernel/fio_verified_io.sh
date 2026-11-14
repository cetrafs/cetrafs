#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fio: verified buffered and O_DIRECT I/O over a large sparse file (random and sequential, several jobs), re-read after a remount, plus fsck
# ct-timeout: 900
#
# The shape of the VM-datastore workload: several jobs writing and then
# rewriting disjoint regions of ONE large sparse file, some through the
# page cache and some with O_DIRECT, at once, with fio's own verifier
# (crc32c header per block, backlogged) checking every block it wrote.
# tests/kernel/churn_oracle.sh and fsx_model.sh check what the filesystem
# holds against a model; this checks it against fio's headers, at a size
# and queue depth neither of them reaches, and then asks whether the bytes
# are still right after an unmount and a remount.
#
# Layout (the file is sparse between regions):
#   0..128M      buffered random writes, 2 jobs (64M each)
#   512M..832M   O_DIRECT random writes, 2 jobs, queue depth 8 when libaio is present
#   960M..992M   O_DIRECT sequential writes, 1 job
#
# Phases
#   write   every region written once, headers embedded, no verify pass;
#   mix     60/40 random read/write over the same regions, in-run verify,
#           buffered and direct jobs concurrently on the one file;
#   verify  after an unmount and a remount, verify-only over every region;
#   fsck    the volume is clean with the data intact.
#
# NEGATIVE CONTROL: between the positive re-read and a second one, one
# data block of the file is overwritten ON THE DEVICE (the block fio wrote
# at file offset 0). The second verify-only must fail, and must fail with
# fio's verify error, not with a missing file. A verifier that cannot see
# a corrupted block would make the green re-read above mean nothing.
#
# Skips, with the reason, when fio is not installed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
if ! command -v fio >/dev/null 2>&1; then
    skip "fio is not installed (apt install fio) -- nothing here can verify I/O without it"
    ct_exit
fi
require_module

# libaio gives the O_DIRECT jobs a real queue depth. Without it they run
# synchronously, which still covers the same paths at depth one.
DIO_ENGINE=psync
if grep -qw libaio <<<"$(fio --enghelp 2>/dev/null || true)"; then
    DIO_ENGINE=libaio
fi

DEV="$(ct_big_dev 2048 fio)"
MNT="$(ct_mnt fio)"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/fio"
F="$MNT/fio/shared.dat"
FIOWD="$(mktemp -d /tmp/cetrafs-fio-XXXXXX)"
ct_track dir "$FIOWD"
log "fio: engine for O_DIRECT jobs: $DIO_ENGINE"

# job_file <write|mix|verify> -> path of a tracked job file
job_file() {
    local mode="$1" rw_buf rw_dio rw_seq dv extra="" mix=""
    case "$mode" in
    write)
        rw_buf=randwrite; rw_dio=randwrite; rw_seq=write; dv=0 ;;
    mix)
        rw_buf=randrw; rw_dio=randrw; rw_seq=write; dv=1
        mix="rwmixread=60" ;;
    verify)
        rw_buf=randread; rw_dio=randread; rw_seq=read; dv=1
        extra="verify_only=1" ;;
    esac
    local j
    j="$(ct_tmp fio-job)"
    cat >"$j" <<JOB
[global]
ioengine=psync
filename=$F
verify=crc32c
verify_fatal=1
verify_backlog=64
do_verify=$dv
$extra

[buf]
rw=$rw_buf
$mix
bs=4k
size=64m
offset=0
offset_increment=128m
numjobs=2
direct=0

[dio]
ioengine=$DIO_ENGINE
iodepth=8
rw=$rw_dio
$mix
bs=4k
size=64m
offset=512m
offset_increment=256m
numjobs=2
direct=1

[dio-seq]
rw=$rw_seq
bs=65536
size=32m
offset=960m
numjobs=1
direct=1
JOB
    echo "$j"
}

# fio_run <jobfile> -> FIO_RC and FIO_OUT. Run from a scratch directory:
# fio writes its verify state beside the job, and that state is what a
# verify-only pass needs.
fio_run() {
    FIO_RC=0
    FIO_OUT="$(cd "$FIOWD" && timeout -k 10 600 fio --output-format=normal "$1" 2>&1)" || FIO_RC=$?
}

# ------------------------------------------------------------------ write
W="$(job_file write)"
fio_run "$W"
if [ "$FIO_RC" = 0 ]; then
    pass "fio write phase: buffered and O_DIRECT jobs wrote every region"
else
    fail "fio write phase exited $FIO_RC: $(grep -m2 -i 'error\|verify' <<<"$FIO_OUT" | tr '\n' ' ')"
    sed -n '1,20p' <<<"$FIO_OUT" | sed 's/^/    | /'
fi
# Setup: the file must actually span the layout. A sparse file that came
# out a few hundred KiB long means fio wrote somewhere else entirely.
SZ="$(stat -c %s "$F" 2>/dev/null || echo 0)"
[ "$SZ" -eq $((992 * 1048576)) ] &&
    pass "the file spans the whole layout (992 MiB, sparse between regions)" ||
    fail "setup: the file is $SZ bytes, not 992 MiB -- fio did not write the layout it describes"

# -------------------------------------------------------------------- mix
M="$(job_file mix)"
fio_run "$M"
if [ "$FIO_RC" = 0 ]; then
    pass "fio mix phase: 60/40 random read/write, buffered and direct on one file, every read verified in-run"
else
    fail "fio mix phase exited $FIO_RC: $(grep -m2 -i 'verify' <<<"$FIO_OUT" | tr '\n' ' ')"
    sed -n '1,20p' <<<"$FIO_OUT" | sed 's/^/    | /'
fi

# Where the device holds file offset 0, for the negative control. Taken
# while mounted, from the same filefrag the fsck-side tooling uses; -b1
# makes the physical column bytes. The columns are matched by regex, not by
# field number: filefrag glues a wide logical range to its colon ("0..67108863:")
# and that shifts every later field, so a field index parses some runs and not others.
PHYS="$(filefrag -v -b1 "$F" | sed -n 's/^ *0: *0\.\.[ ]*[0-9]*: *\([0-9]*\)\.\..*/\1/p' | head -1)" || true
case "$PHYS" in
'' | *[!0-9]*) fail "setup: could not find the device offset of file offset 0 -- the negative control cannot run" ;;
*) pass "file offset 0 lives at device byte $PHYS" ;;
esac

# ----------------------------------------------------- remount and re-read
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo 3 >/proc/sys/vm/drop_caches
V="$(job_file verify)"
fio_run "$V"
if [ "$FIO_RC" = 0 ]; then
    pass "after an unmount and a remount, verify-only re-reads and verifies every block of every job"
else
    fail "verify-only after a remount exited $FIO_RC: $(grep -m2 -i 'verify' <<<"$FIO_OUT" | tr '\n' ' ')"
    sed -n '1,20p' <<<"$FIO_OUT" | sed 's/^/    | /'
fi

ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && FSCK_RC=0 || FSCK_RC=$?
if [ "$FSCK_RC" = 0 ]; then
    pass "fsck is clean after the fio run"
else
    fail "fsck reports a problem after the fio run: $(grep -m2 -iE 'ERR|problem|leaked|overlap' <<<"$FSCK_OUT" | tr '\n' ' ')"
fi

# ------------------------------------------------------- negative control
# Poke the device, not the file: the next mount reads the device, and a
# poke into the file would be invisible behind whatever the page cache
# still holds. Flush first so no stale device page can land over the poke.
if [ -n "$PHYS" ]; then
    before="$(dd if="$DEV" bs=4096 count=1 skip=$((PHYS / 4096)) status=none | sha256sum | cut -d' ' -f1)"
    dd if=/dev/urandom of="$DEV" bs=4096 count=1 seek=$((PHYS / 4096)) conv=notrunc status=none
    blockdev --flushbufs "$DEV"
    after="$(dd if="$DEV" bs=4096 count=1 skip=$((PHYS / 4096)) status=none | sha256sum | cut -d' ' -f1)"
    if [ "$before" = "$after" ]; then
        fail "setup: the poke did not change the device block -- the control would test nothing"
    fi
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo 3 >/proc/sys/vm/drop_caches
    fio_run "$V"
    if [ "$FIO_RC" != 0 ] && grep -qi 'verify' <<<"$FIO_OUT" && ! grep -qi 'no such file' <<<"$FIO_OUT"; then
        pass "negative control: one corrupted data block was caught by fio's verify (exit $FIO_RC): $(grep -m1 -i 'verify' <<<"$FIO_OUT" | cut -c1-160)"
    else
        fail "negative control NOT caught (exit $FIO_RC): fio's verifier did not report the corrupted block -- $(grep -m1 -i 'verify\|error\|no such' <<<"$FIO_OUT" || echo 'no output')"
    fi
    ct_umount "$MNT"
fi

ct_exit
