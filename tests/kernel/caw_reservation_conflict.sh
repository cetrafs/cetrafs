#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a COMPARE AND WRITE refused with RESERVATION CONFLICT is a definite failure, not an unknown outcome
#
# RESERVATION CONFLICT is a SCSI STATUS, with no sense data, so the CAW
# path's classifier sent it to its "no valid sense" branch and reported
# it as an UNKNOWN outcome (-ETIMEDOUT) -- the answer reserved for a
# command that may have executed. The target states the opposite: the
# command was not performed (SAM). It is now a definite failure.
#
# A loop device has no SCSI target and no CAW, so this builds a real one
# on this host: the LIO loopback fabric (tcm_loop) exports one fileio
# backstore through TWO nexuses -- two SCSI disks, two initiators, one
# LUN. A Write Exclusive reservation taken through the second makes every
# write from the first, CAW included, come back RESERVATION CONFLICT.
# Registration at mount is a CAW and the first write of the mount, so
# the mount runs straight into it.
#
# The backstore needs a unit serial set before it is enabled: without
# one LIO lists no VPD pages, the kernel never fetches Block Limits, and
# the disk reads as having no CAW at all.
#
# DISCRIMINATION: without the change dmesg says "outcome UNKNOWN" for
# that CAW, and nothing says it was refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v sg_persist >/dev/null || { skip "sg_persist (sg3_utils) is missing"; ct_exit; }
modprobe target_core_mod 2>/dev/null && modprobe target_core_file 2>/dev/null && modprobe tcm_loop 2>/dev/null ||
    { skip "the LIO loopback target (tcm_loop) is not available"; ct_exit; }
CF=/sys/kernel/config/target
# The target itself WARNs when it fails a COMPARE AND WRITE this way
# (target_core_sbc.c, compare_and_write_callback): its code, not ours.
CT_DMESG_IGNORE_WARN='WARNING: drivers/target/target_core_sbc.c:[0-9]+ at compare_and_write_callback'
[ -d "$CF/loopback" ] || { skip "configfs target/loopback is missing"; ct_exit; }

IMG="$(ct_image 560 cawrc)"
MNT="$(ct_mnt cawrc)"
TAG="$$"
HBA="$CF/core/fileio_$((7000 + TAG % 1000))"
BS="$HBA/ctrc$TAG"
naa() { printf 'naa.5001405%07x%02x' "$TAG" "$1"; }
# Teardown as a script, registered as ONE line: the harness's registry
# is line-based and runs it after the unmount, also on an abort.
TEARDOWN="$(ct_tmp cawrc-teardown)"
cat >"$TEARDOWN" <<EOT
for t in "$CF/loopback/$(naa 1)" "$CF/loopback/$(naa 2)"; do
    rm -f "\$t/tpgt_1/lun/lun_0/ctrc$TAG"
    rmdir "\$t/tpgt_1/lun/lun_0" "\$t/tpgt_1" "\$t" 2>/dev/null
done
rmdir "$BS" "$HBA" 2>/dev/null
[ ! -d "$BS" ]
EOT
ct_track cmd "bash $TEARDOWN"

mkdir -p "$BS"
echo "fd_dev_name=$IMG,fd_dev_size=$((560 * 1024 * 1024))" >"$BS/control"
echo "ctrc$TAG" >"$BS/wwn/vpd_unit_serial"
echo 1 >"$BS/enable"
for i in 1 2; do
    t="$CF/loopback/$(naa "$i")"
    mkdir -p "$t/tpgt_1/lun/lun_0"
    naa "$((i + 10))" >"$t/tpgt_1/nexus"
    ln -s "$BS" "$t/tpgt_1/lun/lun_0/ctrc$TAG"
done
disk() { # <nexus>: its /dev/sdX
    local a
    a="$(cat "$CF/loopback/$(naa "$1")/tpgt_1/address")"
    for _ in $(seq 1 50); do
        [ -d "/sys/class/scsi_device/$a:0/device/block" ] && { echo "/dev/$(ls "/sys/class/scsi_device/$a:0/device/block")"; return; }
        sleep 0.1
    done
}
A="$(disk 1)"
B="$(disk 2)"
[ -b "$A" ] && [ -b "$B" ] || { fail "setup: the two nexuses gave '$A' and '$B'"; ct_exit; }
ct_mkfs_small "$A" >/dev/null

log "1: a plain mount over this target uses real CAW"
MARK="$(dmesg_mark)"
ct_mount "$A" "$MNT"
require_cetrafs_mount "$MNT"
dmesg_since "$MARK" | grep -q "CAW: class=scsi .* max_caw_blocks=[1-9].* -> atomic CAS available" &&
    pass "1: setup: the LIO disk is mounted with atomic CAW" ||
    { fail "1: setup: CAW was not discovered: $(dmesg_since "$MARK" | grep 'CAW:' | tail -1)"; ct_exit; }
ct_umount "$MNT"

log "2: the same mount while another initiator holds Write Exclusive"
# The first command a fresh disk sees answers UNIT ATTENTION (power on /
# reset), and sg_persist exits nonzero on it: try twice. The reservation
# is verified right after, so a real failure still fails the setup.
for _ in 1 2; do
    sg_persist --out --register --param-sark=0x1 "$B" >/dev/null 2>&1 && break || true
done
for _ in 1 2; do
    sg_persist --out --reserve --param-rk=0x1 --prout-type=1 "$B" >/dev/null 2>&1 && break || true
done
sg_persist -r "$A" 2>/dev/null | grep -q "type: Write Exclusive" &&
    pass "2: setup: nexus 2 holds a Write Exclusive reservation" ||
    { fail "2: setup: no reservation: $(sg_persist -r "$A" 2>&1 | tail -1)"; ct_exit; }
MARK="$(dmesg_mark)"
if mount -t cetrafs "$A" "$MNT" 2>/dev/null; then
    fail "2: the mount succeeded although every write is refused"
    umount "$MNT"
else
    pass "2: the mount fails"
fi
dmesg_since "$MARK" | grep -q "CAW lba=[0-9]* refused: RESERVATION CONFLICT (not executed)" &&
    pass "2: the CAW is reported refused, not executed" ||
    fail "2: no refusal logged: $(dmesg_since "$MARK" | grep -E 'CAW lba' | head -1)"
dmesg_since "$MARK" | grep -q "outcome UNKNOWN" &&
    fail "2: the conflict was still taken for an unknown outcome" ||
    pass "2: and not taken for an unknown outcome"
sg_persist --out --release --param-rk=0x1 --prout-type=1 "$B" >/dev/null 2>&1 || true
sg_persist --out --register-ignore --param-sark=0 "$B" >/dev/null 2>&1 || true
ct_exit
