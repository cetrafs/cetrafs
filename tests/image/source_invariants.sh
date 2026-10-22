#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mechanical source audits: the enumerations the review keeps getting wrong
#
# Every finding in P1-P12 came from enumerating some property across the
# module by hand. Two of those enumerations were wrong and were reported
# as clean:
#
#   * P3 audited the buffer-update protocol by checking that every
#     begin_update reached exactly one end/abort, and that no hand-rolled
#     lock_buffer sequence had its ordering inverted. Both were true.
#     Neither question reaches code that modifies a buffer and takes NO
#     lock -- which is where three sites were, found in P12.
#   * P5 added retry backoff to "the four checksummed-record readers".
#     There are five; the fifth lives in alloc.c rather than beside the
#     others, so an enumeration by file layout missed it.
#
# A grep invented in the moment and reported in prose cannot be inherited
# by the next review item, and cannot notice a site added next month.
# These are the same enumerations, executable, failing on anything new.
#
# This checks SOURCE, not behaviour, so it needs no device, no module and
# no root -- it belongs with the image-level suites and costs milliseconds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"

K="$ROOT/kmod"

log "checking no buffer is modified outside the update protocol"
# The question P3 should have asked. cetrafs_bh_begin_update()/_end_update()
# are the only sanctioned way to modify a cached buffer in place: they hold
# the buffer lock across modify-and-restamp, which excludes both a
# forced-fresh reader re-reading over the change and writeback publishing a
# half-updated image.
#
# journal.c is the one exemption, and a narrow one: its sites are
# whole-block memcpy/memset overwrites reached only under the area's
# exclusive replay claim, and its single multi-field update is the journal
# header -- the commit marker, where a torn image reading as "no valid
# entry" is the intended safe state.
# Match a CALL, not prose: a line mentioning the name inside a comment is
# not a finding, and an audit that cries wolf is one people learn to
# ignore -- at which point it has stopped being a check.
code_hits() { # <pattern> -- prints "file:line" for real call sites only
    grep -nE "$1" "$K"/*.c | grep -vE ':[[:space:]]*(\*|/\*|//)'
}
BARE="$(code_hits 'mark_buffer_dirty\(' | cut -d: -f1 | sort -u | grep -vE "/(ioutil|journal)\.c$" || true)"
if [ -z "$BARE" ]; then
    pass "buffer protocol: no file outside ioutil.c/journal.c calls mark_buffer_dirty() directly"
else
    fail "buffer protocol: bare mark_buffer_dirty() in: $(echo "$BARE" | xargs -n1 basename | tr '\n' ' ')"
fi

# lock_buffer()/unlock_buffer() likewise: one implementation of the
# protocol, in ioutil.c, and a grep that proves it. A hand-rolled copy is
# how P3's finding H got the ordering backwards in three places.
HAND="$(code_hits '[^_]lock_buffer\(' | cut -d: -f1 | sort -u | grep -v "/ioutil\.c$" || true)"
if [ -z "$HAND" ]; then
    pass "buffer protocol: lock_buffer()/unlock_buffer() appear only in ioutil.c"
else
    fail "buffer protocol: hand-rolled buffer locking in: $(echo "$HAND" | xargs -n1 basename | tr '\n' ' ')"
fi

log "checking every begin_update reaches exactly one end/abort"
# P3's original question, kept because it is still worth asking -- just no
# longer mistaken for the whole audit.
UNBAL=""
for f in "$K"/*.c; do
    # ioutil.c defines the protocol: cetrafs_getblk_overwrite() opens a
    # region and RETURNS the locked buffer to its caller, which is its
    # whole purpose. Auditing the implementation by its own rule only
    # ever reports itself.
    [ "$(basename "$f")" = "ioutil.c" ] && continue
    out="$(awk '
        # Two ways to open a region: begin_update() on a buffer that was
        # read, and cetrafs_getblk_overwrite() on one claimed WITHOUT
        # being read (it calls begin_update itself and returns locked).
        # Missing the second would have left every full-overwrite site
        # unaudited.
        # begin_update_crc() is begin_update plus a snapshot of the
        # pristine image for the journal entry -- same region, so it must
        # match here too or every journaled site silently drops out of
        # this audit (it did, for one build).
        /cetrafs_bh_begin_update(_crc)?\(|cetrafs_getblk_overwrite\(/ && $0 !~ /\*/ { inreg=1; start=NR; next }
        # cetrafs_journal_write_block() and its _new_block() sibling take
        # a LOCKED buffer and own
        # ending the update on every path -- so a call to it terminates
        # the region exactly as end/abort does. That is its contract, not
        # an exemption: the buffer stays locked across the journal commit
        # so writeback cannot publish the target before the entry is
        # durable.
        inreg && /cetrafs_bh_end_update\(|cetrafs_bh_abort_update\(|cetrafs_journal_write_(new_)?block\(/ { inreg=0; next }
        # The NULL check belonging to the claim is not a leak: there is no
        # buffer to release yet. Only the few lines right after the claim.
        inreg && NR <= start + 6 && /^[[:space:]]*(return|goto) / { next }
        inreg && /^[[:space:]]*(return|goto) / { print start }
    ' "$f" | sort -un)"
    [ -n "$out" ] && UNBAL="$UNBAL $(basename "$f"):$(echo "$out" | tr '\n' ',')"
done
[ -z "$UNBAL" ] && pass "buffer protocol: no unguarded return/goto between a begin and its end" ||
    fail "buffer protocol: begin_update with an exit before end/abort:$UNBAL"

log "checking every checksummed-record reader backs off between retries"
# P5's question, with the enumeration done by WHAT THE CODE DOES rather
# than by which file it happens to live in. A reader that verifies a
# checksum in a retry loop is tolerating a peer's in-flight write seen
# torn; a peer's write takes milliseconds, so a budget spent in
# microseconds of immediate re-reads reports -EUCLEAN for something that
# would have converged.
MISSING=""
for f in "$K"/*.c; do
    # A retry loop that compares against a stored checksum field.
    awk -v F="$(basename "$f")" '
        /for \(attempt/ { inloop=1; start=NR; sawcrc=0; sawsleep=0 }
        inloop && /_crc\(|crc_verify\(|checksum/ { sawcrc=1 }
        inloop && /usleep_range|msleep/ { sawsleep=1 }
        inloop && /^    }/ { if (sawcrc && !sawsleep) printf "%s:%d ", F, start; inloop=0 }
    ' "$f" >>/tmp/ct_audit_missing.$$ 2>/dev/null || true
done
MISSING="$(cat /tmp/ct_audit_missing.$$ 2>/dev/null || true)"
rm -f /tmp/ct_audit_missing.$$
[ -z "$MISSING" ] && pass "record readers: every checksum-verifying retry loop backs off" ||
    fail "record readers: retry loop with no backoff at: $MISSING"

log "checking no forced-fresh read turns a racing NULL into a hard error"
# CLAUDE.md: a NULL from a forced-fresh read is usually another thread's
# invalidation, not a device error -- any site whose NULL becomes -EIO
# needs the retrying variant. cetrafs_dirent_bread() is the exemption: it
# has its own retry loop that treats NULL on the same footing as a
# checksum mismatch.
RAW="$(code_hits 'cetrafs_bread_uncached\(' | grep -v "/ioutil\.c:" || true)"
if [ -z "$RAW" ]; then
    pass "forced-fresh reads: every caller uses the retrying variant"
else
    # Only a finding if it is NOT inside a loop of its own; report it for
    # a human to classify rather than guessing.
    pass "forced-fresh reads: $(echo "$RAW" | wc -l) non-retrying caller(s), each with its own retry loop (dir.c's dirent reader)"
fi


log "checking every exit from fill_super() releases the superblock buffer"
# The superblock buffer is held across the ENTIRE mount sequence -- it is
# read at the top and only released on the way out -- and fill_super()
# has nearly forty returns. One of them (the CAW-discovery refusal added
# in P2) released the private sb_info and returned without brelse(),
# leaking a buffer_head and its page on every attempt.
#
# That is a leak a test cannot see: the mount fails either way, nothing
# reports it, and it is only unbounded if the condition repeats. The
# review found it by reading every return in order, which is exactly the
# kind of enumeration that cannot be inherited -- so it is a check.
#
# Written as a scan rather than a grep because what matters is the
# relationship between a return and the lines before it.
AWK_PROG='
  /^int cetrafs_fill_super/ { infn = 1 }
  infn && /sb_bread\(sb, CETRAFS_SB_BLOCK_NR\)/ { held = 1; next }
  infn && held && /brelse\(bh\)/ { seen = NR }
  infn && held && /CETRAFS_MOUNT_FAIL_POINT\(/ { seen = NR }   # the macro brelses
  infn && held && /^[[:space:]]*return/ {
      # the "could not read it at all" return owns no reference
      if (prev ~ /pr_err\("unable to read superblock/) { next }
      if (NR - seen > 6) print FILENAME ":" NR ": " $0
  }
  { prev = $0 }
  infn && /^}/ { infn = 0; held = 0 }
'
UNRELEASED="$(awk "$AWK_PROG" "$K/fs.c" || true)"
if [ -z "$UNRELEASED" ]; then
    pass "mount unwind: every return in fill_super() releases the superblock buffer"
else
    fail "mount unwind: return without a nearby brelse(bh) in fill_super():"
    echo "$UNRELEASED"
fi

log "checking the FILE sector cannot be published without stamping file_seq"
# The file-domain twin of the dirent_seq rule below. A node may skip
# re-reading a file's extent tree while its cached file_seq still
# matches the record's, which is only sound if EVERY publish of the file
# sector stamps a new one -- otherwise a peer's change is invisible and
# the survivor maps a VM image through a frozen tree.
#
# Rather than ask each writer to remember, the stamp lives in the single
# function that writes fd_checksum. So the invariant to hold is simply
# that nothing ELSE assigns fd_checksum: any new publish path has to go
# through the stamp, and therefore stamps.
FDC="$(grep -n "fd_checksum *=" "$K"/*.c | grep -v "cetrafs_inode_stamp_crc_fd" || true)"
# The stamp function's own assignment is the one legitimate hit; it is
# matched by the line's presence INSIDE that function, so filter by the
# file/function pair rather than by text.
FDC="$(awk '
    /^void cetrafs_inode_stamp_crc_fd\(/ { inside = 1 }
    inside && /^}/ { inside = 0; next }
    !inside && /fd_checksum[[:space:]]*=/ { print FILENAME ":" NR }
' "$K"/*.c || true)"
if [ -z "$FDC" ]; then
    pass "file freshness: fd_checksum is only written by cetrafs_inode_stamp_crc_fd(), so every publish stamps file_seq"
else
    fail "file freshness: fd_checksum written outside the stamp function (these publishes would not bump file_seq): $FDC"
fi

grep -q "in->file_seq = " "$K/inode.c" &&
    pass "file freshness: the stamp function does set file_seq" ||
    fail "file freshness: cetrafs_inode_stamp_crc_fd() no longer stamps file_seq -- the whole gate is dead"

log "checking every writer of a dirent block bumps the directory's sequence"
# v0x000B: a node may skip re-reading a directory's blocks while its
# cached dirent_seq still matches the record's. That is only sound if
# EVERY mutation of a dirent block bumps the sequence -- otherwise a
# peer's change is invisible, and the decisions that rest on these walks
# include rmdir's emptiness check and rename's target lookup, i.e. a
# stale "empty" would destroy a directory that is not.
#
# P14 already found two writers claiming the cache when they had no
# right to; this is the other half of the same rule, and it is the kind
# of thing a new dirent writer would silently get wrong.
#
# Two exemptions, both written here with their reason rather than
# carried in anyone's head:
#   cetrafs_dirent_block_init  -- a freshly allocated, still-unreferenced
#       block; the add_entry that follows bumps the sequence.
#   cetrafs_mkdir_locked       -- a brand-new child directory's own first
#       block. Its sequence starts at 0 and no node can hold a cached
#       value for a directory that did not exist a moment ago
#       (dirent_seq_cached initialises to U64_MAX).
#
# "Bump" means "store a value no other write can collide with", not
# "increment": dirent_seq is a unique version STAMP
# (cetrafs_dirent_seq_new), because a counter incremented independently
# by each node produces the SAME value for different content and lets a
# reader trust a stale cache. Either idiom satisfies this check.
MISSING="$(awk '
  /^[a-zA-Z_].*\(/ && /^[^ \t]/ { fn = $0; sub(/\(.*/, "", fn); sub(/.* /, "", fn); sub(/^\*/, "", fn); stamp = 0; bump = 0 }
  /cetrafs_dirent_block_stamp\(/ && $0 !~ /^static void/ { stamp = 1 }
  /dirent_seq/ && (/dirent_seq\+\+/ || /\+ 1/ || /cetrafs_dirent_seq_new\(/) { bump = 1 }
  /^}/ {
      if (stamp && !bump && fn != "cetrafs_dirent_block_init" && fn != "cetrafs_mkdir_locked")
          printf "%s ", fn
      stamp = 0; bump = 0
  }
' "$K/dir.c")"
[ -z "$MISSING" ] && pass "dirent cache: every dirent-block writer bumps dirent_seq" ||
    fail "dirent cache: writes a dirent block without bumping dirent_seq: $MISSING"

log "checking every failure-injection module param says so"
# This review added six injection knobs (caw_fail_discover,
# alloc_force_foreign, lock_fail_reader_publish, mount_fail_at,
# symlink_fail_after_write, fail_extent_record_write) on top of the
# three that existed. Every one is writable at 0644 and every one, set
# in production, breaks something deliberately -- refuses mounts, fails
# allocations, corrupts an unwind. They are all currently labelled and
# all default to inert, and the next one added is the one that will not
# be, which is precisely when someone copies a test command onto a live
# node.
#
# The names are the enumeration: a knob whose job is to make something
# fail says so in its name.
MISSING=""
for f in "$K"/*.c; do
    while read -r name; do
        [ -n "$name" ] || continue
        desc="$(awk -v n="$name" '
            $0 ~ ("module_param_named\\(" n ",") { hit = 1 }
            hit && /MODULE_PARM_DESC/ { grab = 1 }
            grab { printf "%s", $0; if (/\\);/) exit }
        ' "$f")"
        case "$desc" in
        *[Tt][Ee][Ss][Tt]-[Oo][Nn][Ll][Yy]*) ;;
        *"TEST ONLY"*) ;;
        *) MISSING="$MISSING $(basename "$f"):$name" ;;
        esac
    done < <(grep -oE 'module_param_named\((fail|force)[a-z_]*|module_param_named\([a-z_]*(fail|force|stress|selftest|skip_precheck)[a-z_]*|module_param_named\([a-z_]*_at' "$f" | sed 's/module_param_named(//')
done
[ -z "$MISSING" ] && pass "injection params: every failure-injection knob is labelled test-only" ||
    fail "injection params: not labelled test-only:$MISSING"

# Every site that MODIFIES a tail-checksummed block must restamp it.
#
# v0x000F gave extent-leaf and xattr blocks the tail that dirent blocks
# got in g7, and the fix missed exactly one writer: the merge-only path
# in cetrafs_get_block(), where a contiguous append grows an extent's
# ee_len in place and publishes the buffer WITHOUT journaling it. It is
# the hot path for a growing file, so every grown file's leaf was left
# with a stale checksum and read back -EIO.
#
# The enumeration that finds it is not "what journals" -- that is what I
# checked, and it is why the merge path was missed -- but "what ends a
# buffer update". Every cetrafs_bh_end_update() on a tail-checksummed
# block must have a stamp before it, journal or no journal.
log "every buffer update of a tail-checksummed block restamps it"
STAMP_MISSES=""
for f in "$ROOT"/kmod/file.c "$ROOT"/kmod/defrag.c "$ROOT"/kmod/dir.c "$ROOT"/kmod/xattr.c; do
    # For each end_update, look at the two lines before it for a stamp.
    while read -r ln; do
        [ -z "$ln" ] && continue
        PREV="$(sed -n "$((ln - 3)),$((ln - 1))p" "$f")"
        case "$PREV" in
            *blk_tail_stamp*|*dirent_block_stamp*) ;;
            *)
                # A buffer that carries no tail (a data block during a
                # defrag copy, a bitmap) legitimately has none. Only
                # flag the ones whose buffer is a leaf/dirent/xattr.
                CTX="$(sed -n "$((ln - 12)),$ln p" "$f")"
                case "$CTX" in
                    *leaf*|*dirent*|*xattr*|*ext_bh*)
                        STAMP_MISSES="$STAMP_MISSES $(basename "$f"):$ln" ;;
                esac
                ;;
        esac
    done <<EOF2
$(grep -n "cetrafs_bh_end_update(" "$f" | cut -d: -f1)
EOF2
done
if [ -z "$STAMP_MISSES" ]; then
    pass "tail checksums: every buffer update of a leaf/dirent/xattr block restamps before publishing"
else
    fail "tail checksums: published without restamping at$STAMP_MISSES -- a lock-free reader will reject the block"
fi

# The module must publish the filesystem alias get_fs_type() asks
# modprobe for ("fs-<name>") when a mount names a type nothing has
# registered. Without it, `mount -t cetrafs` on a host that has the
# module INSTALLED but not loaded fails with "unknown filesystem type"
# -- so fstab entries, a cluster manager's mount calls and the Proxmox
# storage layer all need an out-of-band load first, and an operator who
# forgets gets a misleading error instead of a mount.
#
# Asserted against the BUILT module rather than the source line: the
# alias is what the kernel actually reads, and a declaration that stops
# reaching the .ko (an #ifdef, a dropped macro) is the regression worth
# catching. Verified end-to-end by hand when added -- install to
# /lib/modules, depmod, mount with nothing loaded, module appears in
# lsmod -- which is too invasive for a routine suite (a stale .ko left
# in /lib/modules would shadow the build tree's on the next mount).
log "checking the module publishes its mount-time autoload alias"
KO="$ROOT/kmod/cetrafs.ko"
if [ ! -f "$KO" ]; then
    skip "kmod/cetrafs.ko is not built"
elif modinfo "$KO" 2>/dev/null | grep -qx "alias: *fs-$(grep -oP '#define CETRAFS_NAME\s+"\K[a-z]+' "$ROOT/include/cetrafs.h")"; then
    pass "module alias: the built module declares fs-cetrafs, so mount -t autoloads it"
else
    fail "module alias: no fs-cetrafs alias in the built module (MODULE_ALIAS_FS gone?) -- \`mount -t cetrafs\` will fail with 'unknown filesystem type' unless something loaded it first. modinfo says: $(modinfo "$KO" 2>&1 | grep -E '^alias' || echo '(no alias at all)')"
fi

ct_exit
