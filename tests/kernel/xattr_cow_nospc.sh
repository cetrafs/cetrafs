#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# setxattr and removexattr on a regular file work when no block is free for the copy
#
# A regular file's xattr block is replaced, not edited in place, so that
# the pointer swap is the one publish and asks about peers atomically
# (audit 2026-11-15 BM N-74). That needs a free block: on a full volume
# both set and remove failed ENOSPC -- including the removals an operator
# uses to make room (F-20). With no block for the copy the call now
# edits in place, as before.
#
# A file with two attributes, the copy's allocation answering ENOSPC
# (xattr_cow_nospc=1):
#   1. removing one attribute succeeds; the other is still there;
#   2. replacing that one succeeds and reads back; both went in place.
#
# DISCRIMINATION: xattr_cow_nospc_fails=1: both fail ENOSPC.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in xattr_cow_nospc xattr_cow_nospc_fails; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt xcn)"
ct_track mnt "$MNT"
ct_param_set xattr_cow_nospc 0
ct_param_set xattr_cow_nospc_fails 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <fails 0|1> -> RES
round() {
    local dev proc f0 out
    dev="$(ct_dev 560 "xcn$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    : >"$MNT/f"
    python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.a", b"one"); os.setxattr(sys.argv[1], "user.b", b"two")' "$MNT/f"
    f0="$(sed -n 's/^xattr_inplace_fallbacks: //p' "$proc/info")"
    echo 1 >$P/xattr_cow_nospc
    echo "$2" >$P/xattr_cow_nospc_fails
    out="$(python3 -I - "$MNT/f" <<'PY'
import errno, os, sys
f = sys.argv[1]
def rc(fn):
    try:
        fn(); return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))
r1 = rc(lambda: os.removexattr(f, "user.a"))
r2 = rc(lambda: os.setxattr(f, "user.b", b"three"))
names = ",".join(sorted(os.listxattr(f)))
b = os.getxattr(f, "user.b").decode() if "user.b" in names else "none"
print("rm=%s set=%s names=%s b=%s" % (r1, r2, names or "none", b))
PY
)"
    echo 0 >$P/xattr_cow_nospc
    echo 0 >$P/xattr_cow_nospc_fails
    RES="$out fallbacks=$(($(sed -n 's/^xattr_inplace_fallbacks: //p' "$proc/info") - f0))"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}

round c 1
C="$RES"
log "control (no block fails the call): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get rm "$R")" = ok ] && [ "$(get names "$R")" = user.b ] &&
    pass "1: the removal succeeded with no block free; the other attribute stays" || fail "1: $R"
[ "$(get set "$R")" = ok ] && [ "$(get b "$R")" = three ] && [ "$(get fallbacks "$R")" = 2 ] &&
    [ "$(get fsck_err "$R")" = 0 ] &&
    pass "2: the replace succeeded in place; both edits went in place; fsck clean" || fail "2: $R"
[ "$(get rm "$C")" = ENOSPC ] && [ "$(get set "$C")" = ENOSPC ] &&
    pass "control: without the fallback both failed ENOSPC" || fail "control: $C"
ct_exit
