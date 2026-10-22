#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a new inode's owner and mode, and what a failed create leaves behind
#
# The three creation paths (create, mkdir, symlink) computed the new
# inode's owner as current_fsuid()/current_fsgid() directly. That skips
# both halves of what the VFS's own inode_init_owner() does:
#
#   * a setgid DIRECTORY passes its group to everything created inside
#     it, and a new SUBDIRECTORY inherits the setgid bit itself -- or the
#     inheritance stops one level down. That is the standard way a
#     shared, group-writable tree is built, which is exactly how a
#     datastore of VM images gets shared between service accounts.
#   * the mnt_idmap argument was accepted and ignored, so on an idmapped
#     mount (a container's view -- the normal case under Proxmox) files
#     were stamped with the raw caller's ids instead of the mapped ones.
#
# tmpfs is the reference: the same sequence is run there and the two
# must agree.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 owner)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt owner)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Build the same tree on tmpfs and on cetrafs, then compare.
REF="$(ct_mnt ownerref)"
build() {
    local root="$1"
    mkdir "$root/sg"
    chgrp 5 "$root/sg"
    chmod g+s "$root/sg"
    : >"$root/sg/file"
    mkdir "$root/sg/sub"
    ln -s target "$root/sg/link"
    mkdir "$root/sg/sub/deeper"
    : >"$root/plain"
}
build "$MNT"
build "$REF"

log "a setgid directory passes its group on, exactly as tmpfs does"
cmp_attr() { # <relative path> <stat format> <what>
    local got want
    got="$(stat -c "$2" "$MNT/$1")"
    want="$(stat -c "$2" "$REF/$1")"
    if [ "$got" = "$want" ]; then
        pass "$3: $got (matches tmpfs)"
    else
        fail "$3: cetrafs says '$got', tmpfs says '$want'"
    fi
}
cmp_attr sg/file '%g' "a file created in a setgid directory takes the directory's group"
cmp_attr sg/sub '%g' "a subdirectory takes the directory's group"
cmp_attr sg/sub '%a' "a subdirectory inherits the setgid bit itself"
cmp_attr sg/link '%g' "a symlink takes the directory's group"
cmp_attr sg/sub/deeper '%a' "the inheritance carries to the next level down"
cmp_attr plain '%g' "a file created outside a setgid directory takes the creator's group"

log "the attributes survive a remount"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
cmp_attr sg/file '%g' "the group is on disk, not just in core"
cmp_attr sg/sub '%a' "the setgid bit is on disk, not just in core"

log "ordinary create semantics"
: >"$MNT/excl"
if (set -o noclobber; : >"$MNT/excl") 2>/dev/null; then
    fail "O_CREAT|O_EXCL succeeded on an existing name"
else
    pass "O_CREAT|O_EXCL on an existing name is refused"
fi
# mode is honoured, less the umask the shell applies
(umask 077 && : >"$MNT/private")
[ "$(stat -c '%a' "$MNT/private")" = "600" ] && pass "the umask is applied to a new file's mode" ||
    fail "a file created under umask 077 is mode $(stat -c '%a' "$MNT/private")"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
