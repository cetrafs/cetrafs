#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the storm until a directory record REVERTS (size goes down outside
# mkdir), keeping that iteration's dmesg. The question is whether the
# writer held the directory's namespace lock.
set -u
# Env: DEV   the shared block device (same path on every node)
#      NODES space-separated hostnames; the FIRST is this node, which
#            runs the master and a local slave
#      REPO  the checkout on this node (default /root/cetrafs)
D="${DEV:?set DEV=<shared block device>}"
NODES="${NODES:?set NODES=\"self peer1 peer2\" -- this node first}"
REPO="${REPO:-/root/cetrafs}"
H="$NODES"
SELF="${NODES%% *}"
PEERS="${NODES#* }"
S="-slaves=a=127.0.0.1:9100"; _n=b
for _p in $PEERS; do S="$S,$_n=$_p:9100"; _n=c; done
cd "$REPO"
mkdir -p /root/revhunt; rm -f /root/revhunt/*
# Always-on corruption stop: poll every node's live stream; at the
# first checksum-failure line, kill the master and freeze everything.
(
  while true; do
    for wh in $NODES; do
      n=$(timeout 12 ssh -n -o ConnectTimeout=5 $wh 'grep -ac "failed its record checksum" /root/rev-stream.txt 2>/dev/null' 2>/dev/null)
      if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
        echo "$(date -u +%H:%M:%S) LIVE-STOP: corruption on $wh ($n lines)"
        pkill -9 -f 'mode=mast[e]r'
        touch /root/LIVE-STOP
        exit 0
      fi
    done
    sleep 5
  done
) &
WATCHPID=$!

for i in $(seq 1 12); do
    echo "### iter $i $(date -u +%H:%M:%S)"
    for h in $H; do
        timeout 45 ssh -n -o ConnectTimeout=10 $h "pkill -f 'mode=sla[v]e'; sleep 1; umount /mnt/cetra 2>/dev/null; rmmod cetrafs 2>/dev/null; insmod /root/cetrafs.ko 2>&1|head -1; for d in /sys/block/sd*/device/state; do grep -q offline \$d 2>/dev/null && echo running > \$d; done; multipath -r >/dev/null 2>&1; pkill -x dmesg; dmesg -C; (setsid dmesg --follow --time-format=iso > /root/rev-stream.txt 2>/dev/null &)" 2>/dev/null
    done
    timeout 45 ssh -n "$SELF" "cd $REPO && (setsid nohup ./ctest/ctest -mode=slave -device=$D -mountpoint /mnt/cetra >/root/ctest-slave.log 2>&1 </dev/null &)" 2>/dev/null
    for h in $PEERS; do timeout 45 ssh -n $h "cd /root && (setsid nohup ./ctest -mode=slave -device=$D -mountpoint /mnt/cetra >/root/ctest-slave.log 2>&1 </dev/null &)" 2>/dev/null; done
    sleep 3
    # NEVER mkfs over a live mount: a silent umount failure leaves a
    # node whose cached world and the device disagree completely, and
    # its reads then fail checksum in bulk -- a corruption storm the
    # harness itself manufactured. Verify, retry, abort loudly.
    for try in 1 2 3 4 5; do
        busy=0
        for h in $H; do
            m=$(timeout 20 ssh -n $h 'umount /mnt/cetra 2>/dev/null; mount | grep -c " /mnt/cetra "' 2>/dev/null)
            [ "$m" = "0" ] || { echo "   $h still mounted (try $try)"; busy=1; }
        done
        [ $busy = 0 ] && break
        sleep 3
    done
    if [ $busy = 1 ]; then echo 'ABORT: a node is still mounted; refusing to mkfs under it'; exit 4; fi
    ./userspace/mkfs.cetra $D -f >/dev/null 2>&1
    timeout 400 ./ctest/ctest -mode=master -scenario=hypervisor-storm -storm-minutes=2 -storm-inject=false -storm-nofilelock -storm-seed=$((300+i)) $S > /root/revhunt/run-$i.log 2>&1
    for h in $H; do
        timeout 45 ssh -n -o ConnectTimeout=10 $h 'pkill -x dmesg; cat /root/rev-stream.txt' > /root/revhunt/dm-$i-$h.txt 2>/dev/null
    done
    # a non-mkdir size decrease for the same directory inode
    if python3 /root/rev7.py "$i"
    then
        echo ">>> REVERT CAUGHT on iteration $i"
        exit 10
    fi
    echo "   no revert this iteration"
done
kill $WATCHPID 2>/dev/null
echo "no revert in 12"
