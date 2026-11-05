#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a setattr publishes only what it changes, never reverting a peer's chmod
#
# setattr's namespace-sector CAS wrote mode, uid and gid wholesale from the
# in-core inode. Nothing refreshes that copy once the namespace lock is
# held, and an fd-based call (futimens, ftruncate, fchmod) never looks the
# file up at all -- so a peer's chmod committed since this node last read
# the record was written back over with the old mode by a call that only
# meant to change the times (audit 2026-11-05, class 1). A security fault:
# a chmod 600 silently undone.
#
# Staged with a "peer" editing the record on the device: open a 0644 file
# (the in-core inode is 0644), set it to 0600 on the device, then futimens
# through the open fd. After a remount the mode must be 0600. A futimens
# that DID change the mode -- fchmod -- still publishes it (control).
#
# The same through a privilege kill: notify_change() turns an
# unprivileged write's "drop setuid/setgid" into a whole mode computed
# from the CACHED copy. A 6777 file, a peer's chmod to 6770 on the
# device, then a write by nobody through an fd already open: the device
# must end 0770 (the peer's o-rwx kept, suid/sgid dropped), not 0777.
#
# DISCRIMINATION: proven 2026-11-05 with the wholesale apply restored: the
# futimens writes 0644 back over the peer's 0600. With the kill applied
# as a whole mode, the write publishes 0777 over the peer's 6770.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 sapm)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt sapm)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

printf 'x' >"$MNT/f"
chmod 0644 "$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
OUT="$(ct_tmp sapm-out)"
python3 - "$MNT/f" "$POKE" "$IMG" "$INO" >"$OUT" 2>&1 <<'PY' || true
import os, subprocess, sys
f, poke, img, ino = sys.argv[1:5]
fd = os.open(f, os.O_RDONLY)
os.fstat(fd)                                   # in-core: 0644
r = subprocess.run([poke, img, "setmode", ino, "0100600"], capture_output=True, text=True)
if r.returncode != 0:
    print("SETUP poke failed:", r.stderr.strip()); sys.exit(0)
os.utime(fd, (1000000000, 1000000000))  # futimens: times only
os.close(fd)
print("OK")
PY
grep -q '^SETUP' "$OUT" && { fail "setup: $(cat "$OUT")"; ct_exit; }
grep -q '^OK' "$OUT" || { fail "setup: the staging script did not finish: $(tr '\n' ';' <"$OUT")"; ct_exit; }
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
M="$(stat -c %a "$MNT/f")"
T="$(stat -c %Y "$MNT/f")"
[ "$T" = 1000000000 ] && pass "setup: the futimens itself was published (mtime $T)" ||
    fail "setup: the futimens did not reach the device (mtime $T) -- nothing was tested"
[ "$M" = 600 ] && pass "a times-only setattr kept the peer's chmod (mode $M)" ||
    fail "a times-only setattr wrote mode $M back over the peer's 600"

# a privilege kill clears only the bits it drops
printf 'y' >"$MNT/k"
chmod 6777 "$MNT/k"
sync
KINO="$(stat -c %i "$MNT/k")"
python3 - "$MNT/k" "$POKE" "$IMG" "$KINO" >"$OUT" 2>&1 <<'PY' || true
import os, subprocess, sys
f, poke, img, ino = sys.argv[1:5]
fd = os.open(f, os.O_WRONLY)                   # in-core: 6777
r = subprocess.run([poke, img, "setmode", ino, "0106770"], capture_output=True, text=True)
if r.returncode != 0:
    print("SETUP poke failed:", r.stderr.strip()); sys.exit(0)
os.setgroups([]); os.setgid(65534); os.setuid(65534)   # no CAP_FSETID
os.pwrite(fd, b'z', 0)                         # kills suid/sgid
os.close(fd)
print("OK")
PY
grep -q '^SETUP' "$OUT" && { fail "setup: $(cat "$OUT")"; ct_exit; }
grep -q '^OK' "$OUT" || { fail "setup: the kill script did not finish: $(tr '\n' ';' <"$OUT")"; ct_exit; }
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
KM="$(stat -c %a "$MNT/k")"
[ "$(head -c1 "$MNT/k")" = z ] || fail "setup: the unprivileged write did not land"
case "$KM" in
770) pass "a privilege kill kept the peer's chmod and dropped only suid/sgid (mode $KM)" ;;
6770) fail "setup: the unprivileged write killed nothing (mode $KM) -- nothing was tested" ;;
*) fail "a privilege kill published mode $KM over the peer's 6770 (want 770)" ;;
esac

# control: a setattr that does change the mode still publishes it
chmod 0640 "$MNT/f"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
M2="$(stat -c %a "$MNT/f")"
[ "$M2" = 640 ] && pass "control: a chmod is still published (mode $M2)" ||
    fail "control: a chmod 640 was not published (mode $M2)"
ct_umount "$MNT"
ct_exit
