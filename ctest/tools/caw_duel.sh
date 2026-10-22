#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Two-node COMPARE-AND-WRITE atomicity contest on ONE raw sector.
# Each contestant: read the sector, build compare=old / write=old with
# counter+1 and its tag, issue CAW via sg_compare_and_write through the
# multipath device. Success = a win; miscompare (exit 14 / reservation
# style conflict) = lost race, retry. If CAW is atomic across nodes, the
# final counter equals the sum of wins. Any shortfall = lost updates =
# the primitive is NOT atomic on this array/path stack.
set -u
D="${DEV:?set DEV=<shared block device, same path on both nodes>}"
LBA=2000000     # raw sector, far from anything; LUN is reformatted after
N=${2:-500}
TAG=$1
WINS=0
# zero the sector once from the starter
if [ "$TAG" = "A" ]; then
    dd if=/dev/zero of=$D bs=512 count=1 seek=$LBA oflag=direct,sync conv=notrunc status=none
fi
sleep 2
for i in $(seq 1 $N); do
    for try in 1 2 3 4 5 6 7 8 9 10; do
        dd if=$D of=/tmp/caw_old.$TAG bs=512 count=1 skip=$LBA iflag=direct status=none
        cnt=$(od -A none -t u4 -N 4 /tmp/caw_old.$TAG | tr -d " ")
        cp /tmp/caw_old.$TAG /tmp/caw_new.$TAG
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( (cnt+1)&255 )) $(( ((cnt+1)>>8)&255 )) $(( ((cnt+1)>>16)&255 )) $(( ((cnt+1)>>24)&255 )))" | dd of=/tmp/caw_new.$TAG bs=1 count=4 conv=notrunc status=none
        printf "$TAG" | dd of=/tmp/caw_new.$TAG bs=1 seek=8 count=1 conv=notrunc status=none
        cat /tmp/caw_old.$TAG /tmp/caw_new.$TAG > /tmp/caw_buf.$TAG
        if sg_compare_and_write --in=/tmp/caw_buf.$TAG --lba=$LBA --num=1 --xferlen=1024 $D >/dev/null 2>&1; then
            WINS=$((WINS+1)); break
        fi
    done
done
echo "$TAG wins=$WINS"
