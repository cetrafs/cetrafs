#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a compare-and-swap never stamps a fresh checksum over a damaged sector
#
# Record swaps keep the fields they do not change and stamp a new
# checksum. The namespace and Zone Group mutators refused an image that
# failed its own checksum first; the file-lock and presence mutator did
# not (nor the node registry's, the Block Group descriptors' and the
# stat publish). Over a torn or damaged sector, that turned the damage
# into a record every checker accepts -- the corruption made permanent
# and invisible.
#
# Staged: an open for write is held between its own (good) read of the
# record and the swap that claims the file lock (lock_open_pause_ms),
# and the namespace sector's checksum is broken on the device in that
# window -- a peer's write torn, or damage, arriving after the check. The
# swap must refuse the image; the sector must still fail its checksum.
#
# DISCRIMINATION: with the lock mutator restamping, the open succeeds
# and fsck finds the record clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 casbad)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt casbad)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo x >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
[ -w /sys/module/cetrafs/parameters/lock_open_pause_ms ] || { skip "lock_open_pause_ms missing"; ct_exit; }
corr() { sed -n 's/^corruptions: //p' "$(ct_procdir "$DEV")/info"; }
C0="$(corr)"
MARK="$(dmesg_mark)"
ct_param_set lock_open_pause_ms 2000
RES="$(python3 - "$MNT/f" "$IPOKE" "$IMG" "$INO" <<'PY'
import errno, os, subprocess, sys, threading, time
def damage():
    time.sleep(0.7)   # inside the open's pause, after its own read
    subprocess.run([sys.argv[2], sys.argv[3], "corrupt", sys.argv[4]], check=True, stderr=subprocess.DEVNULL)
t = threading.Thread(target=damage); t.start()
try:
    fd = os.open(sys.argv[1], os.O_WRONLY)
    os.close(fd); r = "open=ok"
except OSError as e:
    r = "open=" + errno.errorcode.get(e.errno, str(e.errno))
t.join(); print(r)
PY
)"
log "$RES"
sleep 1
dmesg_since "$MARK" | grep -q "lock CAS: the namespace sector on the device fails its checksum" &&
    pass "the lock swap met the damaged sector and refused it" ||
    log "(the lock swap logged no refusal)"
# And the refusal is damage found on read -- kind 2, counted -- not a
# log line and nothing else (docs/internal/ERRORS.md).
C1="$(corr)"
[ -n "$C0" ] && [ -n "$C1" ] && [ "$C1" -gt "$C0" ] &&
    pass "the refusal was counted as damage (corruptions $C0 -> $C1)" ||
    fail "the refused swap was only logged: corruptions $C0 -> $C1"
ct_umount "$MNT" || umount -l "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
if grep -qiE "ino(de)?[ =]$INO\b.*(checksum|crc)|(checksum|crc).*ino(de)?[ =]$INO\b" <<<"$OUT"; then
    pass "the damage is still visible: fsck reports ino $INO's checksum"
else
    fail "fsck finds ino $INO clean -- a swap stamped a fresh checksum over the damaged sector"
    grep -E '^(ERR|WARN)' <<<"$OUT" | head -3 >&2 || true
fi
ct_exit
