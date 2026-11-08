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

# N5 (audit 2026-11-05): hb_interval_secs and stale_secs were plain
# module params whose descriptions said "UNBOUNDED test knob" -- words
# the check above keys on neither -- and reached every mount unclamped: a
# stale window of 0 is a split-brain lever, untraced and untainted. The
# rule: a parameter is either a TEST ONLY knob (traced above) or listed
# here with what it tunes and why no safety decision reads it. A new
# plain parameter fails until someone has answered that.
log "checking every plain module parameter is a listed tuning knob (N5)"
PLAIN_OK='caw_probe:load-time only (0444): forces a CAW backend choice, refused if the device lacks it
cas_selftest:runs the mount-time CAS self-test; off only skips a check that refuses nothing it would not
dio_fill_holes:selects the O_DIRECT hole-fill path; both paths are the supported ones
alloc_run_blocks:allocation run length (performance); next_run_len bounds it
alloc_run_max_blocks:allocation run cap (performance)
auto_defrag:background defrag on/off (performance)
auto_defrag_min_pct:defrag trigger threshold (performance)
auto_defrag_quiet_secs:defrag quiet period (performance)
auto_defrag_min_extents:defrag trigger threshold (performance)
bg_sweep_min_secs:rate limit of a statistics sweep (performance)
ext_cache:extent-tree cache on/off; off reads the device every time
scrub:background leak scrub on/off; off leaks until fsck, never frees
scrub_interval_secs:scrub period (0 means the default)
scrub_gap_secs:scrub pacing (0 means the default)
node_uuid:load-time only (0444): this node identity
pf_full_backoff_ms:pending-free queue backoff (latency)
pf_drain_min_ms:pending-free drain rate limit (latency)'
plain_params() { grep -hoE '^module_param(_named)?\([a-z_0-9]+' "$@" | sed -E 's/^module_param(_named)?\(//' | sort -u; }
UNLISTED="$(plain_params "$K"/*.c | while read -r n; do grep -q "^$n:" <<<"$PLAIN_OK" || echo "$n"; done)"
NPLAIN="$(plain_params "$K"/*.c | wc -l)"
[ "$NPLAIN" -ge 10 ] || fail "plain params: found only $NPLAIN -- the scan is not seeing the tree"
[ -z "$UNLISTED" ] && pass "plain params: all $NPLAIN plain module parameters are listed tuning knobs" ||
    fail "plain params: not TEST ONLY and not listed (bound it or trace it): $(echo $UNLISTED)"
SAMPLE="$(ct_tmp plainparam-sample).c"
printf '%s\n' 'module_param_named(stale_secs, cetrafs_stale_secs, uint, 0644);' >"$SAMPLE"
[ "$(plain_params "$SAMPLE")" = stale_secs ] && ! grep -q "^stale_secs:" <<<"$PLAIN_OK" &&
    pass "plain params: control -- the old plain stale_secs would be flagged" ||
    fail "plain params: control -- the old plain stale_secs would not be flagged"

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
FREE_FN="$(sed -n 's/.*\.free_inode[[:space:]]*=[[:space:]]*\([a-z_0-9][a-z_0-9]*\).*/\1/p' "$K/super_ops.c")"
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

# A give-back after a reclaim undoes what the reclaim TOOK. Every CAS
# that takes -- the lock claim, steal_release, the reader-bit CLEAR, the
# namespace-lock steal, the journal replay claim -- has a "nothing to
# do" outcome the CAS wrapper folds into success, and giving that back
# hands a live node a lock or a presence bit no open of its holds
# (classes 28/21: the lock give-back, then the reader bit, then the two
# steal_release sites, each found one at a time). So every give-back --
# a call of cetrafs_lock_undo_steal(), or a re-attach test on the
# success of a CAS (`ret == 0 && ... reattached_since_fence`) -- must
# test `displaced` on its line or the line before. Negative control:
# drop `rctx.displaced &&` from the reader-bit give-back -- fails.
log "checking every reclaim give-back is gated on a recorded displacement"
GB="$(for f in "$K"/*.c; do
    awk -v F="$(basename "$f")" '
        /^[[:space:]]*(\*|\/\*|\/\/)/ { prev = $0; next }
        /^static bool cetrafs_lock_undo_steal/ { prev = $0; next }
        /cetrafs_lock_undo_steal\(/ || (/ret == 0/ && /reattached_since_fence\(/) {
            if ($0 !~ /displaced/ && prev !~ /displaced/) print F ":" NR
        }
        { prev = $0 }' "$f"
done)"
NGB="$(cat "$K"/*.c | grep -c 'cetrafs_lock_undo_steal(\|reattached_since_fence(' || true)"
[ "$NGB" -ge 5 ] || fail "give-back gate: found only $NGB give-back sites -- the check sees nothing"
[ -z "$GB" ] && pass "give-back gate: every reclaim give-back tests displaced" ||
    fail "give-back gate: a give-back not gated on displaced at: $(echo $GB)"

# The image suites need no kernel, so nothing in them may need GNU
# grep's -P: on a host without it the suite stopped at the first one
# (audit, section 4). POSIX sed/awk instead.
log "checking the image suites and the harness avoid GNU-only grep (-P)"
GP="$(grep -n 'grep -[a-zA-Z]*P' "$ROOT"/tests/image/*.sh "$ROOT"/tests/lib/*.sh |
    grep -vE '^[^:]*:[0-9]+:[[:space:]]*#|GP=|GNU-only grep|portability' | sed "s|$ROOT/||" || true)"
[ -z "$GP" ] && pass "portability: no grep -P in tests/image or tests/lib" ||
    fail "portability: grep -P (GNU only) at: $(echo "$GP" | cut -d: -f1,2 | tr '\n' ' ')"

# callgraph <file>...: "caller callee" for every call, inside a column-0
# function body, of a name that is itself defined at column 0 in the
# files. Coarse, as dio_waiters: a body runs from its signature to the
# column-0 closing brace.
callgraph() {
    awk '
        FNR == 1 { fn = "" }
        /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
        /^[a-z]/ && /\(/ && !/;[[:space:]]*$/ { f = $0; sub(/\(.*/, "", f); sub(/.*[ *]/, "", f); fn = f; def[f] = 1; next }
        /^}/ { fn = ""; next }
        fn != "" {
            line = $0
            while (match(line, /[a-z_][a-z_0-9]*\(/)) {
                c = substr(line, RSTART, RLENGTH - 1)
                n++; caller[n] = fn; callee[n] = c
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END { for (i = 1; i <= n; i++) if (callee[i] in def) print caller[i], callee[i] }
    ' "$@" | sort -u
}
# forward <edges-file> <root>: every function reachable from root.
forward() {
    local seen="$2" frontier="$2" next
    while [ -n "$frontier" ]; do
        next="$(for f in $frontier; do awk -v f="$f" '$1 == f { print $2 }' "$1"; done | sort -u)"
        frontier=""
        for f in $next; do
            case " $seen " in *" $f "*) ;; *) seen="$seen $f"; frontier="$frontier $f" ;; esac
        done
    done
    echo "$seen"
}

CG="$(ct_tmp callgraph)"
callgraph "$K"/*.c >"$CG"
[ "$(wc -l <"$CG")" -ge 1000 ] || fail "call graph: only $(wc -l <"$CG") edges -- the extraction went blind"
# takes <fn> <ERE>: does fn's own body match ERE (comments skipped)?
body_matches() {
    awk -v f="$1" -v re="$2" '
        /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
        /^[a-z]/ && /\(/ && !/;[[:space:]]*$/ { g = $0; sub(/\(.*/, "", g); sub(/.*[ *]/, "", g); in_ = (g == f); next }
        /^}/ { in_ = 0 }
        in_ && $0 ~ re { print FILENAME ":" FNR; exit }' "${@:3}"
}

# Class 22, the second half: the O_DIRECT completion
# (cetrafs_dio_end_io()) runs while the submitter -- or truncate, punch,
# defrag, suspend, which all drain direct I/O -- may hold i_rwsem, and
# lock_mutex or ns_mutex above it. Nothing it reaches may take one of
# them, or the drain and the completion wait on each other. Checked
# over the transitive callee set (coarse: may-call, so it can only
# over-report). Negative control: the sample below, an end_io whose
# helper takes inode_lock, must be flagged.
log "checking nothing the DIO completion reaches takes i_rwsem, lock_mutex or ns_mutex (class 22)"
# [(], not a backslash: awk -v processes escapes, and mawk turns \( into
# an unbalanced ( -- a regex that matches nothing, silently.
C22RE='(inode_lock(_shared)?[(]|lock_mutex|ns_mutex)'
c22_scan() { # <edges> <root> <files>...
    local e="$1" r="$2" f hits=""
    shift 2
    for f in $(forward "$e" "$r"); do
        h="$(body_matches "$f" "$C22RE" "$@")"
        [ -n "$h" ] && hits="$hits $f@$h"
    done
    echo "$hits"
}
S22="$(ct_tmp c22-sample).c"; ct_track file "$S22"
printf '%s\n' 'static int helper(struct inode *inode)' '{' '    inode_lock(inode);' '    return 0;' '}' \
    'static int sample_end_io(struct kiocb *iocb)' '{' '    return helper(NULL);' '}' >"$S22"
E22="$(ct_tmp c22-edges)"
callgraph "$S22" >"$E22"
[ -n "$(c22_scan "$E22" sample_end_io "$S22")" ] ||
    fail "class 22 completion: the known-bad sample (end_io -> helper -> inode_lock) is not flagged -- the check is blind"
N22="$(forward "$CG" cetrafs_dio_end_io | wc -w)"
[ "$N22" -ge 10 ] || fail "class 22 completion: cetrafs_dio_end_io reaches only $N22 functions -- the graph lost it"
H22="$(c22_scan "$CG" cetrafs_dio_end_io "$K"/*.c | sed "s|$K/||g")"
[ -z "$H22" ] && pass "class 22 completion: none of the $N22 functions the DIO completion may reach takes i_rwsem, lock_mutex or ns_mutex" ||
    fail "class 22 completion: reached from cetrafs_dio_end_io and takes a lock its drainers hold:$H22"

# Class 5 (audit N3): every durability boundary a user or a peer relies
# on -- sync_fs, put_super, ->flush at close, fsync (files and
# directories), the last writer's release -- must reach a device cache
# flush. MAY-reach over the call graph, so it catches a boundary that
# lost every path to a flush, not one that skips it on some branch; the
# flush counters (sync_flushes_cache, publish_flushes_cache) are the
# instrument for that. Negative control: the sample boundary below,
# which flushes nothing, must be flagged.
log "checking every durability boundary reaches a device cache flush (class 5)"
FLRE='(blkdev_issue_flush|sync_blockdev)[(]'
c5_flushers() { # <files>...
    awk -v re="$FLRE" '
        /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
        /^[a-z]/ && /\(/ && !/;[[:space:]]*$/ { g = $0; sub(/\(.*/, "", g); sub(/.*[ *]/, "", g); next }
        /^}/ { g = "" }
        g != "" && $0 ~ re { print g }' "$@" | sort -u
}
c5_reaches() { # <edges> <boundary> <flushers...>: prints the flusher reached, if any
    local e="$1" b="$2" r f
    shift 2
    r=" $(forward "$e" "$b") "
    for f in "$@"; do case "$r" in *" $f "*) echo "$f"; return ;; esac; done
}
S5="$(ct_tmp c5-sample).c"; ct_track file "$S5"
printf '%s\n' 'static int flushes(void)' '{' '    return blkdev_issue_flush(NULL);' '}' \
    'static int sample_sync(void)' '{' '    return 0;' '}' >"$S5"
E5="$(ct_tmp c5-edges)"
callgraph "$S5" >"$E5"
[ -z "$(c5_reaches "$E5" sample_sync $(c5_flushers "$S5"))" ] && [ -n "$(c5_flushers "$S5")" ] ||
    fail "class 5: the sample boundary that flushes nothing is not flagged -- the check is blind"
FLUSHERS="$(c5_flushers "$K"/*.c)"
MISS5=""
for b in cetrafs_sync_fs cetrafs_put_super cetrafs_file_flush __cetrafs_fsync cetrafs_dir_fsync cetrafs_lock_release; do
    grep -q "^$b " "$CG" || body_matches "$b" . "$K"/*.c | grep -q . || { MISS5="$MISS5 $b(gone?)"; continue; }
    [ -n "$(c5_reaches "$CG" "$b" $FLUSHERS)" ] || MISS5="$MISS5 $b"
done
[ -z "$MISS5" ] && pass "class 5: every durability boundary reaches a device cache flush" ||
    fail "class 5: no path to a device flush from:$MISS5"

# Class 32: a slot claimed by an identity needs a path back to free.
# Each free/none sentinel the format defines must be WRITTEN somewhere
# outside the tests -- an assignment, or a memset whose comment names it
# (the registry row's FREE is all-zero) -- or the state is only ever
# tested for, and a slot that leaves it never returns (audit R10: no
# path retired a departed registry row). And a tool that BORROWS a row
# must keep the original on the device: the saved-row offset must be
# both written by the tools and read back by the kernel's reap.
# Negative control: drop the memset comment in devutil.h -- fails.
log "checking every free/none sentinel has a writer, and a borrowed row is saved on the device"
SENT="$(sed -n 's/^#define \(CETRAFS_[A-Z_]*\(STATE_FREE\|OWNER_FREE\|ID_NONE\|LOCK_NONE\)\)[[:space:]].*/\1/p' "$ROOT/include/cetrafs.h")"
[ "$(echo $SENT | wc -w)" -ge 4 ] || fail "class 32: found only '$SENT' -- the sentinel list went blind"
MISS=""
for c in $SENT; do
    cat "$K"/*.c "$ROOT"/userspace/*.c "$ROOT"/userspace/*.h |
        grep -E "(=[^=]*\b$c\b|memset.*\b$c\b)" | grep -vqE "(==|!=)[^=]*\b$c\b" && continue
    cat "$K"/*.c "$ROOT"/userspace/*.c "$ROOT"/userspace/*.h | grep -E "memset.*\b$c\b" -q || MISS="$MISS $c"
done
[ -z "$MISS" ] && pass "class 32: every free/none sentinel is written somewhere ($(echo $SENT))" ||
    fail "class 32: tested but never written:$MISS"
grep -q 'memcpy(blk + CETRAFS_REPAIR_SAVED_OFF' "$ROOT/userspace/devutil.h" &&
    grep -q 'CETRAFS_REPAIR_SAVED_OFF' "$K/node.c" &&
    pass "class 32: a borrowed registry row is saved in the claim block and read back by the reap" ||
    fail "class 32: the borrowed row's on-device copy is not both written (devutil.h) and read (node.c)"

# Class 35: a mount option ACCEPTED and then not in force. A second
# mount of a mounted device got the first superblock and dropped its own
# nofilelock/errors=/corruption= without a word (audit L29). Every
# option in the spec must, in its parse case, set a value AND a _set
# flag; the value must be applied to the superblock (fill_super), and
# the flag compared on a second mount (cetrafs_opts_unmet()). A new
# option that skips either is accepted and silently not in force.
# Negative control: drop the corruption line from cetrafs_opts_unmet()
# -- fails.
log "checking every mount option is applied, and refused on a second mount that differs (class 35)"
FS="$K/fs.c"
OPTS="$(sed -n 's/.*fsparam_[a-z_0-9]*("\([a-z_]*\)", \(Opt_[a-z_]*\).*/\2/p' "$FS")"
[ "$(echo $OPTS | wc -w)" -ge 3 ] || fail "class 35: found options '$OPTS' -- the spec scan went blind"
UNMET="$(awk '/^static bool cetrafs_opts_unmet\(/ { f = 1 } f { print } f && /^}/ { exit }' "$FS")"
[ -n "$UNMET" ] || fail "class 35: cetrafs_opts_unmet() is gone -- nothing compares a second mount's options"
BAD35=""
for o in $OPTS; do
    CASE="$(awk -v o="case $o:" '$0 ~ o { f = 1; next } f && /break;|case Opt_/ { exit } f { print }' "$FS")"
    SETF="$(sed -n 's/.*fci->\([a-z_]*\)_set = true.*/\1/p' <<<"$CASE")"
    VALF="$(sed -n 's/.*fci->\([a-z_]*\) = .*/\1/p' <<<"$CASE" | grep -v '_set$' | head -1)"
    [ -n "$SETF" ] && [ -n "$VALF" ] || { BAD35="$BAD35 $o(no value or _set in its case)"; continue; }
    grep -q "fci->${SETF}_set" <<<"$UNMET" || BAD35="$BAD35 $o(not compared on a second mount)"
    grep -E "sbi->[a-z_]+ = .*fci->$VALF\b" "$FS" | grep -q . || BAD35="$BAD35 $o(never applied to the superblock)"
done
[ -z "$BAD35" ] && pass "class 35: every mount option ($(echo $OPTS)) is applied and checked on a second mount" ||
    fail "class 35: accepted and not in force:$BAD35"

# Class 34: a CAS mutator that REFUSES a negative count is safe only if
# no other actor's inverse move can sit between two of ours -- a credit
# landing after the debit it pays for reads, in between, as below zero,
# and the refusal drops a legal move with no later repair (audit R25:
# the BG release credited the pool after the group read FREE). Each such
# refusal must say, in a "class 34:" comment just above it, why no
# interleaving passes through zero. Negative control: delete the
# annotation above cetrafs_zg_pool_mutate()'s guard -- fails.
log "checking every negative-count refusal in a CAS mutator names its ordering"
C34="$(for f in "$K"/*.c; do
    awk -v F="$(basename "$f")" '
        /^static int [a-z_]*_mutate\(/ { inf = 1; last34 = -100 }
        inf && /^}/ { inf = 0 }
        inf && /class 34:/ { last34 = NR }
        inf && /[a-z_]+ < 0\)/ && !/ret < 0|err < 0/ { cand = NR }
        inf && cand && NR - cand <= 12 && /return -E/ {
            if (cand - last34 > 14) print F ":" cand
            cand = 0
        }' "$f"
done)"
N34="$(cat "$K"/*.c | grep -c 'class 34:' || true)"
[ "$N34" -ge 3 ] || fail "class 34: found $N34 annotations -- the check sees nothing"
[ -z "$C34" ] && pass "class 34: every negative-count refusal in a mutator names why no inverse move interleaves" ||
    fail "class 34: a negative-count refusal with no ordering argument at: $(echo $C34)"

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

# N3 (audit 2026-11-05): defrag freed with kfree() the array
# cetrafs_tree_flatten() grows with kvrealloc(). Past one page that can be
# vmalloc memory, and kfree() of a vmalloc address is an oops or slab
# corruption -- under memory fragmentation only, so no runtime test sees
# it on demand. The question is mechanical: of every pointer filled by a
# kv*/vmalloc allocator, directly or through an out-parameter of a
# function that hands such memory out, is any freed with kfree()?
# KV_OUT names those functions; the check below refuses a new one that
# returns kv memory through an out-parameter without being listed.
log "checking nothing kv/vmalloc-allocated is freed with kfree() (N3)"
KV_OUT='cetrafs_tree_flatten'
kv_kfree() { # <files>... -- prints file:line of a kfree() of kv memory
    awk -v kvout="$KV_OUT" '
        BEGIN { n = split(kvout, f, "|"); for (i = 1; i <= n; i++) out[f[i]] = 1 }
        FNR == 1 { delete kv }
        /^[[:space:]]*(\*|\/\*|\/\/)/ { next }
        /^[a-z].*\(/ && !/;[[:space:]]*$/ { delete kv }
        {
            line = $0
            while (match(line, /[A-Za-z_][A-Za-z0-9_>.-]*[[:space:]]*=[[:space:]]*(kvmalloc|kvzalloc|kvcalloc|kvmalloc_array|kvrealloc|vmalloc|vzalloc|vcalloc|vmalloc_array)\(/)) {
                v = substr(line, RSTART, RLENGTH); sub(/[[:space:]]*=.*/, "", v); kv[v] = 1
                line = substr(line, RSTART + RLENGTH)
            }
            for (fn in out) if (index($0, fn "(")) {
                line = substr($0, index($0, fn "("))
                while (match(line, /&[A-Za-z_][A-Za-z0-9_>.-]*/)) {
                    kv[substr(line, RSTART + 1, RLENGTH - 1)] = 1; line = substr(line, RSTART + RLENGTH)
                }
            }
            line = $0
            while (match(line, /[^v]kfree\([A-Za-z_][A-Za-z0-9_>.-]*\)/)) {
                v = substr(line, RSTART + 7, RLENGTH - 8)
                if (v in kv) print FILENAME ":" FNR ": kfree(" v ")"
                line = substr(line, RSTART + RLENGTH)
            }
        }' "$@"
}
KVF="$(kv_kfree "$K"/*.c)"
[ -z "$KVF" ] && pass "allocator family: no kv/vmalloc pointer is freed with kfree()" ||
    fail "allocator family: kfree() of kv/vmalloc memory at: $(echo "$KVF" | sed "s|$K/||" | tr '\n' ' ')"
# Every function that returns kv memory through an out-parameter is in
# KV_OUT, or the check above cannot see its callers.
UNLISTED="$(awk '
    /^[a-z].*\(/ && !/;[[:space:]]*$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.*[ *]/, "", fn); kvfn = 0 }
    /(kvmalloc|kvzalloc|kvcalloc|kvrealloc|vmalloc|vzalloc)\(/ { kvfn = 1 }
    kvfn && /^[[:space:]]*\*[a-z_]+[[:space:]]*=[[:space:]]*[a-z_]+;/ { print fn }' "$K"/*.c | sort -u |
    grep -vxE "$KV_OUT" || true)"
[ -z "$UNLISTED" ] && pass "allocator family: every function handing out kv memory by out-parameter is listed ($KV_OUT)" ||
    fail "allocator family: these hand out kv memory by out-parameter and are not in KV_OUT: $(echo $UNLISTED)"
# Negative control: the check must catch the shape it exists for.
NEGSRC="$(ct_tmp kvneg).c"
printf 'static int f(void)\n{\n    cetrafs_extent_t *flat = NULL;\n    int r = cetrafs_tree_flatten(inode, raw, &flat, &n);\n    kfree(flat);\n}\nstatic int g(void)\n{\n    p = kvmalloc_array(n, 8, GFP_NOFS);\n    kfree(p);\n}\n' >"$NEGSRC"
[ "$(kv_kfree "$NEGSRC" | wc -l)" = 2 ] && pass "allocator family: control -- both planted kfree()s of kv memory are caught" ||
    fail "allocator family: control -- the check caught $(kv_kfree "$NEGSRC" | wc -l) of 2 planted kfree()s"

# struct folio_batch moved out of <linux/pagevec.h> (kernel 7.1). A file
# that includes pagevec.h for it unguarded stops building there; file.c
# did, while ioutil.c had the guard (audit 2026-11-05, section 3).
log "checking every pagevec.h include falls back from folio_batch.h"
pagevec_unguarded() {
    awk '/__has_include\(<linux\/folio_batch\.h>\)/ { g = NR }
         /^#include <linux\/pagevec\.h>/ && !(g && NR - g <= 3) { print FILENAME ":" FNR }' "$@"
}
PV="$(for f in "$K"/*.c "$K"/*.h; do pagevec_unguarded "$f"; done | sed "s|$K/||")"
[ -z "$PV" ] && pass "pagevec: every include of it is the fallback of a folio_batch.h check" ||
    fail "pagevec: unguarded #include <linux/pagevec.h> at: $(echo $PV)"
SAMPLE="$(ct_tmp pagevec-sample).c"
printf '#include <linux/fs.h>\n#include <linux/pagevec.h>\n' >"$SAMPLE"
[ -n "$(pagevec_unguarded "$SAMPLE")" ] && pass "pagevec: control -- an unguarded include is caught" ||
    fail "pagevec: control -- an unguarded include is not caught"

# Flags one thread sets to stop a loop another is running are read with
# READ_ONCE and set with WRITE_ONCE: a plain bool re-read in a loop may be
# hoisted out of it, and KCSAN flags it (audit 2026-11-05, section 3,
# scrub->draining). KCSAN is not in the rig, so the rule is checked here.
log "checking cross-thread stop flags are marked accesses"
plain_flag() { grep -nE '[a-z_]+->(draining|defrag_draining)\b' "$@" | grep -vE 'READ_ONCE\(|WRITE_ONCE\(|^\S+:[0-9]+:\s*(bool|\*|/\*)' || true; }
PF="$(plain_flag "$K"/scrub.c "$K"/fs.c | sed "s|$K/||")"
[ -z "$PF" ] && pass "stop flags: every access to draining/defrag_draining is READ_ONCE/WRITE_ONCE" ||
    fail "stop flags: plain access at: $(echo "$PF" | cut -d: -f1,2 | tr '\n' ' ')"
SAMPLE="$(ct_tmp flag-sample).c"
printf '    if (s->draining)\n        return;\n' >"$SAMPLE"
[ -n "$(plain_flag "$SAMPLE")" ] && pass "stop flags: control -- a plain read is caught" ||
    fail "stop flags: control -- a plain read is not caught"

# Class 36 (fail-open guards). A check written `X(..., &out) == 0 && out`
# reads "no error and the answer is yes" -- and an ERROR falls into the
# other branch with the answer. Harmless where the true branch is the
# one that ACTS (an error then does nothing); a hole where the true
# branch is the one that REFUSES: evict asked "does another node still
# use this file?" that way, and every failure of the question freed the
# number and the blocks under a peer's open fd (audit 2026-11-05, N1).
# Every site of the shape is listed with the direction that makes it
# safe; a new one fails until someone has judged it. The split form
# (`rc = X(&out); if (!rc && out)`) is not seen -- a gap the entry records.
log "checking every 'no error && answer' guard has its direction judged"
FAILOPEN_OK='alloc.c:cetrafs_read_bg_geom:pre-filter; the claim re-checks under its own CAS
alloc.c:cetrafs_bg_data_block_stats:acts (debits the pool) only on success
defrag.c:cetrafs_read_raw_inode_overlaid:advisory re-queue only
dir.c:cetrafs_read_raw_inode:acts (zeroes nlink) only on success; an error leaks
dir.c:cetrafs_rename_ns_delta:acts (set_nlink) only on success; an error leaves the count high
dir.c:cetrafs_walk_dirents:target discovery; the locked re-check decides
heartbeat.c:cetrafs_node_self_fence_check:pre-check; the renewal compares fence_epoch itself
inode.c:cetrafs_sb_get_node_id:true branch skips a refresh; an error applies it, the default
lock.c:cetrafs_node_is_stale:acts (reclaims a reader bit) only on success; an error counts the reader
node.c:cetrafs_node_is_stale:true branch skips a peer; an error counts it as live
scrub.c:cetrafs_zg_scrub_adopt_one_stale:log only
xattr.c:cetrafs_xattr_slot_free:returns bool, not an error
zonegroup.c:cetrafs_bg_release_empty:log only
zonegroup.c:cetrafs_zg_try_claim_one:acts (counts a claim) only on success
zonegroup.c:cetrafs_bg_data_block_stats:fast-path pick; an error falls to the full scan'
failopen_sites() {
    for f in "$@"; do
        grep -nE '(cetrafs_[a-z0-9_]+\([^;]*&[^;]*\)[[:space:]]*==[[:space:]]*0[[:space:]]*&&)|(![[:space:]]*cetrafs_[a-z0-9_]+\([^;]*&[^;]*\)[[:space:]]*&&)' "$f" |
            while IFS= read -r l; do
                c="$(sed -nE 's/.*(^|[^a-z0-9_])(cetrafs_[a-z0-9_]+)\([^;]*&[^;]*\)[[:space:]]*==[[:space:]]*0[[:space:]]*&&.*/\2/p' <<<"$l")"
                [ -n "$c" ] || c="$(sed -nE 's/.*![[:space:]]*(cetrafs_[a-z0-9_]+)\(.*/\1/p' <<<"$l")"
                echo "$(basename "$f"):$c"
            done
    done | sort -u
}
FO="$(failopen_sites "$K"/*.c)"
NFO="$(grep -c . <<<"$FO" || true)"
[ "$NFO" -ge 10 ] || fail "fail-open guards: found only $NFO sites -- the scan is not seeing the tree"
UNJ="$(while read -r k; do [ -n "$k" ] && ! grep -q "^$k:" <<<"$FAILOPEN_OK" && echo "$k"; done <<<"$FO" || true)"
[ -z "$UNJ" ] && pass "fail-open guards: all $NFO 'no error && answer' sites have a judged direction" ||
    fail "fail-open guards: judge the error direction of (an error must not reach the permissive branch): $(echo $UNJ)"
SAMPLE="$(ct_tmp failopen-sample).c"
printf '    if (cetrafs_lock_foreign_user_exists(sb, ino, me, &blocked, &reader) == 0 &&\n        (blocked || reader))\n        ret = -ETXTBSY;\n' >"$SAMPLE"
[ "$(failopen_sites "$SAMPLE")" = "$(basename "$SAMPLE"):cetrafs_lock_foreign_user_exists" ] &&
    pass "fail-open guards: control -- the old evict guard is caught" ||
    fail "fail-open guards: control -- the old evict guard is not caught ($(failopen_sites "$SAMPLE"))"

# Class 37 (a wait made true without a wake). wait_event() re-tests its
# condition only when its queue is woken; a store that makes the
# condition true and wakes nobody leaves the waiter asleep for good. The
# journal held a slot past its operation that way: the waiter's "or
# every slot is held" became true and nobody said so, so the writer
# slept uninterruptibly, holding a buffer's update lock (audit
# 2026-11-05, N2). Per waited queue: the stores that can make its
# condition true, and the wake every function doing one must contain.
# The count of wait sites is pinned, so a new wait fails here until its
# queue is specified below.
log "checking every store that can satisfy a wait wakes its queue"
# file|function exempt from the rule (or -)|store regex|wake regex
WAKE_SPEC='journal.c|cetrafs_journal_write_block_flags|clear_bit\([^,]*, *j->busy\)|j->held\+\+|\+\+j->held|wake_up(_all)?\(&j->slot_wq\)
dmpath.c|-|->resolving = false|wake_up(_all)?\(&cetrafs_dmpath_wq\)
caw.c|-|atomic_dec[a-z_]*\(&ctx->running\)|wake_up(_all)?\(&ctx->done\)
fs.c|-|clear_bit\([^,]*, *sbi->zg_adopt_wanted\)|wake_up(_all)?\(&sbi->zg_adopt_wq\)'
# The first spec line's exemption is the waiter itself: it clears a held
# slot's bit and re-sets it under the same j->lock hold, so nothing
# becomes free (journal.c, "re-set below").
unwoken() { # <file> <exempt fn> <store re> <wake re>: functions storing without waking
    # Through the environment: awk -v would eat the regexes' backslashes.
    WEX="$2" WST="$3" WWK="$4" awk '
        BEGIN { ex = ENVIRON["WEX"]; st = ENVIRON["WST"]; wk = ENVIRON["WWK"] }
        /^[a-z].*\(/ && !/;[[:space:]]*$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.*[ *]/, "", fn); stored = 0; woke = 0 }
        fn != "" && $0 ~ st && $0 !~ /^[[:space:]]*(\*|\/\*)/ { stored = 1 }
        fn != "" && $0 ~ wk { woke = 1 }
        /^}/ { if (fn != "" && fn != ex && stored && !woke) print FILENAME ":" fn; fn = "" }' "$1"
}
WSITES="$(grep -cE '^[^*/]*\bwait_event[a-z_]*\(' "$K"/*.c | awk -F: '{ n += $2 } END { print n + 0 }')"
[ "$WSITES" = 5 ] && pass "wait wakes: 5 wait_event sites, each queue specified" ||
    fail "wait wakes: $WSITES wait_event sites (specified for 5) -- add the new queue's stores and wake to WAKE_SPEC"
UW=""
while IFS= read -r line; do
    f="${line%%|*}"; rest="${line#*|}"; ex="${rest%%|*}"; rest="${rest#*|}"
    wk="${rest##*|}"; st="${rest%|*}"
    UW="$UW$(unwoken "$K/$f" "$ex" "$st" "$wk" | sed "s|$K/||") "
done <<<"$WAKE_SPEC"
[ -z "${UW// /}" ] && pass "wait wakes: every function that can satisfy a wait wakes its queue" ||
    fail "wait wakes: a store that can satisfy a wait, with no wake, in: $UW"
SAMPLE="$(ct_tmp wake-sample).c"
printf 'static void cetrafs_journal_hold_slot(struct cetrafs_journal *j, u32 slot)\n{\n    j->held++;\n}\n' >"$SAMPLE"
[ -n "$(unwoken "$SAMPLE" - 'j->held\+\+' 'wake_up(_all)?\(&j->slot_wq\)')" ] &&
    pass "wait wakes: control -- the old hold_slot (held++ and no wake) is caught" ||
    fail "wait wakes: control -- the old hold_slot is not caught"

# Class 40 (main line and signal handler in the same code). The repair
# tools renew their claim from a SIGALRM handler, and fsck renewed the
# same row from its main line with the same static buffers and SIGALRM
# unmasked: a tick between the main call's read and its CAW made the
# CAW miscompare and the tool exit "claim taken away" (audit 2026-11-05,
# N7). Every function a handler calls is listed with what keeps the
# main line from interleaving with it, and that is checked in its body.
log "checking what the signal handlers call is safe against the main line"
U="$ROOT/userspace"
HANDLERS="$(grep -hoE 'sa_handler = cetrafs_[a-z0-9_]+' "$U"/*.c "$U"/*.h | sed 's/.*= //' | sort -u | tr '\n' ' ')"
[ "$HANDLERS" = "cetrafs_repair_stop cetrafs_repair_tick " ] && pass "signal handlers: the two known handlers, and no new one" ||
    fail "signal handlers: installed handlers are now '$HANDLERS' -- list what each calls below"
fn_body() { # <file> <fn>: the body of a function defined in it
    awk -v f="$2" '$0 ~ "^static.*[ *]" f "\\(" && !/;[[:space:]]*$/ { on = 1 } on { print } on && /^}/ { exit }' "$1"
}
handler_calls() { # <file> <handler...>: cetrafs_* functions the handlers call
    local h="$1"; shift
    for x in "$@"; do fn_body "$h" "$x" | tail -n +2 | grep -oE 'cetrafs_[a-z0-9_]+\(' | tr -d '('; done | sort -u
}
SIGSAFE_OK='cetrafs_repair_renew:masks SIGALRM around the renewal (sigprocmask)
cetrafs_repair_node_beat:called from the tick handler only
cetrafs_repair_release:disarms the timer before any I/O'
CALLED="$(handler_calls "$U/devutil.h" cetrafs_repair_tick cetrafs_repair_stop)"
UNL="$(while read -r c; do [ -n "$c" ] && ! grep -q "^$c:" <<<"$SIGSAFE_OK" && echo "$c"; done <<<"$CALLED" || true)"
[ -n "$CALLED" ] || fail "signal handlers: found nothing the handlers call -- the scan is not seeing them"
[ -z "$UNL" ] && pass "signal handlers: everything they call is listed with what keeps the main line out" ||
    fail "signal handlers: they call, unjudged: $(echo $UNL)"
fn_body "$U/devutil.h" cetrafs_repair_renew | grep -q 'sigprocmask(SIG_BLOCK' &&
    pass "signal handlers: cetrafs_repair_renew masks SIGALRM" ||
    fail "signal handlers: cetrafs_repair_renew no longer masks SIGALRM around the renewal"
fn_body "$U/devutil.h" cetrafs_repair_release | tail -n +2 | grep -m1 -E 'cetrafs_|pread|pwrite' | grep -q 'cetrafs_repair_timer(fd, sb, row, 0)' &&
    pass "signal handlers: cetrafs_repair_release disarms the timer first" ||
    fail "signal handlers: cetrafs_repair_release does I/O before disarming the timer"
NB="$(grep -nE 'cetrafs_repair_node_beat\(' "$U"/*.c "$U"/*.h | grep -vE 'static inline int cetrafs_repair_node_beat|cetrafs_renew_fd' || true)"
[ -z "$NB" ] && pass "signal handlers: cetrafs_repair_node_beat has no main-line caller" ||
    fail "signal handlers: cetrafs_repair_node_beat called from the main line at: $(echo "$NB" | cut -d: -f1,2)"
SAMPLE="$(ct_tmp sig-sample).h"
printf 'static void cetrafs_repair_tick(int sig)\n{\n    cetrafs_write_row(fd);\n}\n' >"$SAMPLE"
[ "$(handler_calls "$SAMPLE" cetrafs_repair_tick)" = cetrafs_write_row ] &&
    pass "signal handlers: control -- an unlisted call in a handler is seen" ||
    fail "signal handlers: control -- a planted handler call is not seen"

# Directory records are written whole from a fresh read in several dir.c
# paths (rename's retarget, the '..' rewrite), which is only safe while
# no field of a directory's record has a writer outside its namespace
# lock. The ones that do on a regular file -- the file lock and read
# presence -- are set by .open/.release/.flock/.lock; a directory
# file_operations with any of them would arm every such write as a
# lost update (audit 2026-11-05, the rename retarget question).
log "checking directory records have no writer outside the namespace lock"
dir_ops_hooks() { awk '/^const struct file_operations cetrafs_dir_ops = \{/ { on = 1 } on { print } on && /^\};/ { exit }' "$1" |
    { grep -oE '^\s*\.(open|release|flock|lock)\s*=' || true; } | tr -d ' .=' | sort -u | tr '\n' ' '; }
DH="$(dir_ops_hooks "$K/dir.c")"
DOPS="$(awk '/^const struct file_operations cetrafs_dir_ops = \{/ { on = 1 } on { n++ } on && /^\};/ { print n; exit }' "$K/dir.c")"
[ "${DOPS:-0}" -ge 3 ] || fail "directory records: cetrafs_dir_ops not found in dir.c -- the scan is not seeing it"
[ -z "$DH" ] && pass "directory records: cetrafs_dir_ops has no open/release/flock/lock hook" ||
    fail "directory records: cetrafs_dir_ops now has $DH-- dir.c's whole-record writes are no longer exclusive"
SAMPLE="$(ct_tmp dirops-sample).c"
printf 'const struct file_operations cetrafs_dir_ops = {\n    .owner = THIS_MODULE,\n    .open = cetrafs_open,\n};\n' >"$SAMPLE"
[ "$(dir_ops_hooks "$SAMPLE")" = "open " ] && pass "directory records: control -- a planted .open is caught" ||
    fail "directory records: control -- a planted .open is not caught"

# Class 42 (VFS state derived from a field a peer changes). The VFS
# caches S_NOSEC -- "no setuid/setgid, no security xattr" -- after one
# write finds nothing to kill, and clears it only in its own
# notify_change(). A mode adopted from the device left it set, so a
# peer's chmod +s was never killed by an unprivileged write here. Every
# in-core mode assignment goes through cetrafs_inode_adopt_identity(),
# which clears it; the two others are listed with their reason.
log "checking every adopted mode clears the VFS's derived S_NOSEC"
MODE_OK='inode.c:inode->i_mode = (umode_t) cetrafs_le32(raw->mode);:the helper itself
inode.c:inode->i_mode = cetrafs_le32(raw.mode);:iget of a NEW inode -- no flag to clear yet
file.c:inode->i_mode = saved.mode;:setattr rollback to this node own previous mode'
mode_sites() { grep -HE '^\s*inode->i_mode = ' "$@" | grep -vE '^\S+:\s*\*' | sed -E "s|^.*/||; s|:\s+|:|"; }
MS="$(mode_sites "$K"/*.c)"
[ "$(grep -c . <<<"$MS")" -ge 3 ] || fail "adopted mode: found only $(grep -c . <<<"$MS") i_mode assignments -- the scan is not seeing the tree"
UNM="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -qF "$l:" <<<"$MODE_OK" && echo "$l"; done <<<"$MS" || true)"
[ -z "$UNM" ] && pass "adopted mode: every i_mode assignment is the helper or a listed exception" ||
    fail "adopted mode: set i_mode through cetrafs_inode_adopt_identity() (it clears S_NOSEC): $UNM"
grep -A6 '^void cetrafs_inode_adopt_identity' "$K/inode.c" | grep -q 'i_flags &= ~S_NOSEC' &&
    pass "adopted mode: the helper clears S_NOSEC" || fail "adopted mode: cetrafs_inode_adopt_identity() no longer clears S_NOSEC"
SAMPLE="$(ct_tmp mode-sample).c"
printf '    inode->i_mode = cetrafs_le32(bufs[0].mode);\n' >"$SAMPLE"
[ -n "$(mode_sites "$SAMPLE" | while IFS= read -r l; do grep -qF "$l:" <<<"$MODE_OK" || echo "$l"; done)" ] &&
    pass "adopted mode: control -- a direct assignment is caught" ||
    fail "adopted mode: control -- a direct assignment is not caught"

# Class 27 (same-node torn reads), the CAS layer. A CAS copies its
# compare image out of a buffer that cetrafs_cache_region_after_cas()
# patches under the buffer lock after another local CAS on the same
# record; an unlocked memcpy/memcmp can see half a patch, which a
# checksummed mutator refuses as damage (audit 2026-11-06 M13). Every
# read of b_data in caw.c goes through cetrafs_bh_copy_stable_at() /
# cetrafs_bh_memcmp_stable_at(); the writes under the update protocol and
# the selftest's quiescent read-back are listed.
log "checking the CAS layer reads buffer bytes only under the buffer lock (class 27)"
CAW_OK='memcpy(bh->b_data + off, new, region);:a WRITE, inside cetrafs_bh_begin_update()/end_update()
memcpy(&final, bh->b_data + CETRAFS_CAS_SELFTEST_OFF, sizeof(final));:selftest read-back after every worker has finished'
caw_raw() { grep -hE '(memcpy|memcmp)\([^;]*b_data' "$@" | grep -vE '^[[:space:]]*(\*|/\*)' | sed -E 's/^[[:space:]]+//'; }
CR="$(caw_raw "$K/caw.c")"
UNC="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -qF "$l:" <<<"$CAW_OK" && echo "$l"; done <<<"$CR" || true)"
[ -z "$UNC" ] && pass "class 27: caw.c reads buffer bytes only through the locked helpers" ||
    fail "class 27: unlocked b_data read in caw.c (use cetrafs_bh_copy_stable_at/_memcmp_stable_at): $UNC"
grep -q 'lock_buffer' <<<"$(sed -n '/^void cetrafs_bh_copy_stable_at/,/^}/p' "$K/ioutil.c")" &&
    grep -q 'lock_buffer' <<<"$(sed -n '/^int cetrafs_bh_memcmp_stable_at/,/^}/p' "$K/ioutil.c")" &&
    pass "class 27: both helpers take the buffer lock" || fail "class 27: a stable-read helper no longer takes the buffer lock"
SAMPLE="$(ct_tmp caw-sample).c"
printf '            memcpy(old, bh->b_data + off, region);\n' >"$SAMPLE"
[ "$(caw_raw "$SAMPLE")" = "memcpy(old, bh->b_data + off, region);" ] &&
    pass "class 27: control -- a planted unlocked copy is found" || fail "class 27: control -- a planted unlocked copy is not found"

# Class 30 (a transport result classified as definite), the CAS loop. A
# swap that timed out may still land, so once one is in flight every way
# out of cetrafs_cas_region_seeded_impl() must either have confirmed it
# or stop the mount; a plain error lets the caller re-accrue its delta
# under a command that then lands too (audit 2026-11-06 L12). Checked
# structurally: the buffer that holds the in-flight swap is allocated
# before the loop (no -ENOMEM mid-flight), nothing inside the loop returns
# except through 'out:', and 'out:' stops the mount for an undecided swap.
log "checking every exit of the CAS loop settles a timed-out swap (class 30)"
cas_body() { sed -n '/^static int cetrafs_cas_region_seeded_impl(/,/^}/p' "$1"; }
cas_check() { # <file>: prints what is wrong, nothing when it holds
    local b; b="$(cas_body "$1")"
    [ -n "$b" ] || { echo "no cetrafs_cas_region_seeded_impl"; return; }
    [ "$(grep -c 'unknown = kmalloc' <<<"$b")" = 1 ] || echo "the in-flight buffer is allocated $(grep -c 'unknown = kmalloc' <<<"$b") times"
    awk '/unknown = kmalloc/{a=NR} /for [(]attempt = 0;/{if(!f){f=NR}} END{if(!a||!f||a>f) print "the in-flight buffer is not allocated before the loop"}' <<<"$b"
    awk '/for [(]attempt = 0;/{on=1} /^out:/{on=0} on && /^[[:space:]]+return /{print "a return inside the loop skips out: -- " $0}' <<<"$b"
    sed -n '/^out:/,/kfree(unknown)/p' <<<"$b" | grep -q 'if (undecided && ret' || echo "out: does not stop the mount for an undecided swap"
}
CC="$(cas_check "$K/caw.c")"
[ -z "$CC" ] && pass "class 30: every exit of the CAS loop confirms a timed-out swap or stops the mount" ||
    fail "class 30: $CC"
SAMPLE="$(ct_tmp cas-sample).c"
printf 'static int cetrafs_cas_region_seeded_impl(void)\n{\n    unknown = kmalloc(2, GFP_KERNEL);\n    for (attempt = 0; attempt < 3; attempt++) {\n        if (x)\n            return -EIO;\n    }\nout:\n    if (undecided && ret)\n        stop();\n    kfree(unknown);\n}\n' >"$SAMPLE"
grep -q "a return inside the loop" <<<"$(cas_check "$SAMPLE")" &&
    pass "class 30: control -- a plain return from inside the loop is caught" ||
    fail "class 30: control -- a plain return from inside the loop is not caught"

# Class 44 ("alive" as the unsafe default). A liveness predicate's first
# look at a row answers "alive" -- right for a reclaim, which then keeps
# its hands off, and wrong for a caller that REFUSES or INHERITS on it
# with no earlier look to compare against: the mount-time peer checks
# judged a crashed node's row live forever (audit 2026-11-06 M5). Every
# function that asks is listed with what it does on "alive"; a new one
# fails here until someone has said which way its answer is safe.
log "checking every caller of a liveness predicate names its safe direction (class 44)"
LIVE_OK='fs.c:cetrafs_sb_peer_progress_stale:the predicate itself
node.c:cetrafs_node_is_stale:the predicate itself
node.c:cetrafs_for_each_live_peer:mount-time walk -- proves alive by watching hb_seq move, never by one sample
node.c:cetrafs_node_cluster_file_lock_mode:the walk
node.c:cetrafs_node_file_lock_mode_conflict:the walk
node.c:cetrafs_node_nocaw_peer_exists:the walk
node.c:cetrafs_node_single_mounter_conflict:the walk
node.c:cetrafs_node_seed_peer_watch:seeds the watch, decides nothing
node.c:cetrafs_node_frees_snapshot:alive -> frees in flight, the scrub skips its cycle (keep)
heartbeat.c:cetrafs_heartbeat_maint:alive -> leave its journal alone (keep)
inode.c:cetrafs_write_vfs_inode:alive -> drop our own dirt (keep the record)
journal.c:cetrafs_journal_claim_replay:alive -> leave the replay to it (keep)
lock.c:cetrafs_foreign_claim_from_raw:alive -> a live claim (keep)
lock.c:cetrafs_foreign_reader_from_raw:alive -> keep its reader bit
lock.c:cetrafs_lock_explicit_acquire:alive -> keep waiting; the runtime watch converges
lock.c:cetrafs_lock_open:alive -> refuse this open; the runtime watch converges on retry
nslock.c:cetrafs_nslock_try:alive -> wait and retry
procfs.c:cetrafs_proc_cluster_show:display only
scrub.c:scrub_reclaim_orphan_inodes:alive -> skip (keep)
zonegroup.c:cetrafs_zg_claim_one_more_locked:alive -> not a candidate (keep)
zonegroup.c:cetrafs_zg_log_foreign_free_leak:log only
zonegroup.c:cetrafs_zg_scrub_adopt_one_stale:alive -> skip (keep)
zonegroup.c:__cetrafs_zg_try_claim_one:alive -> leave the Zone Group (keep)'
live_callers() {
    for f in "$@"; do
        awk -v F="$(basename "$f")" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn) }
            /cetrafs_node_is_stale\(|cetrafs_sb_peer_progress_stale\(|cetrafs_for_each_live_peer\(/ && !/^[[:space:]]*\*/ && !/^[[:space:]]*\/\*/ { print F ":" fn }' "$f"
    done | sort -u
}
LC="$(live_callers "$K"/*.c)"
[ "$(grep -c . <<<"$LC")" -ge 15 ] || fail "class 44: found only $(grep -c . <<<"$LC") callers -- the scan is not seeing the tree"
UNL="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -qF "$l:" <<<"$LIVE_OK" && echo "$l"; done <<<"$LC" || true)"
[ -z "$UNL" ] && pass "class 44: every caller of a liveness predicate names what it does on 'alive'" ||
    fail "class 44: unclassified liveness callers (is 'alive' the safe answer there?): $(echo $UNL)"
SAMPLE="$(ct_tmp live-sample).c"
printf 'static int cetrafs_new_refuser(struct super_block *sb)\n{\n    return cetrafs_node_is_stale(sb, 1, &s);\n}\n' >"$SAMPLE"
[ "$(live_callers "$SAMPLE")" = "$(basename "$SAMPLE"):cetrafs_new_refuser" ] &&
    pass "class 44: control -- a planted caller is found" || fail "class 44: control -- a planted caller is not found"

# Class 45 (repair before the verdict, repair of the ambiguous). fsck -r
# wrote repairs while a later pass could still find the fault that
# disables repair, and restamped records it had not shown to be valid
# records of that number (audit 2026-11-06 M11, M12).
#  (a) every function that restamps an inode record calls
#      fsck_record_restampable(), or is listed (it builds a NEW record);
#  (b) every repair gate before the last repair_block() in main() carries
#      a "class 45:" note naming why it is safe whatever the run decides
#      later -- keep, set, recount, lossless, deferred, or allowed.
log "checking fsck restamps only valid records and justifies every early repair (class 45)"
FSCK_C="$ROOT/userspace/fsck.c"
RESTAMP_OK='fsck_write_inode:the writer itself
fsck_lost_found:writes the new record it built'
restampers() { # <file> -> fn names that restamp a record without the check
    awk '
        /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { if (fn != "" && hit && !chk) print fn; fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn); hit = 0; chk = 0 }
        /cetrafs_inode_stamp_crcs_us\(|fsck_write_inode\(/ && !/^[a-z_]/ && !/^[[:space:]]*\*/ { hit = 1 }
        /fsck_record_restampable\(/ && !/^[a-z_]/ { chk = 1 }
        END { if (fn != "" && hit && !chk) print fn }' "$1" | sort -u
}
RS="$(restampers "$FSCK_C")"
RSU="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -q "^$l:" <<<"$RESTAMP_OK" && echo "$l"; done <<<"$RS" || true)"
[ -z "$RSU" ] && pass "class 45: every fsck restamp checks the record is a valid record of that number" ||
    fail "class 45: fsck restamps without fsck_record_restampable(): $(echo $RSU)"
grep -q "^fsck_lost_found$" <<<"$RS" || fail "class 45: the restamp scan no longer sees fsck_lost_found's write -- is it seeing the file?"
SAMPLE="$(ct_tmp fsck-restamp).c"
printf 'static void fsck_new_fixer(int fd)\n{\n    fsck_write_inode(fd, sb, 5, &in);\n}\n' >"$SAMPLE"
[ "$(restampers "$SAMPLE")" = "fsck_new_fixer" ] &&
    pass "class 45: control -- a planted unchecked restamp is found" ||
    fail "class 45: control -- a planted unchecked restamp is not found"
early_gates() { # <file> -> line numbers of untagged gates before main's last repair_block()
    awk '
        /^int main\(/ { inmain = 1 }
        { line[NR] = $0 }
        inmain && /repair_block\(/ && !/^[[:space:]]*\*/ && !/static void repair_block/ { last = NR }
        inmain && /repair_mode && !repair_blocked/ { g[++ng] = NR }
        END {
            for (i = 1; i <= ng; i++) {
                n = g[i]
                if (n > last) continue
                if (line[n] ~ /class 45:/ || line[n - 1] ~ /class 45:/ || line[n + 1] ~ /class 45:/) continue
                print n
            }
        }' "$1"
}
EG="$(early_gates "$FSCK_C")"
NG="$(awk '/^int main\(/{m=1} m && /repair_mode && !repair_blocked/' "$FSCK_C" | grep -c .)"
[ "$NG" -ge 15 ] || fail "class 45: found only $NG repair gates in main() -- the scan is not seeing the file"
[ -z "$EG" ] && pass "class 45: every repair ahead of fsck's last repair_block() names why it is safe" ||
    fail "class 45: repairs before the verdict is final, with no class 45 note (fsck.c lines): $(echo $EG)"
SAMPLE="$(ct_tmp fsck-early).c"
printf 'int main(void)\n{\n    if (repair_mode && !repair_blocked)\n        fix();\n    repair_block("late");\n}\n' >"$SAMPLE"
[ "$(early_gates "$SAMPLE")" = "3" ] && pass "class 45: control -- a planted untagged early gate is found" ||
    fail "class 45: control -- a planted untagged early gate is not found"

# Class 46 (judging the midpoint of a peer's multi-step operation). An
# operation that publishes a record dropping blocks and only then frees
# them leaves the blocks named by nothing and not yet free -- the scrub's
# definition of a leak -- and when a peer owns them the frees are queue
# CASes that can run past the scrub's gap: the owner freed them first and
# its drain freed them again (audit 2026-11-06, N2 sweep finding A). Every
# function that frees blocks either brackets the window with
# cetrafs_frees_begin(), or is listed with what covers it instead.
log "checking every block free is announced to the scrub or names what covers it (class 46)"
FREE_OK='alloc.c:__cetrafs_free_data_extent:the primitive
alloc.c:cetrafs_free_data_extent:the primitive
alloc.c:cetrafs_free_data_extent_unless_reserved:the primitive (the scrub'"'"'s)
file.c:cetrafs_free_fetched_extents:primitive -- evict'"'"'s, whose record names the blocks until forget_tree
file.c:cetrafs_free_inline_extents:primitive
file.c:cetrafs_free_leaf_array:primitive
file.c:cetrafs_leaf_array_punch:primitive -- its do_free callers are checked
file.c:cetrafs_leaf_array_trim:primitive -- its do_free callers are checked
file.c:cetrafs_tree_free_meta:primitive -- its callers are checked
defrag.c:cetrafs_defrag_commit:inside its only caller'"'"'s bracket (cetrafs_defrag_inode)
super_ops.c:cetrafs_evict_inode:the claimed dead record names every block until forget_tree (H1)
scrub.c:scrub_free_confirmed:the judge itself
file.c:cetrafs_do_allocate:blocks never published, held in the reservation registry until given back (H2)
file.c:__cetrafs_get_block:a block it allocated and never published
file.c:cetrafs_tree_append:a leaf or index it allocated and never published
file.c:cetrafs_tree_build:a tree it built and never published
dir.c:cetrafs_mkdir_locked:a dirent block it allocated and never published
lock.c:cetrafs_inode_set_reservation:a reservation run, never published
lock.c:cetrafs_inode_drop_reservation:the unused rest of a reservation run, never published'
free_callers() {
    for f in "$@"; do
        awk -v F="$(basename "$f")" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { if (fn != "" && hit && !beg) print F ":" fn; fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn); hit = 0; beg = 0 }
            /(cetrafs_free_data_block|cetrafs_free_data_extent|cetrafs_free_data_extent_unless_reserved|cetrafs_zg_queue_foreign_free|cetrafs_tree_free_meta|cetrafs_free_fetched_extents|cetrafs_free_leaf_array|cetrafs_free_inline_extents|cetrafs_leaf_array_trim|cetrafs_leaf_array_punch)\(/ && !/^[a-z_]/ && !/^[[:space:]]*\*/ && !/^[[:space:]]*\/\*/ { hit = 1 }
            /cetrafs_frees_begin\(/ && !/^[a-z_]/ { beg = 1 }
            END { if (fn != "" && hit && !beg) print F ":" fn }' "$f"
    done | sort -u
}
FC="$(free_callers "$K"/*.c)"
[ "$(grep -c . <<<"$FC")" -ge 15 ] || fail "class 46: found only $(grep -c . <<<"$FC") unbracketed freeing functions -- the scan is not seeing the tree"
for b in __cetrafs_truncate_shrink cetrafs_defrag_inode cetrafs_xattr_set_locked cetrafs_fallocate; do
    grep -q "cetrafs_frees_begin" <<<"$(awk "/^[a-z_].*[ *]$b\\(/,/^}/" "$K"/*.c)" ||
        fail "class 46: $b no longer brackets its post-publish frees with cetrafs_frees_begin()"
done
UNF="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -qF "$l:" <<<"$FREE_OK" && echo "$l"; done <<<"$FC" || true)"
[ -z "$UNF" ] && pass "class 46: every function that frees blocks announces it or names what covers the window" ||
    fail "class 46: frees with no cetrafs_frees_begin() and no stated cover (can a scrub judge the midpoint?): $(echo $UNF)"
SAMPLE="$(ct_tmp free-sample).c"
printf 'static int cetrafs_new_dropper(struct super_block *sb)\n{\n    publish(sb);\n    cetrafs_free_data_block(sb, 5);\n}\n' >"$SAMPLE"
[ "$(free_callers "$SAMPLE")" = "$(basename "$SAMPLE"):cetrafs_new_dropper" ] &&
    pass "class 46: control -- a planted unannounced free is found" ||
    fail "class 46: control -- a planted unannounced free is not found"

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
elif modinfo "$KO" 2>/dev/null | grep -qx "alias: *fs-$(sed -n 's/^#define CETRAFS_NAME[[:space:]][[:space:]]*"\([a-z][a-z]*\)".*/\1/p' "$ROOT/include/cetrafs.h")"; then
    pass "module alias: the built module declares fs-cetrafs, so mount -t autoloads it"
else
    fail "module alias: no fs-cetrafs alias in the built module (MODULE_ALIAS_FS gone?) -- \`mount -t cetrafs\` will fail with 'unknown filesystem type' unless something loaded it first. modinfo says: $(modinfo "$KO" 2>&1 | grep -E '^alias' || echo '(no alias at all)')"
fi

ct_exit
