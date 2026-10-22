#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# duel v2: contest via explicit raw paths. $1=tag $2=device $3=iterations
set -u
DEV=$2; LBA=2000000; N=${3:-400}; TAG=$1; WINS=0
for i in $(seq 1 $N); do
    for try in 1 2 3 4 5 6 7 8 9 10; do
        dd if=$DEV of=/tmp/c2_old.$TAG bs=512 count=1 skip=$LBA iflag=direct status=none
        cnt=$(od -A none -t u4 -N 4 /tmp/c2_old.$TAG | tr -d " ")
        cp /tmp/c2_old.$TAG /tmp/c2_new.$TAG
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( (cnt+1)&255 )) $(( ((cnt+1)>>8)&255 )) $(( ((cnt+1)>>16)&255 )) $(( ((cnt+1)>>24)&255 )))" | dd of=/tmp/c2_new.$TAG bs=1 count=4 conv=notrunc status=none
        printf "$TAG" | dd of=/tmp/c2_new.$TAG bs=1 seek=8 count=1 conv=notrunc status=none
        cat /tmp/c2_old.$TAG /tmp/c2_new.$TAG > /tmp/c2_buf.$TAG
        if sg_compare_and_write --in=/tmp/c2_buf.$TAG --lba=$LBA --num=1 --xferlen=1024 $DEV >/dev/null 2>&1; then
            WINS=$((WINS+1)); break
        fi
    done
done
echo "$TAG dev=$DEV wins=$WINS"
