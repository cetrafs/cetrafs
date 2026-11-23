#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refused extent-leaf write is not an operation's ENOSPC: it waits for space; only dirent and xattr blocks fail
#
# A refused metadata write fails just its operation with ENOSPC when the
# block is a directory-entry or xattr block -- those operations undo
# themselves. Anything else waits for the space to come back, the mount
# up: a tree edit spans several blocks, and an ENOSPC halfway through
# one leaves the rest published (audit 2026-11-14 A-4). The journal chose the kind by
# asking whether the block's CONTENT passed the dirent or the xattr
# structure check -- and the dirent check only bounds name_len at
# 266-byte strides, which an extent leaf passes. So a refused leaf write
# was failed as an operation's ENOSPC, the tree edit cut in half (audit 2026-11-22 N-52). It is decided by the
# block's own tail magic now.
#
# A file with an external leaf; tree edits written at once
# (leaf_defer_off); the leaf's write refused (meta_write_nospc_block)
# under a write that adds an extent:
#   1. the refusal is not an operation's (journal_op_refusals unchanged):
#      the write waits for space, and once the refusal is lifted it
#      completes, the file reading back as written.
#
# DISCRIMINATION: journal_op_refusable_by_content=1 (the old choice):
# the write fails ENOSPC and the refusal is counted as an operation's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_op_refusable_by_content meta_write_nospc_block leaf_defer_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt lrn)"
ct_track mnt "$MNT"
IPOKE="$(ct_helper inode_block_poke)"
ct_param_set journal_op_refusable_by_content 0
ct_param_set journal_nospc_stops 0
ct_param_set space_wait_stops 0
ct_param_set meta_write_nospc_block 0
ct_param_set leaf_defer_off 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# <tag> <by_content 0|1> -> RES
round() {
    local img dev mark proc ino p n w wp waited out
    out="$(ct_tmp lrn-out)"
    img="$(ct_image 560 "lrn$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    python3 -I - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(30):
    os.pwrite(fd, b'f' * 4096, i * 2 * 4096)
os.fsync(fd); os.close(fd)
PY
    sync
    ino="$(stat -c %i "$MNT/frag")"
    p="$("$IPOKE" "$dev" leaf "$ino" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
    [ -n "$p" ] || { fail "setup: frag has no external leaf"; ct_exit; }
    n="$(sed -n 's/^journal_op_refusals: //p' "$proc/info")"
    echo "$2" >$P/journal_op_refusable_by_content
    echo 1 >$P/leaf_defer_off
    mark="$(dmesg_mark)"
    echo "$p" >$P/meta_write_nospc_block
    python3 -I - "$MNT/frag" >"$out" <<'PY' &
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY)
    os.pwrite(fd, b'g' * 4096, 100 * 4096)  # a new extent: the leaf is edited
    os.fsync(fd); os.close(fd); print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
PY
    wp=$!
    # Either answer comes within seconds: the old choice fails the write,
    # the new one logs that it waits for space -- lifted then.
    wait_for 30 "[ -s '$out' ] || dmesg_since '$mark' | grep -q 'no space to overwrite.*block $p '" || true
    waited=$(dmesg_since "$mark" | grep -c "no space to overwrite.*block $p " || true)
    echo 0 >$P/meta_write_nospc_block
    wait_for 60 "[ -s '$out' ]" || true
    wait "$wp" || true
    w="$(cat "$out")"
    echo 0 >$P/leaf_defer_off
    echo 0 >$P/journal_op_refusable_by_content
    RES="write=$w refusals=$(($(sed -n 's/^journal_op_refusals: //p' "$proc/info") - n))"
    RES="$RES waited=$waited stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    RES="$RES data=$(python3 -I -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); print("ok" if os.pread(fd,4096,100*4096)==b"g"*4096 else "bad")' "$MNT/frag" 2>/dev/null || echo none)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (by content, as before): $C"
[ "$(get waited "$R")" -ge 1 ] || [ "$(get write "$C")" = ENOSPC ] ||
    { fail "setup: the leaf write was never refused ($R / $C)"; ct_exit; }
[ "$(get refusals "$R")" = 0 ] && [ "$(get waited "$R")" -ge 1 ] && [ "$(get write "$R")" = 0 ] &&
    [ "$(get data "$R")" = ok ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "1: a refused leaf write is not an operation's ENOSPC: it waited for space and completed" || fail "1: $R"
[ "$(get refusals "$C")" -ge 1 ] && [ "$(get write "$C")" = ENOSPC ] &&
    pass "control: chosen by content, the leaf passed as a dirent block and the write failed ENOSPC" ||
    fail "control: the old choice did not take the leaf for a dirent/xattr block -- the suite proves nothing: $C"
ct_exit
