#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# after a live grow a file may grow past the capacity the volume had at mount
#
# The largest file a volume holds is its capacity (capped by the format's
# 2^32 blocks). It used to be stamped into sb->s_maxbytes once, at mount,
# from fields its comment called fixed for the life of the mount -- true
# until live grow. After one, a file stopped at the old capacity: a VM
# image streaming through two grows got EFBIG 3.5 GiB in on a volume
# grown to 8 GiB (ctest grow-twice, 2026-11-12).
#
# Now s_maxbytes is the format ceiling alone and the capacity is checked
# against the layout this node holds -- catching up first when a request
# passes it, since a node that has not yet adopted a peer's grow would
# otherwise refuse what every other node accepts. vfs_fallocate() checks
# s_maxbytes BEFORE ->fallocate, which is why the capacity cannot stay
# there and be refreshed: nothing could catch the node up in time.
#
# The peer is played by this node (grow_skip_local_publish, as in
# grow_live_refresh.sh) with the heartbeat's refresh off, so the
# on-demand catch-up is the SOLE way this node can learn of each grow.
# For each of truncate(2), fallocate(2) and write(2), in turn: a grow
# lands behind this node, and the operation past the capacity it holds
# must succeed and bring the node to the new layout_gen.
#
# The cap is still enforced: past the capacity of the CURRENT layout each
# of the three is refused EFBIG (the control that the check exists).
#
# DISCRIMINATION: with the catch-up in cetrafs_sb_capacity_for() removed,
# the truncate after the first grow fails EFBIG and the node stays at
# layout_gen 0; the next step's setup then fails too, since growfs's own
# ioctl catches a node up before it grows (2026-11-12).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_big_image 2900 growmaxb)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt growmaxb)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
grow_behind() { # <size>: committed to the device, this node not switched
    ct_param_set grow_skip_local_publish 1
    ct_growfs "$DEV" -s "$1" 2>&1
}
# <op> <file> <bytes>: 0 when the kernel accepted it, prints the errno name otherwise
try_op() {
    python3 - "$1" "$2" "$3" <<'PY'
import os, sys, errno
op, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
try:
    if op == "truncate":
        os.ftruncate(fd, n)
    elif op == "fallocate":
        os.posix_fallocate(fd, n - 4096, 4096)
    else:
        os.pwrite(fd, b"PASTCAP!" * 512, n - 4096)
        os.fsync(fd)
        if os.pread(fd, 8, n - 4096) != b"PASTCAP!":
            print("READBACK"); sys.exit(1)
    print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno))); sys.exit(1)
finally:
    os.close(fd)
PY
}

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set layout_refresh_hb_off 1

# ------------------------------------------------- the cap is still enforced
CAP0="$(info max_file_size_bytes)"
[ -n "$CAP0" ] && [ "$CAP0" -gt 0 ] && [ "$CAP0" -lt 1073741824 ] ||
    { fail "setup: a 600 MiB volume reports max_file_size_bytes='$CAP0'"; ct_exit; }
for op in truncate fallocate write; do
    r="$(try_op "$op" "$MNT/ctl-$op" $((CAP0 + 1048576)) || true)"
    [ "$r" = "EFBIG" ] && pass "control: $op 1 MiB past the capacity ($CAP0) is refused EFBIG" ||
        fail "control: $op 1 MiB past the capacity ($CAP0) gave '$r', not EFBIG"
done

# ----------------------------- each operation catches up with a peer's grow
size=600
for op in truncate fallocate write; do
    gen0="$(info layout_gen)"; cap="$(info max_file_size_bytes)"
    size=$((size + 700))
    out="$(grow_behind "${size}M")" || { fail "$op: setup: the grow failed: $(tail -2 <<<"$out")"; ct_exit; }
    [ "$(info layout_gen)" = "$gen0" ] && [ "$(info max_file_size_bytes)" = "$cap" ] ||
        { fail "$op: setup: this node adopted the grow on its own -- nothing below would test the catch-up"; ct_exit; }
    r="$(try_op "$op" "$MNT/big-$op" $((cap + 1048576)) || true)"
    [ "$r" = "OK" ] && pass "$op 1 MiB past the capacity this node held ($cap) is accepted after a peer's grow" ||
        fail "$op 1 MiB past the capacity this node held ($cap) gave '$r' after a peer's grow"
    g="$(info layout_gen)"; c="$(info max_file_size_bytes)"
    [ "$g" = "$((gen0 + 1))" ] && [ "$c" -gt "$cap" ] &&
        pass "$op: and caught the node up (layout_gen $gen0 -> $g, capacity $cap -> $c)" ||
        fail "$op: the node is at layout_gen $g, capacity $c (was $gen0, $cap)"
done

ct_param_set layout_refresh_hb_off 0
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean after the grows" ||
    fail "fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
