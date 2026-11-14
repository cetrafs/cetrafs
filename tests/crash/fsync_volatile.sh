#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# acknowledged fsync data survives a volatile write cache at the cut
#
# The other crash scenarios replay WRITES IN LOG ORDER up to a barrier,
# so a flush that was never issued still looks durable: nothing in them
# can notice a missing cache flush after the last write of an fsync.
# This one cuts the way a volatile cache does (replay-log
# --volatile-cut-token): every write covered by a later FLUSH/FUA is
# applied, and the writes after the last barrier before the cut are
# dropped, or a seeded random subset of them kept -- in any order, not a
# prefix. Then it reads back what fsync acknowledged.
#
# Three variants, each run as a control and as shipped (FSV_VARIANTS
# restricts the list):
#   fsync            the call the rig was written for;
#   fdatasync        the same workload with fdatasync, which since the
#                    datasync scope no longer publishes the record for
#                    time-only dirt (file.c cetrafs_sync_inode_meta());
#   fdatasync-prealloc
#                    a FALLOCATED file: the rounds write blocks that are
#                    still preallocated, so every round is an uninit-to-
#                    written conversion that the datasync must publish
#                    and that changes neither size nor blocks.
#
# Workload: a 64-block file, fully written and fsynced ("base") -- for the
# prealloc variant only blocks 0..15 are written, the rest of the 64 are
# preallocated. Then six rounds: four random blocks written in place (no
# size change), fsync or fdatasync, then a token write (see workload)
# issued AFTER the call returns. Each token names what must be on the device:
# every block written by rounds up to it, with its latest contents (a
# preallocated block nothing wrote reads as zeros).
#
# The cut at mark ackR is the state an acknowledged fsync must survive:
# with the cut placed after the fsync's last write and before any later
# flush, a fsync whose final cache flush is missing leaves its data in
# the window, and the window is dropped or thinned.
#
#   1. as shipped: every checkpoint, drop and seeded random cuts, reads
#      back exactly its expected blocks and mounts;
#   2. control (fsync_flush_skip=1, TEST ONLY): at least one checkpoint
#      must lose acknowledged data, with a window that held dropped
#      writes -- the setup must have put the call's writes in the window
#      or the suite proves nothing.
#
# Opt-in like the rest of tests/crash (make check-crash).
# ct-timeout: 1200
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm-log-writes 2>/dev/null || true
command -v dmsetup >/dev/null || { skip "dmsetup not found"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/fsync_flush_skip ] || { skip "fsync_flush_skip is missing"; ct_exit; }
command -v python3 >/dev/null || { skip "python3 not found"; ct_exit; }

REPLAY="$CT_BUILD/replay-log"
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || { fail "replay-log build failed"; ct_exit; }
fi
ct_param_set hb_interval_secs 1 # a replayed image's mount watches its row (see crash_consistency.sh)
ct_param_set stale_secs 4

SZ_MB=560
# The device is 64 MiB larger than the filesystem (mkfs -s): the token
# sector lies past the filesystem, where nothing but the token is written.
DM_MB=$((SZ_MB + 64))
SECTORS=$((DM_MB * 1024 * 1024 / 512))
MNT="$(ct_mnt fsvol)"
ct_track mnt "$MNT"
OUT="$CT_BUILD/fsvol-out.$$"
rm -rf "$OUT"
mkdir -p "$OUT"

ROUNDS=6
NBLK=64

# workload <file> <dmdev> <outdir>: records the base file, the rounds and
# a token after each fsync; writes exp-<name> (one "block round" line per
# block). A token is a 4 KiB O_DIRECT write to the last sectors of the
# device, past the filesystem (mkfs -s below), issued after fsync returns.
# dm-log-writes logs data bios in issue order but writes a dmsetup mark
# straight to the log, so a mark is NOT ordered after the data it follows
# (a first version of this rig put the control's marks ahead of its data);
# the token is a data write, so it is.
workload() {
    python3 - "$1" "$2" "$3" "$ROUNDS" "$NBLK" "$SECTORS" "$4" "$5" <<'PY'
import mmap, os, random, sys
path, dmdev, out, rounds, nblk, sectors = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
sync, prealloc = sys.argv[7], sys.argv[8] == "1"
random.seed(11)
call = os.fdatasync if sync == "fdatasync" else os.fsync

def pat(r, b):
    return (b"R%03dB%03d" % (r, b)) * 512          # 4096 bytes

tokfd = os.open(dmdev, os.O_WRONLY | os.O_DIRECT)
tokbuf = mmap.mmap(-1, 4096)

def mark(name):
    tokbuf.seek(0)
    tokbuf.write(("TOK-" + name).encode().ljust(4096, b"."))
    os.pwrite(tokfd, tokbuf, (sectors - 8) * 512)


def expect(name, latest):
    with open(os.path.join(out, "exp-" + name), "w") as f:
        for b in range(nblk):
            f.write("%d %d\n" % (b, latest[b]))

fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
# latest -1: never written, reads as zeros (only the prealloc variant has these).
latest = [0] * nblk
if prealloc:
    os.posix_fallocate(fd, 0, nblk * 4096)
    latest = [0 if b < nblk // 4 else -1 for b in range(nblk)]
    written = range(nblk // 4)
else:
    written = range(nblk)
for b in written:
    os.pwrite(fd, pat(0, b), b * 4096)
call(fd)
mark("base")
expect("base", latest)
for r in range(1, rounds + 1):
    blocks = random.sample(range(nblk), 4)
    for b in blocks:
        os.pwrite(fd, pat(r, b), b * 4096)
        latest[b] = r
    call(fd)
    mark("ack%d" % r)
    expect("ack%d" % r, latest)
os.close(fd)
PY
}

# record <key> <skip> <sync> <prealloc>: the workload through dm-log-writes
# with the final flush skipped (1) or not (0). Prints the log device.
record() {
    local key="$1" data log dm lw
    data="$(ct_loop "$(ct_image "$DM_MB" "fsv-d$key")")"
    log="$(ct_loop "$(ct_image 512 "fsv-l$key")")"
    dm="fsv_${key}_$$"
    dmsetup create "$dm" --table "0 $SECTORS log-writes $data $log"
    ct_track dm "$dm"
    lw="/dev/mapper/$dm"
    ct_param_set fsync_flush_skip "$2"
    ct_mkfs "$lw" -s "${SZ_MB}M" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$lw" "$MNT"
    mkdir -p "$OUT/rec$key"
    workload "$MNT/vm" "$lw" "$OUT/rec$key" "$3" "$4"
    ct_umount "$MNT"
    ct_param_set fsync_flush_skip 0
    dmsetup remove "$dm"
    blockdev --flushbufs "$log"
    echo "$log"
}

# verify <file> <expect>: how many blocks of <file> differ from what
# <expect> says they hold ("block round" lines). Prints the count.
verify() {
    python3 - "$1" "$2" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bad = 0
for line in open(sys.argv[2]):
    b, r = map(int, line.split())
    want = (b"R%03dB%03d" % (r, b)) * 512 if r >= 0 else b"\0" * 4096
    if os.pread(fd, 4096, b * 4096) != want:
        bad += 1
os.close(fd)
print(bad)
PY
}

# cut <log> <mark> <mode> <seed> <rimg>: replays the volatile cut before
# <mark> onto <rimg>, mounts it, and prints "<bad blocks> <window note>".
# bad counts blocks that differ from the mark's expectation, or -1 when
# the image does not mount.
cut() {
    local log="$1" mark="$2" mode="$3" seed="$4" rimg="$5" note bad
    dd if=/dev/zero of="$rimg" bs=1M count="$DM_MB" status=none
    note="$("$REPLAY" --log "$log" --replay "$rimg" --volatile-cut-token "TOK-$mark" --volatile-mode "$mode" --volatile-seed "$seed" 2>&1 >/dev/null | tail -1)"
    blockdev --flushbufs "$rimg"
    if ! mount -t cetrafs "$rimg" "$MNT" 2>/dev/null; then
        echo "-1 $note"
        return
    fi
    bad="$(verify "$MNT/vm" "$CHECK_EXP")"
    umount "$MNT"
    echo "$bad $note"
}

# checkpoints: every mark, in the order the workload placed them.
MARKS="base ack1 ack2 ack3 ack4 ack5 ack6"

# run_round <variant> <skip> <tag>: record, then cut at each mark in drop
# mode and in random mode with seeds 1..3. Prints one line per cut.
run_round() {
    local variant="$1" skip="$2" tag="$3" sync prealloc log rimg m mode seed res bad note key
    case "$variant" in
    fsync) sync=fsync prealloc=0 ;;
    fdatasync) sync=fdatasync prealloc=0 ;;
    fdatasync-prealloc) sync=fdatasync prealloc=1 ;;
    *) echo "unknown variant $variant" >&2; ct_exit ;;
    esac
    key="$tag-$skip"
    log="$(record "$key" "$skip" "$sync" "$prealloc")"
    rimg="$(ct_loop "$(ct_image "$DM_MB" "fsv-r$key")")"
    for m in $MARKS; do
        CHECK_EXP="$OUT/rec$key/exp-$m"
        for mode in drop random; do
            for seed in 1 2 3; do
                [ "$mode" = drop ] && [ "$seed" != 1 ] && continue
                res="$(cut "$log" "$m" "$mode" "$seed" "$rimg")"
                bad="${res%% *}"
                note="${res#* }"
                echo "$tag $m $mode $seed bad=$bad $note"
            done
        done
    done
}

for variant in ${FSV_VARIANTS:-fsync fdatasync fdatasync-prealloc}; do
    log "variant $variant: control (the final flush removed), then as shipped"
    # ---- control first: the knob removes the final flush of the call ----
    ctl="$(run_round "$variant" 1 control)"
    echo "$ctl"
    ctl_lost="$(grep -c 'bad=[1-9-]' <<<"$ctl" || true)"
    ctl_window="$(sed -n 's/.*\([0-9][0-9]*\) dropped.*/\1/p' <<<"$ctl" | sort -n | tail -1)"

    # ---- as shipped ----
    shp="$(run_round "$variant" 0 shipped)"
    echo "$shp"

    [ "${ctl_window:-0}" -gt 0 ] &&
        pass "$variant setup: the control's cut windows held unflushed writes (up to ${ctl_window:-0} dropped)" ||
        { fail "$variant setup: no cut window held an unflushed write -- the workload never reaches the final flush"; ct_exit; }
    [ "$ctl_lost" -gt 0 ] &&
        pass "$variant control: without the final flush, $ctl_lost cut(s) lose acknowledged data -- the loss this rig exists to see" ||
        fail "$variant control: no cut lost acknowledged data -- the rig cannot tell a missing flush from a present one"
    bad_shp="$(grep -c 'bad=[1-9-]' <<<"$shp" || true)"
    [ "$bad_shp" = 0 ] &&
        pass "$variant as shipped: every cut mounts and reads back its acknowledged blocks (drop and 3 random seeds, $(wc -l <<<"$shp") cuts)" ||
        fail "$variant as shipped: $bad_shp cut(s) lose or fail to mount acknowledged data: $(grep 'bad=[1-9-]' <<<"$shp" | head -3 | tr '\n' ' ')"
done
rm -rf "$OUT"
ct_exit
