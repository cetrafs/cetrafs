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

# sync_dirty_buffer() decides failure by looking at BH_Uptodate AFTER the
# write, and this module's forced-fresh readers clear that bit
# concurrently: a write that landed reads as -EIO (it failed
# dir_concurrency on 2026-11-01), and a site that cannot trust the result
# learns to ignore it -- which is how eight sites came to drop real write
# errors. cetrafs_sync_buffer() reports BH_Write_EIO, the write's own
# outcome; it lives in ioutil.c and is the only caller left.
SDB="$(code_hits '[^_]sync_dirty_buffer\(' | cut -d: -f1 | sort -u | grep -v "/ioutil\.c$" || true)"
if [ -z "$SDB" ]; then
    pass "buffer protocol: no file outside ioutil.c calls sync_dirty_buffer()"
else
    fail "buffer protocol: sync_dirty_buffer() (its result comes from BH_Uptodate) in: $(echo "$SDB" | xargs -n1 basename | tr '\n' ' ')"
fi

# A plain sb_bread() racing a cetrafs_invalidate_block() of the same
# block comes back NULL with no device error (__bread_slow() re-checks
# BH_Uptodate after its read completes). Caller after caller turned that
# into -EIO, and one of those error paths left a birth claim on a dead
# record: blocks then read as shared between two files (2026-11-03).
# cetrafs_bread_retry() is the sanctioned reader; ioutil.c implements
# it, and fs.c's two reads run in fill_super, before anything else can
# reach the mount.
SBR="$(code_hits '[^_]sb_bread\(' | grep -vE "/ioutil\.c:" | grep -vE "/fs\.c:" || true)"
if [ -z "$SBR" ]; then
    pass "block reads: no plain sb_bread() outside ioutil.c and fill_super"
else
    fail "block reads: plain sb_bread() (a racing invalidate reads as -EIO) at: $(echo "$SBR" | cut -d: -f1,2 | xargs -n1 basename | tr '\n' ' ')"
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
            $0 ~ ("(module_param_named|cetrafs_test_param)\\(" n ",") { hit = 1 }
            hit && /MODULE_PARM_DESC/ { grab = 1 }
            grab { printf "%s", $0; if (/\\);/) exit }
        ' "$f")"
        case "$desc" in
        *[Tt][Ee][Ss][Tt]-[Oo][Nn][Ll][Yy]*) ;;
        *"TEST ONLY"*) ;;
        *) MISSING="$MISSING $(basename "$f"):$name" ;;
        esac
    done < <(grep -oE '(module_param_named|cetrafs_test_param)\((fail|force)[a-z_]*|(module_param_named|cetrafs_test_param)\([a-z_]*(fail|force|stress|selftest|skip_precheck)[a-z_]*|(module_param_named|cetrafs_test_param)\([a-z_]*_at' "$f" | sed -E 's/(module_param_named|cetrafs_test_param)\(//')
done
NINJ="$(grep -ohE '(module_param_named|cetrafs_test_param)\((fail|force)[a-z_]*' "$K"/*.c | wc -l)"
[ "$NINJ" -ge 5 ] || fail "injection params: found only $NINJ fail/force knobs -- the scan is not seeing the tree"
[ -z "$MISSING" ] && pass "injection params: every failure-injection knob is labelled test-only" ||
    fail "injection params: not labelled test-only:$MISSING"

# Audit R23: a TEST ONLY knob bends a safety check for every mount, and
# root can flip it at run time. Declared through cetrafs_test_param(), a
# write is logged and taints the kernel; declared with plain
# module_param_named() it leaves no trace. Enumerated by description.
untraced_test_params() {
    awk '
        /module_param_named\(/ { n = $0; sub(/.*module_param_named\(/, "", n); sub(/,.*/, "", n); decl[n] = FILENAME ":" FNR }
        /MODULE_PARM_DESC\(/ { d = $0; sub(/.*MODULE_PARM_DESC\(/, "", d); nm = d; sub(/,.*/, "", nm)
                               if (nm in decl && tolower($0) ~ /test[- ]only/) print decl[nm] ":" nm }' "$@"
}
SAMPLE="$(ct_tmp testparam-sample)"
printf '%s\n' 'module_param_named(x_knob, x, bool, 0644);' 'MODULE_PARM_DESC(x_knob, "TEST ONLY: bends a check");' >"$SAMPLE"
[ -n "$(untraced_test_params "$SAMPLE")" ] || fail "test params: the check does not flag the known-bad sample"
NTP="$(grep -c 'cetrafs_test_param(' "$K"/*.c | awk -F: '{ s += $2 } END { print s }')"
[ "$NTP" -ge 100 ] || fail "test params: only $NTP traced knobs found -- the scan is not seeing the tree"
HITS="$(untraced_test_params "$K"/*.c | sed "s|$K/||")"
[ -z "$HITS" ] && pass "test params: all $NTP TEST ONLY knobs log and taint on write" ||
    fail "test params: TEST ONLY knob declared without cetrafs_test_param() (no log, no taint): $(echo $HITS)"

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

# BUG-CLASSES.md class 18, async lifetime. A work item, timer or thread
# that runs after what it touches is gone is a use-after-free -- the
# 0.9.3 field Oops was a reconcile on the SYSTEM workqueue, which nothing
# drains at unmount, whose iput() evicted a deleted file after put_super
# had freed sb_info. Every async source must name the cancel that runs
# before teardown, and a new one fails here until it does.
log "checking every async work source names its drain (class 18)"
# body <file> <function>: the function's body, from its definition line
# to the closing brace in column 0.
body() { awk -v f="$2" '$0 ~ ("^[a-z].*[ *]" f "\\(") && !/;$/ { on = 1 } on { print } on && /^}/ { exit }' "$1"; }
FREE_SB="$(body "$K/fs.c" cetrafs_free_sb_info)"
KILL_SB="$(body "$K/fs.c" cetrafs_kill_sb)"
[ -n "$FREE_SB" ] && [ -n "$KILL_SB" ] ||
    fail "async drains: cannot find cetrafs_free_sb_info/cetrafs_kill_sb bodies -- the check below would pass vacuously"

# (a) Shared system workqueues: never drained for us. Each item queued on
# one is listed with the cancel that stops it and the teardown call that
# reaches that cancel from cetrafs_free_sb_info().
#   file | queued item | cancel call (in that file) | called from free_sb_info
SHARED_OK='
fs.c|sbi->stop_work|cancel_work_sync(&sbi->stop_work)|cancel_work_sync(&sbi->stop_work)
fs.c|sbi->lease_work|cancel_work_sync(&sbi->lease_work)|cancel_work_sync(&sbi->lease_work)
scrub.c|s->work|cancel_delayed_work_sync(&s->work)|cetrafs_scrub_stop(
heartbeat.c|hb->work|cancel_delayed_work_sync(&hb->work)|cetrafs_heartbeat_stop(
heartbeat.c|hb->maint|cancel_delayed_work_sync(&hb->maint)|cetrafs_heartbeat_stop(
'
UNDRAINED=""
SHARED_SEEN=""
for f in "$K"/*.c; do
    fn="$(basename "$f")"
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        SHARED_SEEN="$SHARED_SEEN $fn|$item|"
        row="$(grep -F "$fn|$item|" <<<"$SHARED_OK" || true)"
        if [ -z "$row" ]; then
            UNDRAINED="$UNDRAINED $fn:$item(not-listed)"
            continue
        fi
        cancel="$(cut -d'|' -f3 <<<"$row")"
        caller="$(cut -d'|' -f4 <<<"$row")"
        grep -qF "$cancel" "$f" || UNDRAINED="$UNDRAINED $fn:$item(no-$cancel)"
        grep -qF "$caller" <<<"$FREE_SB" || UNDRAINED="$UNDRAINED $fn:$item(free_sb_info-never-calls-$caller)"
    done < <(grep -v '^\s*\*' "$f" | grep -oE '(schedule_(delayed_)?work\(|queue_(delayed_)?work\(system_[a-z_]*wq, )&[a-z_>.-]+' |
        sed -E 's/.*&//')
done
while IFS= read -r row; do
    [ -n "$row" ] || continue
    grep -qF "$(cut -d'|' -f1-2 <<<"$row")|" <<<"$SHARED_SEEN" || UNDRAINED="$UNDRAINED stale-entry:$(cut -d'|' -f1-2 <<<"$row")"
done <<<"$SHARED_OK"
[ -z "$UNDRAINED" ] && pass "async drains: every item on a shared workqueue is cancelled from free_sb_info" ||
    fail "async drains: shared-workqueue items without a named drain:$UNDRAINED -- list each in SHARED_OK with its cancel, or use a per-mount queue"

# (b) Private workqueues: whatever is queued on one must be destroyed
# (destroy_workqueue drains), and the per-mount cold queue must also be
# closed and flushed in kill_sb BEFORE kill_block_super(), which is where
# the VFS evicts inodes the queued work may pin.
NODESTROY=""
for f in "$K"/*.c; do
    while IFS= read -r wq; do
        [ -n "$wq" ] || continue
        grep -qF "destroy_workqueue($wq)" "$K"/*.c || NODESTROY="$NODESTROY $(basename "$f"):$wq"
    done < <(grep -v '^\s*\*' "$f" | grep -oE 'queue_(delayed_)?work\([a-z_>.-]+,' | grep -v 'system_' |
        sed -E 's/queue_(delayed_)?work\(//; s/,$//' | sort -u)
done
[ -z "$NODESTROY" ] && pass "async drains: every private workqueue that is queued on is destroyed" ||
    fail "async drains: queued on but never destroyed:$NODESTROY"
if awk '/cetrafs_sb_cold_close\(sb\)/ { c = NR } /kill_block_super\(sb\)/ { k = NR } END { exit !(c && k && c < k) }' <<<"$KILL_SB"; then
    pass "async drains: kill_sb closes the cold queue before kill_block_super()"
else
    fail "async drains: cetrafs_kill_sb() does not close the cold queue before kill_block_super() -- a queued reconcile can pin an inode past evict_inodes()"
fi

# (c) References handed to async context, and threads/timers/RCU. Each
# site is listed by its enclosing function with what releases it; a new
# igrab()/ihold() or a first timer/call_rcu/kthread fails here until it
# says what drains it.
#   file | enclosing function | construct
ASYNC_OK='
lock.c|cetrafs_inode_mark_tree_cold|igrab
lock.c|cetrafs_inode_note_stamp|igrab
dir.c|cetrafs_link_locked|ihold
caw.c|cetrafs_cas_stress|kthread_run
'
UNLISTED=""
SEEN=""
for f in "$K"/*.c; do
    fn="$(basename "$f")"
    while IFS='|' read -r func what; do
        [ -n "$what" ] || continue
        SEEN="$SEEN
$fn|$func|$what"
        grep -qxF "$fn|$func|$what" <<<"$ASYNC_OK" || UNLISTED="$UNLISTED $fn:$func:$what"
    done < <(awk '
        /^[a-z].*\(/ && !/;$/ { match($0, /[a-z_0-9]+\(/); fname = substr($0, RSTART, RLENGTH - 1) }
        # POSIX classes, not a backslash-s: mawk, the default awk on Debian,
        # has none, so comment lines were not skipped and a comment naming
        # igrab() was reported as a call site on every box without gawk.
        /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
        match($0, /(igrab|ihold|kthread_run|kthread_create|call_rcu|timer_setup|mod_timer|add_timer)\(/) {
            print fname "|" substr($0, RSTART, RLENGTH - 1)
        }' "$f")
done
# An extraction that finds nothing would pass: every listed site must
# have been seen, so the list cannot go stale and the awk cannot go blind
# (it did once: 'func' is a gawk keyword).
while IFS= read -r row; do
    [ -n "$row" ] || continue
    grep -qxF "$row" <<<"$SEEN" || UNLISTED="$UNLISTED stale-entry:$row"
done <<<"$ASYNC_OK"
[ -z "$UNLISTED" ] && pass "async refs: every igrab/ihold/thread/timer/RCU site is listed with its release" ||
    fail "async refs: unlisted async constructs:$UNLISTED -- add each to ASYNC_OK only after naming what drains it (BUG-CLASSES.md class 18)"

# BUG-CLASSES.md class 22, waiting under a lock the awaited takes. An
# O_DIRECT write's completion takes invalidate_lock to convert what it
# wrote (cetrafs_dio_end_io()); inode_dio_wait() waits for that
# completion. Called with invalidate_lock held, the two sleep on each
# other uninterruptibly. Punch, the defrag step and the lock suspend all
# did exactly that until 2026-11-03, and truncate, one call down, until
# 2026-11-04.
log "checking nothing waits for direct I/O while holding invalidate_lock (class 22)"
# dio_waiters <file>...: an ERE of inode_dio_wait and every function that
# reaches it, transitively. Truncate waited in cetrafs_truncate_shrink(),
# whose CALLER held the lock, and a per-function scan saw a wait with no
# lock and a lock with no wait (2026-11-04). Coarse on purpose: a
# function counts from its column-0 signature to its closing brace, and
# an over-match can only add waiters, never hide one.
dio_waiters() {
    local pat='inode_dio_wait' prev='' names
    while [ "$pat" != "$prev" ]; do
        prev="$pat"
        names="$(awk -v pat="$pat" '
            /^[a-z]/ && /\(/ && !/;[[:space:]]*$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.*[ *]/, "", fn); next }
            /^}/ { fn = "" }
            /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
            fn != "" && $0 ~ ("(^|[^a-z_0-9])(" pat ")\\(") { print fn }
        ' "$@" | sort -u | tr '\n' '|')"
        pat="inode_dio_wait${names:+|${names%|}}"
    done
    echo "$pat"
}
# dio_wait_under_lock <file>...: file:line of every call to a waiter made
# with invalidate_lock (or a wrapper that takes it) held, per function.
dio_wait_under_lock() {
    local pat
    pat="$(dio_waiters "$@")"
    awk -v pat="$pat" '
        FNR == 1 { held = 0 }
        /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
        /^}/ { held = 0 }
        /^[a-z]/ { next }
        /filemap_invalidate_unlock(_shared)?\(|cetrafs_defrag_inode_unlock\(/ { held = 0 }
        held && $0 ~ ("(^|[^a-z_0-9])(" pat ")\\(") { print FILENAME ":" FNR }
        /filemap_invalidate_lock(_shared)?\(|cetrafs_defrag_inode_lock(_drained)?\(inode\)/ { held = 1 }
    ' "$@"
}
# Not blind: known-bad bodies must be caught -- a wait under the lock,
# and a wait one call down from a caller that holds it -- and the fixed
# orders passed.
SAMPLE="$(ct_tmp dio-wait-sample)"
printf '%s\n' 'static void bad(struct inode *inode)' '{' '    filemap_invalidate_lock(inode->i_mapping);' \
    '    inode_dio_wait(inode);' '}' 'static void good(struct inode *inode)' '{' '    inode_dio_wait(inode);' \
    '    filemap_invalidate_lock(inode->i_mapping);' '}' 'static int shrink(struct inode *inode)' '{' \
    '    inode_dio_wait(inode);' '    return 0;' '}' 'static int bad_caller(struct inode *inode)' '{' \
    '    filemap_invalidate_lock(inode->i_mapping);' '    return shrink(inode);' '}' \
    'static int good_caller(struct inode *inode)' '{' '    int r = shrink(inode);' \
    '    filemap_invalidate_lock(inode->i_mapping);' '    return r;' '}' >"$SAMPLE"
[ "$(dio_wait_under_lock "$SAMPLE" | tr '\n' ' ')" = "$SAMPLE:4 $SAMPLE:19 " ] ||
    fail "dio wait under lock: the check does not flag the known-bad samples (got '$(dio_wait_under_lock "$SAMPLE" | tr '\n' ' ')')"
HITS="$(dio_wait_under_lock "$K"/*.c | sed "s|$K/||")"
NWAITS="$(grep -c 'inode_dio_wait(' "$K"/*.c | awk -F: '{ n += $2 } END { print n }')"
[ "$NWAITS" -ge 4 ] || fail "dio wait under lock: found only $NWAITS inode_dio_wait() calls -- the scan is not seeing the tree"
[ -z "$HITS" ] && pass "dio wait under lock: none of $NWAITS inode_dio_wait() calls, nor any function reaching one, runs under invalidate_lock" ||
    fail "dio wait under lock: a wait for direct I/O with invalidate_lock held at: $(echo $HITS) -- drain BEFORE taking it (cetrafs_dio_end_io() needs it)"

# BUG-CLASSES.md class 13, loop rescheduling. A loop inside an
# alloc_mutex section walks bits: a Block Group's (up to 2^32) or an
# extent's (up to 2^31), one bitmap test each, holding a mutex every
# allocator on the node waits for. None rescheduled until 2026-11-04.
log "checking every loop under alloc_mutex reschedules (class 13)"
# alloc_loops_without_resched <file>...: file:line of each for/while
# loop opened inside a cetrafs_sb_alloc_lock() section whose body has
# no cond_resched(). Braces are counted per line; a loop body is from
# its header to the line its depth closes.
alloc_loops_without_resched() {
    awk '
        FNR == 1 { held = 0; depth = 0; nl = 0 }
        /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
        /cetrafs_sb_alloc_unlock\(/ { held = 0 }
        held && /^[[:space:]]*(for|while) \(/ && !/;[[:space:]]*$/ { nl++; ld[nl] = depth; ll[nl] = FNR; lr[nl] = 0 }
        /cond_resched\(/ { for (i = 1; i <= nl; i++) lr[i] = 1 }
        {
            o = gsub(/\{/, "{"); c = gsub(/\}/, "}"); depth += o - c
            while (nl > 0 && depth <= ld[nl] && FNR > ll[nl]) {
                if (!lr[nl]) print FILENAME ":" ll[nl]
                nl--
            }
        }
        /cetrafs_sb_alloc_lock\(/ { held = 1 }
    ' "$@"
}
# Not blind: a loop with no reschedule under the lock is caught, one with
# it, or outside the lock, is not.
SAMPLE="$(ct_tmp alloc-loop-sample)"
printf '%s\n' 'static void f(struct super_block *sb, u64 count)' '{' '    u64 b;' '' \
    '    cetrafs_sb_alloc_lock(sb);' '    for (b = 0; b < count; b++) {' '        test(b);' '    }' \
    '    for (b = 0; b < count; b++) {' '        if (!(b & 4095))' '            cond_resched();' '        test(b);' '    }' \
    '    cetrafs_sb_alloc_unlock(sb);' '    for (b = 0; b < count; b++) {' '        test(b);' '    }' '}' >"$SAMPLE"
[ "$(alloc_loops_without_resched "$SAMPLE" | tr '\n' ' ')" = "$SAMPLE:6 " ] ||
    fail "alloc loops: the check does not flag the known-bad sample (got '$(alloc_loops_without_resched "$SAMPLE" | tr '\n' ' ')')"
NLOCK="$(grep -c 'cetrafs_sb_alloc_lock(sb);' "$K/alloc.c")"
[ "$NLOCK" -ge 5 ] || fail "alloc loops: found only $NLOCK alloc_mutex sections in alloc.c -- the scan is not seeing the tree"
HITS="$(alloc_loops_without_resched "$K"/*.c | sed "s|$K/||")"
[ -z "$HITS" ] && pass "alloc loops: every loop in the $NLOCK alloc_mutex sections reschedules" ||
    fail "alloc loops: a loop under alloc_mutex never reschedules, at: $(echo $HITS) -- add a periodic cond_resched() (class 13)"

log "checking every whole-bitmap walk in alloc.c reschedules (class 13)"
# The inline check above sees only loops written between alloc_lock and
# alloc_unlock; the bitmap scans are static HELPERS called from inside
# those sections, and were invisible to it (audit R18). Any function in
# alloc.c that walks a bitmap block by block must reschedule in that loop.
bitmap_walks_without_resched() {
    awk '
        /^[a-z].*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.*[ *]/, "", fn) }
        /for \(blk = 0; blk < [a-z_.()> -]+; blk\+\+\)/ { inloop = 1; depth = 0; seen = 0; start = FNR }
        inloop {
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m
            if ($0 ~ /cond_resched\(\)/) seen = 1
            if (depth <= 0 && FNR > start) { if (!seen) print FILENAME ":" start ":" fn; inloop = 0 }
        }' "$@"
}
SAMPLE="$(ct_tmp bitmap-walk-sample)"
printf '%s\n' 'static long scan(void)' '{' '    for (blk = 0; blk < nblocks; blk++) {' '        test(blk);' '    }' '}' >"$SAMPLE"
[ -n "$(bitmap_walks_without_resched "$SAMPLE")" ] ||
    fail "bitmap walks: the check does not flag the known-bad sample"
NWALK="$(grep -cE 'for \(blk = 0; blk < ' "$K/alloc.c")"
[ "$NWALK" -ge 4 ] || fail "bitmap walks: found only $NWALK block walks in alloc.c -- the scan is not seeing the tree"
HITS="$(bitmap_walks_without_resched "$K/alloc.c" | sed "s|$K/||")"
[ -z "$HITS" ] && pass "bitmap walks: all $NWALK block-by-block walks in alloc.c reschedule" ||
    fail "bitmap walks: no cond_resched() in the walk at: $(echo $HITS) (class 13, audit R18)"

log "checking no give-back of a claim discards its result (class 31)"
# A claim given back with its result cast away is a claim kept for good
# when the give-back fails: the holder keeps beating, so nothing else
# ever clears it. Three of the four 2026-11-04 instances had exactly
# this shape, and the suspend-mark clears (R20) were the fourth.
discarded_giveback() {
    grep -nE '\(void\) *cetrafs_(lock_clear_on_disk|inode_reclaim_claim|lock_cas|nslock_release[a-z_]*|lock_suspend_mark)\(' "$@" || true
}
SAMPLE="$(ct_tmp giveback-sample)"
printf '%s\n' '    (void) cetrafs_lock_clear_on_disk(inode, false);' '    ret = cetrafs_lock_clear_on_disk(inode, false);' >"$SAMPLE"
[ "$(discarded_giveback "$SAMPLE" | cut -d: -f1)" = 1 ] ||
    fail "give-backs: the check does not flag the known-bad sample"
HITS="$(discarded_giveback "$K"/*.c | sed "s|$K/||")"
[ -z "$HITS" ] && pass "give-backs: none discards its result" ||
    fail "give-backs: a claim's give-back result is discarded at: $(echo $HITS) -- queue it for the heartbeat (class 31)"

# BUG-CLASSES.md class 19, execution context. ->free_inode runs from an
# RCU callback, in softirq: nothing in it may sleep. It held a
# cancel_work_sync() until 2026-11-03.
log "checking nothing that can sleep runs in ->free_inode (class 19)"
FREE_FN="$(grep -oP '\.free_inode\s*=\s*\K[a-z_0-9]+' "$K/super_ops.c")"
FREE_BODY=""
for f in "$K"/*.c; do
    b="$(body "$f" "$FREE_FN")"
    [ -n "$b" ] && FREE_BODY="$b"
done
if [ -z "$FREE_FN" ] || [ -z "$FREE_BODY" ]; then
    fail "free_inode context: cannot find the ->free_inode function ('$FREE_FN') -- nothing was checked"
else
    SLEEPERS="$(tail -n +2 <<<"$FREE_BODY" | grep -v '^\s*\*\|^\s*/\*' |
        grep -oE '\b(cancel_[a-z_]*_sync|flush_[a-z_]+|mutex_lock[a-z_]*|down_[a-z_]+|down|msleep|usleep_range|ssleep|schedule[a-z_]*|wait_[a-z_]+|lock_buffer|[a-z_]*bread[a-z_]*|iput|synchronize_[a-z_]+|kv?[mz]alloc|kcalloc|vmalloc|cetrafs_[a-z_]+)\(' |
        grep -vE '^(CETRAFS_I|cetrafs_inode_cache)\(' | sort -u | tr '\n' ' ' || true)"
    [ -z "$SLEEPERS" ] && pass "free_inode context: $FREE_FN calls nothing that can sleep" ||
        fail "free_inode context: $FREE_FN (RCU callback, softirq) calls: $SLEEPERS-- a sleep there is a BUG on a debug kernel and a stall without one"
fi

# Every liveness window must be at least the stale window a peer waits
# before calling a node dead: that window exists for multipath queueing,
# and any watch shorter than it reads a node whose paths stall in between
# as gone. Two did not -- the kernel's repair-claim judgement (15 s, audit
# R4) and the twin watch at re-attach (35 s, L1) -- against a 120 s base.
# A liveness window is a variable named window; each assignment must name
# the stale window (cetrafs_sb_stale_secs / CETRAFS_NODE_STALE_SECS), or
# be a raise-only branch (its condition compares "> window"). Negative
# control: replace node.c's twin-watch floor with "2 * pi + 5" -- fails.
log "checking every liveness window derives from the stale window"
WIN="$(for f in "$K/node.c" "$K/fs.c" "$ROOT/userspace/devutil.h"; do
    awk -v F="$(basename "$f")" '
        /^[[:space:]]*(\*|\/\*|\/\/)/ { next }
        /(^|[^_[:alnum:]])window[[:space:]]*=[^=]/ {
            if ($0 !~ /stale|STALE/ && prev !~ /> *window/) print F ":" NR
        }
        NF { prev = $0 }' "$f"
done)"
[ -z "$WIN" ] && pass "liveness windows: every one is floored at the stale window" ||
    fail "liveness windows: shorter than the stale window, or not derived from it, at: $(echo $WIN)"

# The dm path resolution allocates and does I/O. Reached from a CAS,
# which evict needs, it must run inside a NOFS scope: a GFP_KERNEL
# allocation entering reclaim evicts an inode of this volume, needs a
# CAS, and waits on the very resolving flag its caller set (audit L23).
# Every call of cetrafs_dmpath_resolve() must have memalloc_nofs_save()
# within the three lines above it. Negative control: drop the scope in
# cetrafs_dmpath_sdev() -- fails.
log "checking the dm path resolution runs in a NOFS scope"
NOFS="$(awk '
    /^[[:space:]]*(\*|\/\*|\/\/)/ { next }
    /cetrafs_dmpath_resolve\(/ && !/^static/ {
        ok = 0
        for (i = 1; i <= 3; i++) if (h[(NR - i) % 4] ~ /memalloc_nofs_save/) ok = 1
        if (!ok) print "dmpath.c:" NR
    }
    { h[NR % 4] = $0 }' "$K/dmpath.c")"
CALLS="$(grep -c 'cetrafs_dmpath_resolve(bdev' "$K/dmpath.c" || true)"
[ "$CALLS" -ge 1 ] || fail "dm path NOFS: found no call of cetrafs_dmpath_resolve() -- the check sees nothing"
[ -z "$NOFS" ] && pass "dm path NOFS: every resolution runs inside memalloc_nofs_save()" ||
    fail "dm path NOFS: a resolution outside a NOFS scope at: $(echo $NOFS)"

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
