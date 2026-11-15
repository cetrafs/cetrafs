#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# errors=panic covers the stops a storage outage produces
#
# errors=panic is the documented pairing for a node a watchdog reboots,
# but it fired only for kind-3 fatal errors and corruption=stop. A fence
# by a peer, our own lease running out and a vanished device went
# through cetrafs_sb_stop(), which never panicked: the host stayed up,
# looked healthy to the cluster manager, and every guest sat in EIO with
# nothing restarting it (audit 2026-11-14 A-5). Those three causes now
# panic under errors=panic; a stop someone asked for (procfs shutdown,
# FS_IOC_SHUTDOWN) still does not.
#
# A panic would take the test box down, so TEST ONLY panic_dry_run makes
# the panic a log line ("would panic now (<cause>)").
#   1. errors=panic, a peer bumps our fence epoch: would panic (fenced);
#   2. errors=panic, renewals failing until the lease runs out: would panic (lease);
#   3. errors=panic, procfs shutdown: stops, and does not panic;
#   4. control: errors=stop (the default), the same fence: no panic.
# (A vanished device takes the same branch as 1 and 2; a loop device
# cannot be removed under a mount to show it.)
#
# DISCRIMINATION: the pre-fix module never says "would panic": 1 and 2 fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in panic_dry_run hb_renew_fail lease_disable; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
NODE_POKE="$(ct_helper node_poke)"
MNT="$(ct_mnt eps)"
ct_track mnt "$MNT"
ct_param_set panic_dry_run 1 # before any errors=panic mount: never a real panic on this box
ct_param_set lease_disable 0
ct_param_set hb_renew_fail 0
compress_timing

# <opts> <how: fence|lease|shutdown> -> dmesg of the attempt
attempt() {
    local mark row DEV
    # A fresh image each time: a stopped mount leaves its row unclean,
    # and mkfs over it would watch that row for a whole stale window.
    DEV="$(ct_dev 560 "eps-$2-${1#errors=}")"
    ct_mkfs_small "$DEV" >/dev/null
    mount -t cetrafs -o "$1" "$DEV" "$MNT"
    row="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
    sleep $((TEST_HB_SECS * 2)) # past the first renewal, which arms the lease
    mark="$(dmesg_mark)"
    case "$2" in
    fence) "$NODE_POKE" "$DEV" "$row" --bump-fence 1 >/dev/null ;;
    lease) echo 1 >/sys/module/cetrafs/parameters/hb_renew_fail ;;
    shutdown) echo "shutdown=now" >"$(ct_procdir "$DEV")/controls" ;;
    esac
    wait_for 30 "dmesg_since '$mark' | grep -qE 'SELF-FENCED|STOPPED'" || true
    sleep 1
    echo 0 >/sys/module/cetrafs/parameters/hb_renew_fail
    dmesg_since "$mark"
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
}

F="$(attempt errors=panic fence)"
grep -q "SELF-FENCED" <<<"$F" || { fail "setup: the fence did not stop the mount"; ct_exit; }
grep -q "would panic now (fenced)" <<<"$F" && pass "1: errors=panic: a fence panics" ||
    fail "1: errors=panic: a fence stopped the mount without panicking"
L="$(attempt errors=panic lease)"
grep -q "SELF-FENCED" <<<"$L" || { fail "setup: the lease did not run out"; ct_exit; }
grep -q "would panic now (lease)" <<<"$L" && pass "2: errors=panic: a lapsed lease panics" ||
    fail "2: errors=panic: a lapsed lease stopped the mount without panicking"
S="$(attempt errors=panic shutdown)"
grep -q "STOPPED (manual)" <<<"$S" || { fail "setup: procfs shutdown did not stop the mount"; ct_exit; }
grep -q "would panic" <<<"$S" && fail "3: a requested shutdown panicked" || pass "3: a requested shutdown stops without panicking"
D="$(attempt errors=stop fence)"
grep -q "SELF-FENCED" <<<"$D" || { fail "setup: the errors=stop fence did not stop the mount"; ct_exit; }
grep -q "would panic" <<<"$D" && fail "4: errors=stop panicked on a fence" || pass "4: control: errors=stop does not panic"
ct_exit
