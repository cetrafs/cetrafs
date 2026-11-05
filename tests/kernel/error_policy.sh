#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a mount that can no longer trust what it knows stops, and stops completely
#
# docs/internal/ERRORS.md. Before it, a metadata write the device refused,
# a swap whose outcome could not be decided, damaged metadata: each
# failed one operation or was logged, and the node went on writing on
# top of whatever the device now held. Only a peer's fence ever stopped
# a mount, and even a fenced mount kept serving reads from a cache that
# described files a peer might own by then.
#
#   A. procfs `shutdown=now`: every access fails with EIO, reads of
#      cached data included, info says why, and NOTHING reaches the
#      device from the stop through the unmount -- the image is
#      byte-identical. Unmount works; a remount comes back clean.
#   B. FS_IOC_SHUTDOWN on the mount point does the same.
#   C. a metadata write the device refuses (meta_write_fail) stops the
#      mount (kind 3); errors=panic is accepted and shown; there is no
#      errors=continue.
#   D. damaged metadata (an extent aimed at the inode table, valid CRC)
#      is counted, and every later write to THAT inode is refused with
#      EUCLEAN while the rest of the mount carries on (kind 2); with
#      corruption=stop it stops the mount instead.
#
# DISCRIMINATION, measured in the same run: without the stop the same
# operations change the image (A); with error_policy_off the refused
# metadata write leaves the mount running (C) and the damaged inode
# accepts the write and the unlink (D).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
# A registered row here looks live to the tools, which then watch it for
# the longest stale window a node may use (240 s, devutil.h) -- not what
# this suite tests; tool_probe_stale_window.sh tests that.
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
# And every remount after a stop is an unclean re-attach, which waits the
# stale window for a twin (cetrafs_node_row_quiet()): compressed, or the
# suite spends minutes in it.
compress_timing
for k in meta_write_fail error_policy_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
PPOKE="$(ct_helper extent_phys_poke)"

IMG="$(ct_image 560 errpol)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt errpol)"
ct_track mnt "$MNT"
PROC="$(ct_procdir "$DEV")"
info() { sed -n "s/^$1: //p" "$PROC/info"; }
img_hash() { sha256sum <"$IMG" | cut -d' ' -f1; }

fresh() { # [mount options]
    umount "$MNT" 2>/dev/null || true
    ct_mkfs_small "$DEV" >/dev/null
    if [ -n "${1:-}" ]; then mount -t cetrafs -o "$1" "$DEV" "$MNT"; else mount -t cetrafs "$DEV" "$MNT"; fi
    require_cetrafs_mount "$MNT"
    mkdir "$MNT/d"
    echo before >"$MNT/d/f"
    sync
}

# Every kind of access, each expected to fail on a stopped mount. Prints
# the ones that did NOT fail.
try_everything() {
    local got=""
    cat "$MNT/d/f" >/dev/null 2>&1 && got="$got read"
    stat "$MNT/d/f" >/dev/null 2>&1 && got="$got stat"
    ls "$MNT/d" >/dev/null 2>&1 && got="$got readdir"
    stat "$MNT/d/nonexistent" 2>&1 | grep -q "No such file" && got="$got lookup"
    { echo x >>"$MNT/d/f"; } 2>/dev/null && got="$got write"
    { : >"$MNT/d/new"; } 2>/dev/null && got="$got create"
    mkdir "$MNT/d/sub" 2>/dev/null && got="$got mkdir"
    truncate -s 0 "$MNT/d/f" 2>/dev/null && got="$got truncate"
    rm -f "$MNT/d/f" 2>/dev/null && [ ! -e "$MNT/d/f" ] && got="$got unlink"
    python3 -I -c "
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
m = mmap.mmap(fd, 0, prot=mmap.PROT_READ)
m[0]
" "$MNT/d/f" 2>/dev/null && got="$got mmap-read"
    echo "$got"
}

# ---------------------------------------------------------------- A
log "A: procfs shutdown=now"
fresh
cat "$MNT/d/f" >/dev/null # cached: the stop must refuse it anyway
ct_param_set hb_interval_secs 2
grep -q "^shutdown: no" "$PROC/controls" || fail "A: controls does not report shutdown: no on a live mount"
echo shutdown=now >"$PROC/controls"
sleep 1 # the stop's sweep is a work item
H0="$(img_hash)"
[ "$(info fenced)" = yes ] && [ "$(info stopped)" = manual ] &&
    pass "A: info reports fenced: yes, stopped: manual" ||
    fail "A: info reports fenced: $(info fenced), stopped: $(info stopped)"
GOT="$(try_everything)"
[ -z "$GOT" ] && pass "A: every access fails, cached reads included" || fail "A: these went through:$GOT"
sleep 5 # two heartbeat ticks: a stopped mount's tick writes nothing
umount "$MNT" && pass "A: a stopped mount unmounts" || { fail "A: umount failed"; umount -l "$MNT" || true; }
[ "$(img_hash)" = "$H0" ] && pass "A: nothing reached the device from the stop through the unmount" ||
    fail "A: the image changed after the stop"
ct_param_set hb_interval_secs "$TEST_HB_SECS"
mount -t cetrafs "$DEV" "$MNT" && [ "$(cat "$MNT/d/f")" = before ] && [ "$(info fenced)" = no ] &&
    pass "A: a remount rejoins, with the data written before the stop" ||
    fail "A: the remount did not come back clean"
umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "A: fsck clean" ||
    fail "A: fsck: $(grep '^ERR' <<<"$OUT" | head -3)"

log "A control: the same operations without the stop change the image"
fresh
H0="$(img_hash)"
GOT="$(try_everything)"
sync
[ "$(img_hash)" != "$H0" ] && [ -n "$GOT" ] &&
    pass "A control: on a live mount they write (the test discriminates)" ||
    fail "A control: the operations did not change the image -- A proves nothing"

# ---------------------------------------------------------------- B
log "B: FS_IOC_SHUTDOWN"
fresh
if python3 -I - "$MNT" <<'PY'
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
FS_IOC_SHUTDOWN = 0x8004587d # _IOR('X', 125, __u32)
fcntl.ioctl(fd, FS_IOC_SHUTDOWN, struct.pack("I", 2)) # NOLOGFLUSH
PY
then
    [ "$(info stopped)" = manual ] && [ -z "$(try_everything)" ] &&
        pass "B: FS_IOC_SHUTDOWN on the mount point stops the mount" ||
        fail "B: after the ioctl stopped=$(info stopped), went through:$(try_everything)"
else
    fail "B: the ioctl failed"
fi
umount "$MNT" || umount -l "$MNT"

# ---------------------------------------------------------------- C
log "C: a refused metadata write stops the mount"
fresh
MARK="$(dmesg_mark)"
ct_param_set meta_write_fail 1
{ : >"$MNT/d/c1"; } 2>/dev/null || true
ct_param_set meta_write_fail 0
[ "$(info stopped)" = error ] && pass "C: the mount stopped (stopped: error)" ||
    fail "C: stopped: $(info stopped) after a refused metadata write"
dmesg_since "$MARK" | grep -q "STOPPED (error): the device refused a metadata write" &&
    pass "C: the kernel says why" || fail "C: no STOPPED line in dmesg"
{ : >"$MNT/d/c2"; } 2>/dev/null && fail "C: a create went through after the stop" || pass "C: and refuses what follows"
umount "$MNT" || umount -l "$MNT"
mount -t cetrafs "$DEV" "$MNT" && [ "$(cat "$MNT/d/f")" = before ] &&
    pass "C: the remount recovers, with the data from before" || fail "C: the remount did not recover"
umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "C: fsck clean" ||
    fail "C: fsck: $(grep '^ERR' <<<"$OUT" | head -3)"

log "C control: error_policy_off"
fresh
ct_param_set error_policy_off 1
ct_param_set meta_write_fail 1
{ : >"$MNT/d/c1"; } 2>/dev/null || true
ct_param_set meta_write_fail 0
{ : >"$MNT/d/c2"; } 2>/dev/null && [ "$(info fenced)" = no ] &&
    pass "C control: without the policy the mount keeps going (the test discriminates)" ||
    fail "C control: the mount stopped even with the policy off -- C proves nothing"
ct_param_set error_policy_off 0
umount "$MNT" || umount -l "$MNT"

log "C: the options"
fresh errors=panic
grep -q "errors=panic" /proc/mounts && pass "C: errors=panic is accepted and shown" ||
    fail "C: errors=panic not in /proc/mounts"
umount "$MNT"
mount -t cetrafs -o errors=continue "$DEV" "$MNT" 2>/dev/null &&
    { fail "C: errors=continue was accepted"; umount "$MNT"; } || pass "C: there is no errors=continue"

# ---------------------------------------------------------------- D
damage() { # [mount options]: a volume whose 'victim' names the inode table
    umount "$MNT" 2>/dev/null || true
    ct_mkfs_small "$DEV" >/dev/null
    mount -t cetrafs "$DEV" "$MNT"
    dd if=/dev/zero of="$MNT/victim" bs=4096 count=4 status=none
    echo ok >"$MNT/bystander"
    sync
    VINO="$(stat -c %i "$MNT/victim")"
    umount "$MNT"
    "$PPOKE" "$IMG" "$VINO" inode_table >/dev/null || { fail "setup: extent_phys_poke failed"; ct_exit; }
    blockdev --flushbufs "$DEV"
    if [ -n "${1:-}" ]; then mount -t cetrafs -o "$1" "$DEV" "$MNT"; else mount -t cetrafs "$DEV" "$MNT"; fi
    cat "$MNT/victim" >/dev/null 2>&1 && { fail "setup: the damaged extent was read without complaint"; ct_exit; }
    true
}
errno_of() { { "$@" 2>&1 >/dev/null || true; } | grep -o "Structure needs cleaning\|Input/output error" | head -1 || true; }

log "D: damaged metadata isolates the inode"
damage
[ "$(info corruptions)" -ge 1 ] && pass "D: counted (corruptions: $(info corruptions))" ||
    fail "D: corruptions: $(info corruptions)"
[ "$(info fenced)" = no ] && pass "D: the mount keeps going" || fail "D: the mount stopped"
E="$(errno_of dd if=/dev/zero of="$MNT/victim" bs=4096 seek=100 count=1 conv=notrunc status=none)"
[ "$E" = "Structure needs cleaning" ] && pass "D: a write to the damaged inode is refused (EUCLEAN)" ||
    fail "D: a write past the damage got: '${E:-success}'"
E="$(errno_of rm -f "$MNT/victim")"
[ "$E" = "Structure needs cleaning" ] && [ -e "$MNT/victim" ] &&
    pass "D: so is unlinking it -- nothing is freed on the strength of a damaged tree" ||
    fail "D: unlink got: '${E:-success}'"
echo more >>"$MNT/bystander" && : >"$MNT/other" && pass "D: other files are writable" ||
    fail "D: an undamaged file was refused"
umount "$MNT"

log "D control: error_policy_off"
ct_param_set error_policy_off 1
damage
E="$(errno_of dd if=/dev/zero of="$MNT/victim" bs=4096 seek=100 count=1 conv=notrunc status=none)"
[ -z "$E" ] && pass "D control: without the policy the same write goes through (the test discriminates)" ||
    fail "D control: the write was refused anyway ('$E') -- D proves nothing"
ct_param_set error_policy_off 0
umount "$MNT"

log "D: corruption=stop"
damage corruption=stop
[ "$(info stopped)" = corruption ] && pass "D: with corruption=stop it stops the mount" ||
    fail "D: corruption=stop left stopped: $(info stopped)"
grep -q "corruption=stop" /proc/mounts && pass "D: and the option is shown" || fail "D: corruption=stop not shown"
umount "$MNT" || umount -l "$MNT"
ct_exit
