#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Independent device-truth observer: poll sector 16512 byte 0-3 via
# O_DIRECT every ~50ms, timestamped. The ground truth each node's CAS
# chain must agree with.
D="${DEV:?set DEV=<shared block device>}"
while true; do
    v=$(dd if=$D bs=512 count=1 skip=16512 iflag=direct status=none 2>/dev/null | od -A none -t x1 -N 16 | tr -d " ")
    echo "$(date -u +%H:%M:%S.%6N) $v"
    sleep 0.05
done
