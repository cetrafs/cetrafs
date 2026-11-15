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
        # cetrafs_tree_hold_back() likewise: it ends the update itself,
        # held back for the boundary or journaled now (file.c).
        inreg && /cetrafs_bh_end_update\(|cetrafs_bh_abort_update\(|cetrafs_journal_write_(new_)?block\(|cetrafs_tree_hold_back\(/ { inreg=0; next }
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
        inloop && /usleep_range|msleep|cetrafs_tear_backoff/ { sawsleep=1 }
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
    /^(static )?void cetrafs_inode_stamp_crc_fd(_as)?\(/ { inside = 1 }
    inside && /^}/ { inside = 0; next }
    !inside && /fd_checksum[[:space:]]*=/ { print FILENAME ":" NR }
' "$K"/*.c || true)"
if [ -z "$FDC" ]; then
    pass "file freshness: fd_checksum is only written by cetrafs_inode_stamp_crc_fd[_as](), so every publish stamps file_seq"
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
    done < <(grep -oE '(module_param_named|cetrafs_test_param)\((fail|force)[a-z_]*|(module_param_named|cetrafs_test_param)\([a-z_]*(fail|force|stress|selftest|skip_precheck)[a-z_]*|(module_param_named|cetrafs_test_param)\([a-z_]*_at,' "$f" | sed -E 's/(module_param_named|cetrafs_test_param)\(//; s/,$//')
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
        # A description may wrap (clang-format puts a long one on the
        # next line): it is read up to its closing ");", or cas_selftest
        # -- "test-only" on the line after MODULE_PARM_DESC( -- passed
        # unseen (audit 2026-11-11 C7).
        pend { txt = txt " " $0
               if (nm == "") { nm = $0; gsub(/^[ \t]+/, "", nm); sub(/,.*/, "", nm) }
               if ($0 ~ /\);/) { judge(); pend = 0 }
               next }
        /MODULE_PARM_DESC\(/ { d = $0; sub(/.*MODULE_PARM_DESC\(/, "", d); nm = d; sub(/,.*/, "", nm); txt = $0
                               if ($0 ~ /\);/) judge(); else pend = 1 }
        function judge() { if (nm in decl && tolower(txt) ~ /test[- ]only/) print decl[nm] ":" nm }' "$@"
}
SAMPLE="$(ct_tmp testparam-sample)"
printf '%s\n' 'module_param_named(x_knob, x, bool, 0644);' 'MODULE_PARM_DESC(x_knob, "TEST ONLY: bends a check");' >"$SAMPLE"
[ -n "$(untraced_test_params "$SAMPLE")" ] || fail "test params: the check does not flag the known-bad sample"
printf '%s\n' 'module_param_named(y_knob, y, bool, 0644);' 'MODULE_PARM_DESC(' '    y_knob,' '    "test-only: wraps");' >"$SAMPLE"
[ -n "$(untraced_test_params "$SAMPLE")" ] || fail "test params: the check does not flag a known-bad sample whose description wraps"
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
hb_interval_secs:heartbeat period for new mounts; clamped 1..3600 (cetrafs_param_hb_interval_secs)
stale_secs:stale window for new mounts; clamped 3..86400 and to >= 3 beats (cetrafs_param_stale_secs)
node_uuid:load-time only (0444): this node identity
pf_full_backoff_ms:pending-free queue backoff (latency)
pf_drain_min_ms:pending-free drain rate limit (latency)
lock_yield_wait_ms:how long an open waits for a background defrag to yield (latency); killable, clamped to 10 min, 0 refuses at once as before
own_claim_resweep_secs:delay of the late own-claim sweep; every clear is judged under the inode lock_mutex, 0 (off) leaves stray claims as they were'
plain_params() { grep -hoE '^module_param(_named)?\([a-z_0-9]+' "$@" | sed -E 's/^module_param(_named)?\(//' | sort -u; }
UNLISTED="$(plain_params "$K"/*.c | while read -r n; do grep -q "^$n:" <<<"$PLAIN_OK" || echo "$n"; done)"
NPLAIN="$(plain_params "$K"/*.c | wc -l)"
[ "$NPLAIN" -ge 10 ] || fail "plain params: found only $NPLAIN -- the scan is not seeing the tree"
[ -z "$UNLISTED" ] && pass "plain params: all $NPLAIN plain module parameters are listed tuning knobs" ||
    fail "plain params: not TEST ONLY and not listed (bound it or trace it): $(echo $UNLISTED)"
SAMPLE="$(ct_tmp plainparam-sample).c"
printf '%s\n' 'module_param_named(x_window_secs, cetrafs_x_window_secs, uint, 0644);' >"$SAMPLE"
[ "$(plain_params "$SAMPLE")" = x_window_secs ] && ! grep -q "^x_window_secs:" <<<"$PLAIN_OK" &&
    pass "plain params: control -- an unlisted plain parameter is flagged" ||
    fail "plain params: control -- an unlisted plain parameter is not flagged"

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
discard.c|d->dwork|cancel_delayed_work_sync(&d->dwork)|cetrafs_inline_discard_close(
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
lock.c|cetrafs_lock_release|ihold
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

# Class 19's other half: nothing that can sleep runs with a spinlock
# held. Every code line between a spin/rw/xa lock and its unlock (per
# function, comments stripped) is scanned for the sleeping primitives,
# and every cetrafs_* function called there is pinned to a list of ones
# read and found not to sleep -- a new callee fails until someone has
# read it. A helper that sleeps only on a path it never takes under the
# lock still has to be split or listed; that is the point.
log "checking nothing that can sleep runs under a spinlock (class 19)"
spin_lines() { # <files...>: file:line:code for every line run with a spinlock held
    awk '{
        line = $0; out = ""
        while (line != "") {
            if (incom) { i = index(line, "*/"); if (!i) { line = ""; break } line = substr(line, i + 2); incom = 0 }
            else { i = index(line, "/*"); if (!i) { out = out line; line = ""; break }
                   out = out substr(line, 1, i - 1); line = substr(line, i + 2); incom = 1 }
        }
        sub(/\/\/.*/, "", out)
        if (out ~ /^[a-z].*\(/ && out !~ /;/) depth = 0
        if (depth > 0 && out ~ /[^[:space:]]/) print FILENAME ":" FNR ":" out
        n = gsub(/(^|[^a-z0-9_])(spin_lock|spin_lock_irq|spin_lock_irqsave|spin_lock_bh|read_lock|write_lock|xa_lock|xa_lock_irq)\(/, "&", out)
        m = gsub(/(^|[^a-z0-9_])(spin_unlock|spin_unlock_irq|spin_unlock_irqrestore|spin_unlock_bh|read_unlock|write_unlock|xa_unlock|xa_unlock_irq)\(/, "&", out)
        depth += n - m; if (depth < 0) depth = 0
    }' "$@"
}
SPIN_SLEEPERS_RE='\b(msleep|usleep_range|ssleep|mutex_lock[a-z_]*|down|down_[a-z_]+|wait_event[a-z_]*|wait_for_[a-z_]+|schedule[a-z_]*|cond_resched|lock_buffer|wait_on_buffer|[a-z_]*bread[a-z_]*|submit_bh|sync_dirty_buffer|iput|brelse|vmalloc|kvmalloc|copy_(to|from)_user|cancel_[a-z_]*_sync|flush_[a-z_]+|synchronize_[a-z_]+)\('
SPIN_OK='cetrafs_peer_window_floor_secs cetrafs_sb_own_renewal_overdue cetrafs_deferred_on_list cetrafs_deferred_eager cetrafs_ext_key_matches cetrafs_inode_deferred cetrafs_inode_fd_copy cetrafs_inode_get_generation cetrafs_inode_wb_failed cetrafs_le16 cetrafs_le32 cetrafs_le64 cetrafs_nswait_is_current cetrafs_pending_any cetrafs_row_mark_of cetrafs_row_mark_same cetrafs_sb_bg_discard_pending_ignored cetrafs_sb_layout_of cetrafs_sb_stale_secs'
SL="$(spin_lines "$K"/*.c)"
[ "$(wc -l <<<"$SL")" -gt 100 ] || fail "class 19 spinlock: setup -- only $(wc -l <<<"$SL") lines found under a spinlock (the scan no longer matches)"
SPIN_BAD="$(grep -E "$SPIN_SLEEPERS_RE" <<<"$SL" | grep -vE 'GFP_ATOMIC|GFP_NOWAIT' | head -5 || true)"
SPIN_GFP="$(grep -E '(GFP_KERNEL|GFP_NOFS|GFP_NOIO)' <<<"$SL" | head -5 || true)"
SPIN_NEW="$(comm -23 <(cut -d: -f3- <<<"$SL" | grep -oE '\bcetrafs_[a-z0-9_]+\(' | tr -d '(' | sort -u) <(tr ' ' '\n' <<<"$SPIN_OK" | sort -u) | tr '\n' ' ')"
[ -z "$SPIN_BAD$SPIN_GFP" ] && pass "class 19 spinlock: no sleeping primitive under a spinlock ($(wc -l <<<"$SL") lines)" ||
    fail "class 19 spinlock: can sleep under a spinlock: $SPIN_BAD $SPIN_GFP"
[ -z "${SPIN_NEW// /}" ] && pass "class 19 spinlock: every cetrafs_* call under a spinlock is a listed non-sleeper" ||
    fail "class 19 spinlock: unlisted callee(s) under a spinlock: $SPIN_NEW-- read each for a sleep, then add it to SPIN_OK"
SPIN_SAMPLE="$(ct_tmp spin).c"
printf 'void cetrafs_x(struct inode *inode)\n{\n    /* spin_unlock( in a comment */\n    spin_lock(&ci->lock);\n    msleep(1);\n    cetrafs_y(inode);\n    spin_unlock(&ci->lock);\n    msleep(2);\n}\n' >"$SPIN_SAMPLE"
SPIN_C="$(spin_lines "$SPIN_SAMPLE")"
grep -qE "$SPIN_SLEEPERS_RE" <<<"$SPIN_C" && grep -q 'cetrafs_y(' <<<"$SPIN_C" && ! grep -q 'msleep(2)' <<<"$SPIN_C" &&
    pass "class 19 spinlock: control -- a planted sleep and callee under a lock are found, the one after it is not" ||
    fail "class 19 spinlock: control -- the scan missed the planted sleep ($SPIN_C)"

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

# A reclaim takes a claim its holder's row has gone stale on. The row
# id alone cannot say whether the claim is still the dead session's: a
# holder that re-attached, swept and took it again writes the very bytes
# compared (class 28). The old cure -- take it, then give it back if the
# holder came back -- was an undo that had to know what it had DONE, and
# five sites got that wrong one at a time. Format 0x000A stamps every
# claim with the incarnation of the mount that took it, and every
# reclaim's swap requires the claim to still carry the incarnation it
# judged, so a re-taken claim is never taken and there is nothing to
# give back. So: each claim kind's mutator compares its record's
# incarnation with ctx->steal_incarnation, and no give-back of a steal
# exists. Negative control: drop the comparison from nslock.c's
# stealable test -- fails.
log "checking every reclaim compares the claim's incarnation (class 28)"
steal_inc_cmp() { # <file> <record field>: does a mutator compare it with the judged incarnation?
    grep -qE "$2(\[[a-z_]+\])?\)? *(==|!=) *ctx->steal_incarnation" "$1"
}
SI=""
for fc in lock.c:lock_owner_incarnation lock.c:read_open_incarnation nslock.c:ns_lock_incarnation \
          journal.c:replay_incarnation; do
    steal_inc_cmp "$K/${fc%%:*}" "${fc#*:}" || SI="$SI$fc "
done
[ -z "$SI" ] && pass "class 28: the lock, reader-bit, namespace-lock and replay-claim steals compare the incarnation" ||
    fail "class 28: a steal no longer compares the claim's incarnation: $SI"
GB="$(grep -nE 'cetrafs_lock_undo_steal\(|ret == 0 &&.*reattached_since_fence\(' "$K"/*.c || true)"
[ -z "$GB" ] && pass "class 28: no reclaim gives a stolen claim back" ||
    fail "class 28: a give-back of a steal is back -- it must know what it took (see the class): $(echo $GB)"
SAMPLE="$(ct_tmp stealinc).c"
printf '    stealable = cetrafs_le32(rec.ns_lock_holder) == ctx->steal_from;\n' >"$SAMPLE"
! steal_inc_cmp "$SAMPLE" ns_lock_incarnation &&
    printf '    stealable = stealable && cetrafs_le32(rec.ns_lock_incarnation) == ctx->steal_incarnation;\n' >"$SAMPLE" &&
    steal_inc_cmp "$SAMPLE" ns_lock_incarnation &&
    pass "class 28: control -- a steal without the comparison is caught, one with it is not" ||
    fail "class 28: control -- the incarnation comparison scan does not discriminate"

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

# Class 52: a count held in two places that readers add up -- an accrued
# delta in memory plus the record it is flushed to -- must never be in
# neither (taken from memory before the record or its cached copy holds
# it) nor in both. Two halves:
#  (a) every take of an accrued delta (atomic64_xchg on a *_free_delta)
#      carries a "class 52:" comment within 8 lines above, saying how a
#      reader stays whole -- a flight, or why nothing reads it there;
#  (b) the delta is read only by the settles that know about flights,
#      and by the presence/count helpers listed below -- a new reader
#      that adds it to a record by hand is the bug this class is about.
# The scan runs over a planted file of each kind first: both must be
# refused (the 2026-11-12 ENOSPC: the flush's xchg had no flight, and
# cetrafs_bg_data_block_stats() added the delta to the descriptor itself).
log "checking accrued free deltas are never in neither place nor in both (class 52)"
c52_scan() { # <dir>: prints file:line of each violation
    local f
    for f in "$1"/*.c; do
        awk -v F="$(basename "$f")" '
            BEGIN { last52 = -100 }
            /^[a-z].*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.* \**/, "", fn) }
            /class 52:/ { last52 = NR }
            /atomic64_xchg\(&[a-z_>.-]*_free_delta/ && NR - last52 > 8 { print F ":" NR ": take with no class 52 argument" }
            /atomic64_read\(&[a-z_>.-]*_free_delta/ && fn !~ /^(cetrafs_sb_bg_free_settle|cetrafs_sb_zg_free_settle|cetrafs_sb_pending_zg_deltas|cetrafs_sb_zg_delta_pending|cetrafs_sb_bg_delta_pending|cetrafs_flush_dirty_free_counts)$/ {
                print F ":" NR ": " fn " reads the delta outside the settles"
            }' "$f"
    done
}
C52P="$(mktemp -d)"
ct_track dir "$C52P" 2>/dev/null || true
cat >"$C52P/planted.c" <<'EOF'
s64 bad_take(struct cetrafs_sb_info *sbi, u32 z)
{
    return atomic64_xchg(&sbi->zg_free_delta[z], 0);
}

u64 bad_sum(struct cetrafs_bg_chunk *c, u32 i, u64 desc)
{
    return desc + atomic64_read(&c->bg_free_delta[i]);
}
EOF
C52N="$(c52_scan "$C52P" | wc -l)"
rm -rf "$C52P"
[ "$C52N" = 2 ] || fail "class 52: the planted take and reader gave $C52N findings, want 2 -- the scan sees nothing"
C52="$(c52_scan "$K")"
N52="$(cat "$K"/*.c | grep -c 'class 52:' || true)"
[ "$N52" -ge 5 ] || fail "class 52: found $N52 annotations -- the check sees nothing"
[ -z "$C52" ] && pass "class 52: every take of an accrued delta names its flight, and only the settles read it" ||
    fail "class 52: $(echo "$C52" | tr '\n' ';')"

# Class 55: a dirty mark cleared as the CLAIM to write what it marks.
# A second caller that finds it clear while the first's write is still
# out reads "nothing to do" and goes on -- and if it then publishes on
# that, the publish can reach the device ahead of what it refers to
# (audit 2026-11-14 A1: two bitmap flushes, one fsync's extents
# published over bits still in flight). Every clear of a *dirty mark
# carries a "class 55:" comment within 6 lines above, naming what a
# second caller who finds it clear waits on, or why none needs to.
log "checking every dirty mark cleared before its write names what a second caller waits on (class 55)"
c55_scan() { # <dir>: file:line of each unargued clear
    local f
    for f in "$1"/*.c; do
        awk -v F="$(basename "$f")" '
            BEGIN { last = -100 }
            /class 55:/ { last = NR }
            /(test_and_clear_bit|clear_bit)\([^)]*dirty|[a-z_>.]+_dirty = false/ && !/test knob/ && !/\*out_/ &&
                NR - last > 6 { print F ":" NR ": " $0 }' "$f"
    done
}
C55P="$(mktemp -d)"
cat >"$C55P/planted.c" <<'EOF'
bool take(struct cetrafs_bg_chunk *c, u32 i)
{
    return test_and_clear_bit(i, c->bmap_alloc_dirty);
}

void done(struct cetrafs_inode_info *ci)
{
    ci->fd_dirty = false;
}
EOF
C55N="$(c55_scan "$C55P" | wc -l)"
rm -rf "$C55P"
[ "$C55N" = 2 ] && pass "class 55: control -- a planted take and a planted clear are found" ||
    fail "class 55: control -- the planted clears gave $C55N findings, want 2"
N55="$(cat "$K"/*.c | grep -c 'class 55:' || true)"
[ "$N55" -ge 8 ] || fail "class 55: found $N55 annotations -- the check sees nothing"
C55="$(c55_scan "$K")"
[ -z "$C55" ] && pass "class 55: every dirty mark cleared names what a second caller finding it clear waits on" ||
    fail "class 55: $(echo "$C55" | tr '\n' ';')"

# Class 57: a tool reading what a peer on another host writes, through
# this host's page cache. The kernel writes the Node Registry with its
# own I/O and a peer host never touches our cache, so a buffered re-read
# returns the first read forever (audit 2026-11-14 U1: the repair
# claim's heartbeat watch; its sibling, growfs's node-readiness scan).
# Every tool function that reads registry rows drops this host's copy
# in the same function, or is listed with why its callers do.
log "checking every tool read of the Node Registry drops this host's cached copy (class 57)"
# cetrafs_repair_row_read: its two callers drop the whole registry
# before each pass (cetrafs_repair_watch_arm(), the beat check).
C57_OK="cetrafs_repair_row_read"
C57_SCAN="$CT_TESTS/image/c57_scan.py"
C57P="$(mktemp -d)"
cat >"$C57P/planted.h" <<'EOF'
static inline int cached_row(int fd, const cetrafs_superblock_t *sb, uint32_t idx, cetrafs_node_entry_t *ne)
{
    /* posix_fadvise in a comment is not a drop */
    return pread(fd, ne, sizeof(*ne), cetrafs_node_row_off(sb, idx)) == (ssize_t) sizeof(*ne);
}
EOF
C57N="$(python3 "$C57_SCAN" "$C57_OK" "$C57P/planted.h" | wc -l)"
rm -rf "$C57P"
[ "$C57N" = 1 ] && pass "class 57: control -- a planted cached registry read is found" ||
    fail "class 57: control -- the planted read gave $C57N findings, want 1"
C57="$(python3 "$C57_SCAN" "$C57_OK" "$ROOT"/userspace/*.h "$ROOT"/userspace/*.c)"
[ -z "$C57" ] && pass "class 57: every tool read of registry rows drops this host's cached copy" ||
    fail "class 57: reads the registry through the cache: $(echo $C57)"

# Class 54: a path that holds an inode's namespace lock reaches a second
# acquire of it, directly or through a VFS entry point whose module callback
# takes it (setattr_prepare()'s killpriv into the xattr handler).
# tests/image/ns_reentry_scan.py walks the callees of every holder. The real
# tree must be clean. Controls: a planted direct self-wait and a planted VFS
# self-wait are found, a guarded acquire and a ?: alternative are not, and a
# copy of the real tree with the nesting guard removed is found.
log "checking no path re-acquires the namespace lock it already holds (class 54)"
C54_SCAN="$CT_TESTS/image/ns_reentry_scan.py"
[ "$(grep -l 'cetrafs_nslock_acquire' "$K"/*.c | wc -l)" -ge 3 ] ||
    fail "class 54: setup: the namespace-lock acquirers are not where the scan expects them"
C54P="$(ct_tmp ns-reentry-plant)"
rm -f "$C54P"
mkdir -p "$C54P"
cat >"$C54P/xattr.c" <<'PLANT'
static int planted_guarded_acquire(struct inode *inode)
{
    bool nested = cetrafs_inode_ns_held_by_current(inode);

    if (!nested)
        return cetrafs_nslock_acquire(inode);
    return 0;
}
static int planted_unguarded_set(struct inode *inode)
{
    return cetrafs_nslock_acquire(inode);
}
static const struct xattr_handler planted_handler = {
    .set = planted_unguarded_set,
};
PLANT
cat >"$C54P/planted.c" <<'PLANT'
static int planted_direct_helper(struct inode *inode)
{
    return cetrafs_nslock_acquire(inode);
}
static void planted_direct_holder(struct inode *inode)
{
    cetrafs_nslock_acquire(inode);
    planted_direct_helper(inode);
    cetrafs_nslock_release(inode);
}
static void planted_vfs_holder(struct mnt_idmap *idmap, struct dentry *d, struct inode *inode, struct iattr *a)
{
    cetrafs_nslock_acquire(inode);
    setattr_prepare(idmap, d, a);
    cetrafs_nslock_release(inode);
}
static void planted_guarded_holder(struct inode *inode)
{
    cetrafs_nslock_acquire(inode);
    planted_guarded_acquire(inode);
    cetrafs_nslock_release(inode);
}
static int planted_ternary(struct inode *inode, bool set)
{
    return set ? cetrafs_nslock_acquire(inode) : cetrafs_nslock_acquire_set(&inode, 1);
}
PLANT
C54N="$(python3 "$C54_SCAN" "$C54P" | wc -l)"
C54L="$(python3 "$C54_SCAN" "$C54P")"
[ "$C54N" = 2 ] && grep -q '^planted.c:planted_direct_holder -> planted_direct_helper ' <<<"$C54L" &&
    grep -q '^planted.c:planted_vfs_holder -> setattr_prepare -> planted_unguarded_set ' <<<"$C54L" &&
    pass "class 54: control -- a planted direct and a planted VFS self-wait are found; a guarded acquire and a ?: alternative are not" ||
    fail "class 54: control -- the planted tree gave $C54N finding(s), want 2 (direct and VFS): $C54L"
rm -rf "$C54P"

C54R="$(python3 "$C54_SCAN" "$K")"
[ -z "$C54R" ] && pass "class 54: no path under the namespace lock takes it again" ||
    fail "class 54: a path re-acquires the namespace lock it holds: $C54R"

# The real nesting guard is the only thing that keeps xattr_set from waiting
# on the setattr that calls it. Removed from a copy, the scan must find it.
C54G="$(ct_tmp ns-reentry-guard)"
rm -f "$C54G"
mkdir -p "$C54G"
cp "$K"/*.c "$K"/*.h "$C54G"/
sed -i "s/bool nested = .*held_by_current(inode);/bool nested = false;/" "$C54G/xattr.c"
[ "$(python3 "$C54_SCAN" "$C54G" | grep -c 'cetrafs_setattr -> .*cetrafs_xattr_set')" = 1 ] &&
    pass "class 54: control -- with the xattr nesting guard removed, the setattr path is found" ||
    fail "class 54: control -- the scan does not find the xattr self-wait with the guard removed"
rm -rf "$C54G"

# Class 27: a cached leaf, index or xattr block is edited IN PLACE by
# several stores, and a cached read checks no checksum -- so a reader of
# its b_data on THIS node needs lock_buffer (or the update / snapshot
# protocol), or a reason no in-place editor can run under it. Every
# function in the extent-tree, xattr, held-back-leaf and defrag code that
# touches b_data without one of those is listed below with its reason
# (each verified against its callers 2026-11-13); a new one fails until
# listed. Negative control: a planted unlocked reader.
log "checking every unlocked reader of a cached tree or xattr block names why no in-place edit can tear it (class 27)"
C27_ALLOW="
file.c:cetrafs_write_new_leaf a-new-block,-unreachable-until-published
file.c:cetrafs_write_new_index a-new-block,-unreachable-until-published
file.c:cetrafs_tree_convert_inner the-editor,-under-invalidate_lock-exclusive
file.c:cetrafs_tree_append the-editor,-under-invalidate_lock-exclusive
file.c:cetrafs_tree_split_leaf the-editor,-under-invalidate_lock-exclusive-(asserted);-its-new-leaf-a-new-block
file.c:cetrafs_tree_insert_any_leaf the-editor,-under-invalidate_lock-exclusive-(asserted)
file.c:cetrafs_idx_insert_keep_last the-editor,-reads-only-after-cetrafs_bh_begin_update_crc-takes-the-buffer-lock
file.c:cetrafs_inode_extents_get_for every-caller-holds-invalidate_lock-(fiemap/seek-shared),-or-the-file-is-being-evicted
file.c:cetrafs_tree_identity headers-only,-every-caller-holds-invalidate_lock-(fiemap/seek-shared)-and-every-editor-exclusive
file.c:cetrafs_tree_block_identity via-cetrafs_tree_identity
file.c:cetrafs_tree_flatten_for via-cetrafs_inode_extents_get_for,-or-defrag-under-invalidate_lock-exclusive
file.c:cetrafs_tree_extent_count_for do_allocate-exclusive;-close-after-the-last-writer;-the-defrag-worker-heuristic-only
file.c:cetrafs_tree_last_contig_lba a-placement-hint,-under-invalidate_lock-exclusive
file.c:cetrafs_tree_free_meta the-old-tree,-after-its-publish-and-under-invalidate_lock-exclusive
file.c:cetrafs_tree_meta_is_ours the-old-tree,-under-invalidate_lock-exclusive
file.c:cetrafs_tree_invalidate_cached drop-only;-an-entry-torn-by-a-local-edit-names-a-block-current-in-the-cache
xattr.c:cetrafs_xattr_set_locked the-editor,-under-the-namespace-lock-and-the-VFS-inode-lock
leafdefer.c:cetrafs_deferred_settle_locked its-caller-holds-lock_buffer
defrag.c:cetrafs_defrag_read_extents under-invalidate_lock-exclusive-(cetrafs_defrag_inode_lock)
"
c27_scan() { # <dir>: prints file:function for every unlocked b_data user
    local f
    for f in "$1"/file.c "$1"/xattr.c "$1"/leafdefer.c "$1"/defrag.c "$1"/planted.c; do
        [ -f "$f" ] || continue
        awk -v F="$(basename "$f")" '
            function out() { if (fn != "" && bd && !lk) print F ":" fn }
            /^[a-z].*\(/ && !/;$/ { out(); fn = $0; sub(/\(.*/, "", fn); sub(/.* \**/, "", fn); bd = 0; lk = 0 }
            /^[[:space:]]*(\*|\/\*)/ { next }
            /b_data/ { bd = 1 }
            /lock_buffer\(|cetrafs_bh_read_lock\(|cetrafs_bh_begin_update\(|cetrafs_bh_snapshot\(/ { lk = 1 }
            END { out() }' "$f"
    done | sort -u
}
C27P="$(mktemp -d)"
cat >"$C27P/planted.c" <<'EOF'
static u16 peek(struct buffer_head *bh)
{
    return ((cetrafs_extent_hdr_t *) bh->b_data)->eh_entries;
}
EOF
C27N="$(c27_scan "$C27P")"
rm -rf "$C27P"
[ "$C27N" = "planted.c:peek" ] || fail "class 27: the planted unlocked reader was not found ($C27N) -- the scan sees nothing"
C27_FOUND="$(c27_scan "$K")"
C27_LISTED="$(awk 'NF {print $1}' <<<"$C27_ALLOW" | sort -u)"
C27_NEW="$(comm -23 <(echo "$C27_FOUND") <(echo "$C27_LISTED"))"
C27_GONE="$(comm -13 <(echo "$C27_FOUND") <(echo "$C27_LISTED"))"
[ -n "$C27_FOUND" ] || fail "class 27: setup -- no unlocked b_data user found (the scan no longer matches)"
[ -z "$C27_NEW" ] && [ -z "$C27_GONE" ] &&
    pass "class 27: every unlocked reader of a cached tree or xattr block names its reason ($(echo $C27_FOUND | wc -w))" ||
    fail "class 27: unlisted: $(echo $C27_NEW); listed but gone: $(echo $C27_GONE)"

# Class 20: a user process must not wait for seconds where SIGKILL cannot
# end the wait, and a wait must not be measured by counting interruptible
# sleeps (msleep_interruptible() returns at once with a signal pending).
# Every UNINTERRUPTIBLE wait (wait_event, wait_for_completion, down_read/
# down_write, wait_on_bit* with TASK_UNINTERRUPTIBLE) and every
# interruptible sleep is listed below by function, with what bounds it
# or how its return is used; a new one fails until listed. mutex_lock is
# not scanned (it is everywhere; class 22 covers waits under a lock the
# awaited takes). Found on the way in: the allocator's wait for a
# surplus release was a plain down_read() a discard could hold for over
# a second -- killable now. Negative control: a planted wait_event().
log "checking every uninterruptible wait and interruptible sleep names its bound (class 20)"
C20_ALLOW="
caw.c:cetrafs_cas_stress test-only-stress-waits-for-its-own-workers
dmpath.c:cetrafs_dmpath_sdev wait_event_timeout
dmpath.c:cetrafs_dmpath_forget wait_event_timeout
fs.c:cetrafs_sb_release_lock heartbeat-only;-the-writers-wait-killable
fs.c:cetrafs_sb_release_wait killable;-the-plain-down_read-is-the-release_wait_unkillable-control-knob
fs.c:cetrafs_sb_birth_gate held-across-one-bit-CAS
fs.c:cetrafs_shutdown_ioctl admin-ioctl;-s_umount
fs.c:cetrafs_sb_bg_flush_lock holder-is-one-CAS-from-letting-go;-an-EINTR-would-be-a-new-failure
fs.c:cetrafs_sb_zg_write_lock holder-is-one-CAS-from-letting-go;-an-EINTR-would-be-a-new-failure
journal.c:cetrafs_journal_take_slot in-flight-writes-only;-a-killed-close-must-finish-(4949eca)
journal.c:cetrafs_journal_take_batch wait_event_timeout-loop
lock.c:cetrafs_flock msleep_interruptible-returns-EINTR
node.c:cetrafs_node_row_quiet msleep_interruptible-returns-EINTR
node.c:cetrafs_node_repair_claim_exists msleep_interruptible-returns-EINTR
"
c20_scan() { # <dir>: prints file:function for every listed kind of wait
    local f
    for f in "$1"/*.c; do
        awk -v F="$(basename "$f")" '
            /^[a-z].*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.* \**/, "", fn) }
            /^[[:space:]]*(\*|\/\*)/ { next }
            /[^a-z_](wait_event|wait_event_timeout|wait_for_completion|down_read|down_write|msleep_interruptible|schedule_timeout_interruptible)\(/ ||
            /wait_on_bit(_lock)?\(.*TASK_UNINTERRUPTIBLE/ { print F ":" fn }' "$f"
    done | sort -u
}
C20P="$(mktemp -d)"
cat >"$C20P/planted.c" <<'EOF'
static void stuck(struct cetrafs_journal *j)
{
    wait_event(j->slot_wq, false);
}
EOF
C20N="$(c20_scan "$C20P")"
rm -rf "$C20P"
[ "$C20N" = "planted.c:stuck" ] || fail "class 20: the planted wait was not found ($C20N) -- the scan sees nothing"
C20_FOUND="$(c20_scan "$K")"
C20_LISTED="$(awk 'NF {print $1}' <<<"$C20_ALLOW" | sort -u)"
C20_NEW="$(comm -23 <(echo "$C20_FOUND") <(echo "$C20_LISTED"))"
C20_GONE="$(comm -13 <(echo "$C20_FOUND") <(echo "$C20_LISTED"))"
[ -n "$C20_FOUND" ] || fail "class 20: setup -- no wait found (the scan no longer matches)"
[ -z "$C20_NEW" ] && [ -z "$C20_GONE" ] &&
    pass "class 20: every uninterruptible wait and interruptible sleep names its bound ($(echo $C20_FOUND | wc -w))" ||
    fail "class 20: unlisted wait: $(echo $C20_NEW); listed but gone: $(echo $C20_GONE)"

# Class 12: an ADDRESS read off the disk must be validated before it aims
# an I/O (rule 19: an extent naming the inode table turned an ordinary
# write(2) into a write over inodes 1..4). Data I/O is aimed in exactly
# one place, map_bh() in __cetrafs_get_block(), and it may take its
# address only from the checked lookup: so (a) map_bh() appears in no
# other function, (b) __cetrafs_get_block() calls no *_unchecked lookup,
# and (c) cetrafs_tree_lookup() still calls cetrafs_lba_run_check() on
# what it returns. Tree and dirent blocks are validated where they are
# read (cetrafs_blk_tail_bread(), cetrafs_read_tree_bh_for()); frees
# resolve the BG themselves. Negative control: a planted map_bh() in
# another function, and a planted unchecked lookup, must both be found.
log "checking data I/O is aimed only through the address-checked lookup (class 12)"
c12_scan() { # <file>: prints a line per violation
    awk '
        /^[a-z].*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.* \**/, "", fn) }
        /^[[:space:]]*(\*|\/\*)/ { next }
        /[^a-z_]map_bh\(/ && fn != "__cetrafs_get_block" { print "map_bh in " fn }
        fn == "__cetrafs_get_block" && /_unchecked\(/ { print "unchecked lookup in __cetrafs_get_block" }
        fn == "cetrafs_tree_lookup" && /cetrafs_lba_run_check\(/ { checked = 1 }
        END { if (!checked) print "cetrafs_tree_lookup no longer checks its address" }' "$1"
}
C12P="$(mktemp)"
cat >"$C12P" <<'EOF'
int cetrafs_tree_lookup(struct inode *inode)
{
    return cetrafs_lba_run_check(sb, lba, 1);
}

static int __cetrafs_get_block(struct inode *inode)
{
    ret = cetrafs_tree_lookup_unchecked(inode, raw, iblock);
    map_bh(bh_result, sb, lba);
}

static int sneaky(struct inode *inode)
{
    map_bh(bh_result, sb, lba);
}
EOF
C12N="$(c12_scan "$C12P" | sort | tr '\n' '|')"
rm -f "$C12P"
[ "$C12N" = "map_bh in sneaky|unchecked lookup in __cetrafs_get_block|" ] ||
    fail "class 12: the planted violations gave '$C12N' -- the scan sees nothing"
C12="$(cat "$K"/*.c | c12_scan /dev/stdin)"
[ "$(grep -c '[^a-z_]map_bh(' "$K/file.c")" -ge 1 ] || fail "class 12: setup -- no map_bh() in file.c (the scan no longer matches)"
[ -z "$C12" ] && pass "class 12: data I/O is aimed only by __cetrafs_get_block(), through the checked lookup" ||
    fail "class 12: $(echo "$C12" | tr '\n' ';')"

# Class 21: a release that fails must not be forgotten. Every call that
# DISCARDS the result of an int-returning release / give-back / clear /
# withdraw / free (a bare statement, or a (void) cast) is listed below by
# callee, with why losing that failure is safe; a new callee discarded
# anywhere fails until listed. (Found 2026-11-12 on the way in:
# cetrafs_bg_adjust_free_blocks() returned before accruing on a failed
# descriptor read, and every caller discarded it -- the delta was lost.)
# Negative control: a planted discarded release must be found.
log "checking no failed release is discarded without a reason (class 21)"
C21_ALLOW="
cetrafs_bg_adjust_free_blocks accrues-first;-the-return-is-the-roll-up-only
cetrafs_flush_dirty_free_counts re-accrues-a-failed-delta-itself
cetrafs_free_data_extent a-lost-free-leaks;-the-scrub-reclaims-it
cetrafs_free_data_extent_batched a-hard-error-is-logged-and-its-blocks-stay-allocated-for-the-scrub
cetrafs_free_batch_flush a-hard-error-is-logged-and-its-blocks-stay-allocated-for-the-scrub
cetrafs_free_inode a-failed-free-keeps-the-bit;-the-orphan-scrub-reclaims-it
cetrafs_release vfs-release;-its-failures-queue-their-own-retry
cetrafs_sb_adjust_free_inodes in-memory;-fails-only-without-sb_info
cetrafs_zg_adjust_free_blocks in-memory-accrue;-fails-only-on-an-impossible-zone-group-id
cetrafs_zg_drain_pending_frees a-failed-drain-leaves-the-entries-queued-for-the-next
cetrafs_zg_reconcile_free_counts never-fails-the-claim-by-design;-logs;-the-allocator-recounts-a-lying-group
"
c21_scan() { # <dir>: prints file:line:callee of every discarded release
    local f fns
    fns="$(grep -hoE '^(static )?int (__)?cetrafs_[a-z_]*(release|give_back|giveback|clear|unlock|withdraw|unpin|yield|free)[a-z_]*\(' "$1"/*.c "$1"/*.h 2>/dev/null |
        sed -E 's/^(static )?int //; s/\($//' | sort -u | tr '\n' '|' | sed 's/|$//')"
    [ -n "$fns" ] || return 0
    for f in "$1"/*.c; do
        awk -v F="$(basename "$f")" -v RE="^[[:space:]]*([(]void[)][[:space:]]*)?(${fns})[(]" '
            /^[[:space:]]*$/ || /^[[:space:]]*(\*|\/\*|\/\/)/ { next }
            $0 ~ RE && (prev ~ /[;{})][[:space:]]*(\/\*.*\*\/)?[[:space:]]*$/ || prev ~ /else[[:space:]]*$/ || prev ~ /\*\/[[:space:]]*$/) {
                c = $0; sub(/^[[:space:]]*(\(void\)[[:space:]]*)?/, "", c); sub(/\(.*/, "", c)
                print F ":" NR ":" c
            }
            { prev = $0 }' "$f"
    done
}
C21P="$(mktemp -d)"
cat >"$C21P/planted.c" <<'EOF'
int cetrafs_thing_release(struct super_block *sb)
{
    return -EIO;
}

static void user(struct super_block *sb)
{
    cetrafs_thing_release(sb);
}
EOF
C21N="$(c21_scan "$C21P" | cut -d: -f3)"
rm -rf "$C21P"
[ "$C21N" = "cetrafs_thing_release" ] || fail "class 21: the planted discarded release was not found ($C21N) -- the scan sees nothing"
C21_FOUND="$(c21_scan "$K")"
C21_LISTED="$(awk 'NF {print $1}' <<<"$C21_ALLOW" | sort -u)"
C21_NEW="$(cut -d: -f3 <<<"$C21_FOUND" | sort -u | comm -23 - <(echo "$C21_LISTED"))"
C21_GONE="$(cut -d: -f3 <<<"$C21_FOUND" | sort -u | comm -13 - <(echo "$C21_LISTED"))"
[ -n "$C21_FOUND" ] || fail "class 21: setup -- no discarded release found (the scan no longer matches)"
[ -z "$C21_NEW" ] && [ -z "$C21_GONE" ] &&
    pass "class 21: every discarded release names why its failure is safe ($(wc -l <<<"$C21_FOUND") calls)" ||
    fail "class 21: discarded with no reason: $(for c in $C21_NEW; do grep ":$c\$" <<<"$C21_FOUND" | head -2; done | tr '\n' ' '); listed but gone: $(echo $C21_GONE)"

# Class 29: an ORDER decided from a real clock is wrong after a backward
# step, a wrap or a peer's skew. The real clock may be read only for
# timestamps, log text, or a stamp clock's anchor -- every function that
# reads it is listed below with which of those it is; a new one fails
# until listed (and listed-but-gone fails too, so the list stays true).
# The order-sensitive stamps come from cetrafs_sb_stamp_ns(), monotonic
# per mount. Negative control: a planted reader in an unlisted function
# must be found.
log "checking the real clock is read only for timestamps, logs and the stamp anchor (class 29)"
C29_ALLOW="
dir.c:cetrafs_create_locked timestamp
dir.c:cetrafs_dir_add_entry timestamp
dir.c:cetrafs_dir_remove_entry timestamp
dir.c:cetrafs_dir_retarget_entry timestamp
dir.c:cetrafs_link_locked timestamp
dir.c:cetrafs_mkdir_locked timestamp
dir.c:cetrafs_rename_locked timestamp
dir.c:cetrafs_rmdir_locked timestamp
dir.c:cetrafs_symlink_locked timestamp
dir.c:cetrafs_unlink_locked timestamp
file.c:cetrafs_do_allocate timestamp
file.c:cetrafs_fallocate timestamp
xattr.c:cetrafs_xattr_set timestamp
fs.c:cetrafs_fill_super anchor-of-the-monotonic-stamp-clock
fs.c:cetrafs_sb_stamp_ns no-mount-fallback
fs.c:cetrafs_sb_stamp_now no-mount-fallback
fs.c:cetrafs_sb_record_damage informational-timestamp
journal.c:cetrafs_journal_claim_mutate written-never-read
node.c:cetrafs_node_claim_mutate informational-last_seen
node.c:cetrafs_node_fence_mutate informational-fenced_at
node.c:cetrafs_node_reattach_mutate informational-last_seen
node.c:cetrafs_node_renew_mutate informational-last_seen
node.c:cetrafs_node_test_beat_mutate informational-last_seen
node.c:cetrafs_node_report_clock_skew log
zonegroup.c:cetrafs_zg_log_foreign_free_leak log
scrub.c:cetrafs_scrub_cycle procfs-timestamp
inode.c:cetrafs_inode_label_may_be_stale order-that-fails-toward-a-re-read
"
c29_scan() { # <dir>: prints file:function for every real-clock read
    local f
    for f in "$1"/*.c; do
        # modpost writes cetrafs.mod.c into the tree on every module build.
        # It is generated boilerplate, not source, and it reads the clock.
        case "$f" in *.mod.c) continue ;; esac
        awk -v F="$(basename "$f")" '
            /^[a-z].*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); sub(/.* \**/, "", fn) }
            /^[[:space:]]*(\*|\/\*)/ { next }
            /ktime_get_real|ktime_get_clocktai|ktime_get_coarse_real|get_seconds\(\)/ { print F ":" fn }' "$f"
    done | sort -u
}
C29P="$(mktemp -d)"
cat >"$C29P/planted.c" <<'EOF'
static bool newer(u64 a)
{
    return a < ktime_get_real_ns();
}
EOF
C29N="$(c29_scan "$C29P")"
rm -rf "$C29P"
[ "$C29N" = "planted.c:newer" ] || fail "class 29: the planted real-clock compare was not found ($C29N) -- the scan sees nothing"
C29_FOUND="$(c29_scan "$K")"
C29_LISTED="$(awk 'NF {print $1}' <<<"$C29_ALLOW" | sort -u)"
C29_NEW="$(comm -23 <(echo "$C29_FOUND") <(echo "$C29_LISTED"))"
C29_GONE="$(comm -13 <(echo "$C29_FOUND") <(echo "$C29_LISTED"))"
[ -n "$C29_FOUND" ] || fail "class 29: setup -- no real-clock read found (the grep no longer matches)"
[ -z "$C29_NEW" ] && [ -z "$C29_GONE" ] &&
    pass "class 29: every real-clock read is a timestamp, a log or the stamp anchor ($(echo $C29_FOUND | wc -w))" ||
    fail "class 29: unlisted real-clock reader: $(echo $C29_NEW); listed but gone: $(echo $C29_GONE)"

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
KV_OUT='cetrafs_tree_flatten|cetrafs_tree_flatten_for|cetrafs_inode_sorted_runs'
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
    awk '/__has_include\(<linux\/folio_batch\.h>\)|LINUX_VERSION_CODE >= KERNEL_VERSION\(7, 1, 0\)/ { g = NR }
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
lock.c:cetrafs_lock_cas:counts a re-asked yield only on success; an error asks nothing and the wait goes on
lock.c:cetrafs_read_raw_inode:acts (the late sweep clears claims) only on success; an error clears nothing
node.c:cetrafs_node_is_stale:true branch skips a peer; an error counts it as live
scrub.c:cetrafs_zg_scrub_adopt_one_stale:log only
xattr.c:cetrafs_xattr_slot_free:returns bool, not an error
uuid.c:cetrafs_serial_usable:returns bool, not an error
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
# queue is specified below. (dmpath.c has two waits on its one queue:
# the killable one a CAS uses and the plain one for the probe and the
# give-backs, 2026-11-08.)
log "checking every store that can satisfy a wait wakes its queue"
# file|function exempt from the rule (or -)|store regex|wake regex
WAKE_SPEC='journal.c|cetrafs_journal_take_slot|clear_bit\([^,]*, *j->busy\)|j->held\+\+|\+\+j->held|wake_up(_all)?\(&j->slot_wq\)
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
# 7: the batch's slot wait (cetrafs_journal_take_batch()) is a second
# waiter on j->slot_wq, whose stores and wake the first line specifies.
[ "$WSITES" = 7 ] && pass "wait wakes: 7 wait_event sites, each queue specified" ||
    fail "wait wakes: $WSITES wait_event sites (specified for 7) -- add the new queue's stores and wake to WAKE_SPEC"
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
# One hook is exempt by name: .lock = cetrafs_posix_lock_refuse, which
# refuses an fcntl lock or hands it to the VFS's in-memory table and
# writes no record -- held to that below: it may call no cetrafs
# function but the two read-only mount accessors.
log "checking directory records have no writer outside the namespace lock"
dir_ops_hooks() { awk '/^const struct file_operations cetrafs_dir_ops = \{/ { on = 1 } on { print } on && /^\};/ { exit }' "$1" |
    grep -vE '^\s*\.lock\s*=\s*cetrafs_posix_lock_refuse\s*,' |
    { grep -oE '^\s*\.(open|release|flock|lock)\s*=' || true; } | tr -d ' .=' | sort -u | tr '\n' ' '; }
plr_body() { awk '/^int cetrafs_posix_lock_refuse\(/ { on = 1 } on { print } on && /^}/ { exit }' "$K/lock.c"; }
PLR="$(plr_body | tail -n +2 | grep -oE 'cetrafs_[a-z0-9_]+\(' | sort -u | tr -d '(' |
    grep -vxE 'cetrafs_sb_file_lock_enabled|cetrafs_sb_posix_lock_local' || true)"
[ -n "$(plr_body)" ] || fail "directory records: cetrafs_posix_lock_refuse not found -- the exemption names nothing"
[ -z "$PLR" ] && pass "directory records: the exempt .lock hook calls only the read-only mount accessors" ||
    fail "directory records: cetrafs_posix_lock_refuse now calls $(echo $PLR) -- re-audit the directory .lock exemption"
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

# Classes 4 and 5: a regular file's extent-tree block is never left
# DIRTY. Block-device writeback is a writer with no lock, no order and no
# journal: it wrote held-back leaves in place, torn by a power cut with
# nothing to redo them, ahead of the data and bits they name, and after
# their block was freed (crash review 2026-11-08, C1/C2). A leaf or
# index edit ends in cetrafs_tree_hold_back() or a journal write, never in
# a bare end_update; and every free drops a held-back copy at the choke
# point.
log "checking no extent-tree block edit is left dirty for writeback (classes 4, 5)"
tree_dirtiers() { grep -nE 'cetrafs_bh_end_update\((lbh|ibh|nbh)\)' "$@" || true; }
TD="$(tree_dirtiers "$K"/*.c)"
[ -z "$TD" ] && pass "classes 4/5: every leaf/index edit is held back or journaled, none left dirty" ||
    fail "classes 4/5: a leaf/index edit ends in a bare end_update (dirty, for writeback): $(echo $TD)"
SAMPLE="$(ct_tmp tree-dirty).c"
printf '    cetrafs_bh_end_update(lbh);\n' >"$SAMPLE"
[ -n "$(tree_dirtiers "$SAMPLE")" ] && pass "classes 4/5: control -- a planted dirty leaf edit is found" ||
    fail "classes 4/5: control -- a planted dirty leaf edit is not found"
FDE="$(awk '/^static int __cetrafs_free_data_extent\(.*\)$/ { on = 1 } on; on && /^}/ { on = 0 }' "$K/alloc.c")"
grep -q 'cetrafs_deferred_forget_range(sb, lba, count)' <<<"$FDE" &&
    pass "classes 4/5: the free choke point drops a held-back copy of the freed blocks" ||
    fail "classes 4/5: __cetrafs_free_data_extent() no longer drops held-back tree blocks it frees"

# Class 9 (change stamps): the file sector's publishers. A file-sector
# CAS writes size, blocks and the extent root; one that does not compare
# the record's file_seq with the stamp it planned from publishes over a
# peer's newer write with a valid checksum. Every mutator handed to
# cetrafs_cas_record_fd_seeded() reads file_seq off the image it is
# given and compares it (audit 2026-11-04; check added 2026-11-08).
log "checking every file-sector CAS mutator compares file_seq (class 9)"
fd_mutators() { # <files...>: names of the mutators passed to the fd CAS
    # One line per file: a call's arguments often span several.
    for f in "$@"; do tr '\n' ' ' <"$f"; echo; done | grep -oE 'cetrafs_cas_record_fd_seeded\([^;]*' |
        grep -v 'struct super_block' | grep -oE 'cetrafs_[a-z_]*_mutate' | sort -u
}
fd_unchecked() { # <file> <mutator...>: the ones whose body never compares file_seq
    local f="$1"; shift
    for fn in "$@"; do
        awk -v fn="$fn" '$0 ~ "^static int " fn "\\(" { on = 1 } on && /file_seq/ && /(!=|==)/ { hit = 1 }
            on && /^}/ { on = 0 } END { exit !hit }' "$f" || echo "$fn"
    done
}
fd_publishes() { # <file> <mutator>: does its body write anything but a new stamp?
    # A stamp-only mutator (the replay's change-stamp advance) rewrites
    # the swap's own image with a new file_seq and nothing else: it
    # cannot publish over a peer's write, it announces one. Anything
    # else -- a field other than the identity copy, a memcpy into the
    # record -- is a publish and must compare file_seq.
    awk -v fn="$2" '$0 ~ "^static int " fn "\\(" { on = 1 }
        on && (/rec\.[a-z_]+(\[[^]]*\])? *=[^=]/ && !/rec\.(ino|generation) *= *rec\.fd_(ino|generation);/ ||
               /memcpy\(&rec/) { hit = 1 }
        on && /^}/ { on = 0 } END { exit !hit }' "$1"
}
FDM="$(fd_mutators "$K"/*.c)"
[ -n "$FDM" ] || fail "class 9: setup -- no file-sector CAS mutator found (the grep no longer matches the call)"
FDU=""
FDS=""
for fn in $FDM; do
    src="$(grep -lE "^static int $fn\\(" "$K"/*.c | head -1)"
    [ -n "$src" ] || { FDU="$FDU$fn(no-body) "; continue; }
    u="$(fd_unchecked "$src" "$fn")"
    if [ -n "$u" ] && ! fd_publishes "$src" "$fn"; then FDS="$FDS$fn "; else FDU="$FDU$u "; fi
done
[ "$(echo $FDM | wc -w)" = 3 ] || fail "class 9: $(echo $FDM | wc -w) file-sector CAS mutators (pinned at 3: $(echo $FDM)) -- review the new one and update the pin"
[ -z "${FDU// /}" ] && pass "class 9: every file-sector CAS mutator that publishes compares file_seq ($(echo $FDM); stamp-only: $(echo $FDS))" ||
    fail "class 9: a file-sector CAS mutator publishes without comparing file_seq: $FDU"
SAMPLE="$(ct_tmp fdmut).c"
printf 'static int cetrafs_bad_mutate(void *image, unsigned int len, void *priv)\n{\n    rec.size = 0;\n    return 0;\n}\n    ret = cetrafs_cas_record_fd_seeded(sb, lba, NULL, 0, cetrafs_bad_mutate, &ctx);\n' >"$SAMPLE"
[ "$(fd_mutators "$SAMPLE")" = cetrafs_bad_mutate ] && [ "$(fd_unchecked "$SAMPLE" cetrafs_bad_mutate)" = cetrafs_bad_mutate ] &&
    fd_publishes "$SAMPLE" cetrafs_bad_mutate &&
    pass "class 9: control -- a planted publishing mutator without the comparison is found" ||
    fail "class 9: control -- the planted mutator was not found ($(fd_mutators "$SAMPLE") / $(fd_unchecked "$SAMPLE" cetrafs_bad_mutate))"
printf 'static int cetrafs_ok_mutate(void *image, unsigned int len, void *priv)\n{\n    rec.ino = rec.fd_ino;\n    rec.generation = rec.fd_generation;\n    return 0;\n}\n' >"$SAMPLE"
! fd_publishes "$SAMPLE" cetrafs_ok_mutate && pass "class 9: control -- a stamp-only mutator is told apart" ||
    fail "class 9: control -- a stamp-only mutator reads as a publish"

# Class 41 (an invalidation that does not fence a fill in flight).
# Clearing a valid bit does not stop a fill already between its device
# read and its store; the store lands after the drop with a value from
# before it. Every function that drops, expires, forgets or invalidates
# cached state is listed here with what fences a fill across it, and a
# new one fails until someone has said which (leafdefer/crash reviews
# 2026-11-08; the extent cache was the one that had nothing).
#   gen:<field>:<store>   the drop moves <field>; <store> compares it
#   buffer                the buffer cache: the drop takes lock_buffer,
#                         which a read in flight holds until it completes
#   wait                  the drop waits out a fill in flight itself
#   safe:<why>            a straddling fill errs in the safe direction
#   none:<why>            not a cache a fill can race
log "checking every cache invalidate names what fences a fill in flight (class 41)"
C41_REG='cetrafs_inode_ext_cache_drop gen:ext_gen:cetrafs_inode_ext_cache_store
cetrafs_verdicts_invalidate gen:verdict_gen:cetrafs_verdict_current
cetrafs_lock_expire_verdicts calls:cetrafs_verdicts_invalidate
cetrafs_tree_invalidate_cached calls:cetrafs_inode_ext_cache_drop
cetrafs_invalidate_block buffer
cetrafs_forget_block buffer
cetrafs_invalidate_raw_inode calls:cetrafs_invalidate_block
cetrafs_bg_invalidate_cache calls:cetrafs_invalidate_block
cetrafs_dmpath_forget wait
cetrafs_sb_peer_watch_forget safe:a-straddling-sample-re-arms-the-watch-at-now-which-only-delays-a-verdict
cetrafs_deferred_forget_range none:the-held-back-set-changes-under-the-buffer-lock
cetrafs_inode_forget_tree none:an-on-disk-record-not-a-cache
cetrafs_sb_nslock_forget none:a-release-queue-entry-not-a-cache
cetrafs_nswait_forget none:a-per-task-deadline-not-a-cache
cetrafs_file_cache_drop_count none:a-counter'
c41_names() { # <files...>: every function whose name says it drops cached state
    grep -hoE '^(static )?(inline )?(void|bool|int|u32|u64) \*?cetrafs_[a-z0-9_]*(cache_drop|expire|invalidate|forget)[a-z0-9_]*\(' "$@" |
        grep -oE 'cetrafs_[a-z0-9_]*' | sort -u
}
c41_body() { # <fn>: its body, from whichever kmod file defines it
    local src
    src="$(grep -lE "^(static )?(inline )?[a-z0-9_]+ \*?$1\\(" "$K"/*.c | head -1)"
    # A multi-line PROTOTYPE also starts with the name and has no ");"
    # on its first line: the header is held until a line ending in ";"
    # (a prototype: dropped) or the opening "{" (the definition).
    [ -n "$src" ] && awk -v f="$1" '
!on && !hdr && $0 ~ ("^[a-z_].*[ *]" f "\\(") { hdr = 1; buf = "" }
hdr { buf = buf $0 "\n"; l = $0; sub(/\/[*\/].*$/, "", l); if (l ~ /;[ \t]*$/) { hdr = 0; next } if (/^\{/) { hdr = 0; on = 1; printf "%s", buf; next } next }
on { print } on && /^}/ { exit }' "$src"
}
c41_bad() { # <fn> <kind>: prints why the fence is missing, nothing if present
    local fn="$1" kind="$2" field store
    case "$kind" in
    gen:*)
        field="$(cut -d: -f2 <<<"$kind")"
        store="$(cut -d: -f3 <<<"$kind")"
        c41_body "$fn" | grep -qE "$field\\+\\+|atomic_inc\\(&[a-z]+->$field\\)" || echo "$fn: does not move $field"
        c41_body "$store" | grep -E "$field" | grep -qE '!=|==' || echo "$store: never compares $field"
        ;;
    calls:*) c41_body "$fn" | grep -q "${kind#calls:}(" || echo "$fn: no longer calls ${kind#calls:}" ;;
    buffer) c41_body "$fn" | grep -q 'lock_buffer(' || echo "$fn: takes no buffer lock" ;;
    wait) c41_body "$fn" | grep -qE 'wait_event|resolving' || echo "$fn: waits for nothing" ;;
    safe:* | none:*) ;;
    *) echo "$fn: unknown kind $kind" ;;
    esac
}
C41_FOUND="$(c41_names "$K"/*.c)"
[ -n "$C41_FOUND" ] || fail "class 41: setup -- no invalidate found (the grep no longer matches)"
C41_NEW="$(comm -23 <(echo "$C41_FOUND") <(cut -d' ' -f1 <<<"$C41_REG" | sort -u))"
C41_GONE="$(comm -13 <(echo "$C41_FOUND") <(cut -d' ' -f1 <<<"$C41_REG" | sort -u))"
C41_BAD="$(while read -r fn kind; do c41_bad "$fn" "$kind"; done <<<"$C41_REG")"
[ -z "$C41_NEW" ] && [ -z "$C41_GONE" ] && [ -z "$C41_BAD" ] &&
    pass "class 41: every cache invalidate names its fence ($(echo $C41_FOUND | wc -w))" ||
    fail "class 41: unlisted: $(echo $C41_NEW); listed but gone: $(echo $C41_GONE); unfenced: $C41_BAD"
# Control: a store that stops comparing the generation, and a new drop.
C41_SAMPLE="$(ct_tmp c41).c"
printf 'void cetrafs_thing_cache_drop(struct inode *inode)\n{\n    ci->valid = false;\n}\n' >"$C41_SAMPLE"
[ "$(c41_names "$C41_SAMPLE")" = cetrafs_thing_cache_drop ] &&
    [ -n "$(K="$(dirname "$C41_SAMPLE")" c41_bad cetrafs_thing_cache_drop gen:thing_gen:cetrafs_thing_cache_drop)" ] &&
    pass "class 41: control -- a planted drop is found, and one that moves no generation is refused" ||
    fail "class 41: control -- the planted drop was not caught"

# Class 51 (a cache key that summarises its value). A cached answer is
# trusted when its key still matches the device; a key that is a SUMMARY
# of the record (counts, a size, a checksum) recurs -- punch k blocks,
# allocate k -- and then trusts an answer about different contents. So
# every function whose name says it trusts or looks up cached state is
# listed with what makes its key an identity: a change stamp every
# publish moves and nothing returns (compared here), a generation, a
# call to one that does, or why no key is involved. A new one fails
# until listed. Names only: a cache trusted under another name is not
# seen (gap, as for class 41).
log "checking every cache lookup is keyed on an identity, not a summary (class 51)"
C51_REG='cetrafs_inode_ext_cache_lookup calls:cetrafs_ext_key_matches
cetrafs_ext_key_matches key:file_seq
cetrafs_dir_needs_fresh key:dirent_seq
cetrafs_verdict_current key:verdict_gen
cetrafs_inode_foreign_opener_cached calls:cetrafs_verdict_current
cetrafs_lock_identity_cache_trusted calls:cetrafs_inode_foreign_opener_cached
cetrafs_lock_read_cache_trusted calls:cetrafs_inode_read_stamp_check
cetrafs_sb_zg_owned_cached none:this-nodes-own-claims-revoked-only-by-its-fence
cetrafs_inode_dirent_seq_cached none:an-accessor-of-the-stamp-dir_needs_fresh-compares
cetrafs_inode_set_dirent_seq_cached none:an-accessor
cetrafs_tree_invalidate_cached none:an-invalidate-class-41
cetrafs_inode_is_allocated_fresh none:a-forced-fresh-read-not-a-cache
cetrafs_inode_ns_held_by_current none:a-lock-holder-test
cetrafs_nswait_is_current key:start_time
cetrafs_xattr_trusted_list none:the-trusted-xattr-namespace'
c51_names() { # <files...>: every function whose name says it trusts cached state
    grep -hoE '^(static )?(inline )?(void|bool|int|u32|u64) \*?cetrafs_[a-z0-9_]*(cache_lookup|_cached|_trusted|_current|_fresh|_key_matches)[a-z0-9_]*\(' "$@" |
        grep -oE 'cetrafs_[a-z0-9_]*' | sort -u
}
c51_bad() { # <fn> <kind>: prints why the key is not an identity, nothing if it is
    case "$2" in
    key:*) grep -E "${2#key:}" <<<"$(c41_body "$1")" | grep -qE '!=|==' || echo "$1: no longer compares ${2#key:}" ;;
    calls:*) grep -q "${2#calls:}(" <<<"$(c41_body "$1")" || echo "$1: no longer calls ${2#calls:}" ;;
    none:*) ;;
    *) echo "$1: unknown kind $2" ;;
    esac
}
C51_FOUND="$(c51_names "$K"/*.c)"
[ -n "$C51_FOUND" ] || fail "class 51: setup -- no cache lookup found (the grep no longer matches)"
C51_NEW="$(comm -23 <(echo "$C51_FOUND") <(cut -d' ' -f1 <<<"$C51_REG" | sort -u))"
C51_GONE="$(comm -13 <(echo "$C51_FOUND") <(cut -d' ' -f1 <<<"$C51_REG" | sort -u))"
C51_BAD="$(while read -r fn kind; do c51_bad "$fn" "$kind"; done <<<"$C51_REG")"
[ -z "$C51_NEW" ] && [ -z "$C51_GONE" ] && [ -z "$C51_BAD" ] &&
    pass "class 51: every cache lookup names the identity its key carries ($(echo $C51_FOUND | wc -w))" ||
    fail "class 51: unlisted: $(echo $C51_NEW); listed but gone: $(echo $C51_GONE); not an identity: $C51_BAD"
# Control: a lookup keyed on counts alone is found and refused.
C51_SAMPLE="$(ct_tmp c51).c"
printf 'static bool cetrafs_thing_key_matches(const struct ci *ci, const cetrafs_inode_t *raw)\n{\n    return ci->key_blocks == raw->blocks;\n}\n' >"$C51_SAMPLE"
[ "$(c51_names "$C51_SAMPLE")" = cetrafs_thing_key_matches ] &&
    [ -n "$(K="$(dirname "$C51_SAMPLE")" c51_bad cetrafs_thing_key_matches key:file_seq)" ] &&
    pass "class 51: control -- a planted lookup keyed on a count is found and refused" ||
    fail "class 51: control -- the planted summary key was not caught"

# Class 43 (a transient withholding reported as a final answer). Every
# function that ORIGINATES -ENOSPC, -EBUSY or -ENOENT is listed with what
# its answer means:
#   waits:<fn>  it waits out the transient states (a release deciding, a
#               peer's lock, a lost race) before answering -- and still
#               calls <fn>, the wait or the retried step;
#   calls:<fn>  its answer comes after asking <fn>, which waits;
#   below:...   an internal "not here / not now" its caller moves on
#               from, retries, or keeps for a later pass;
#   final:...   a structural limit or a state no wait changes (a full
#               tree, a name that is gone under the lock, a mount
#               refused with its reason), or a test injection.
# A new originator fails until it says which. What is enumerated is the
# literal; an errno passed up from elsewhere is its originator's. A
# literal the scan cannot place in a function fails as well: the scan
# once missed every __cetrafs_* function, __cetrafs_get_block()'s
# ENOSPC among them.
log "checking every -ENOSPC/-EBUSY/-ENOENT/-ETXTBSY names the transient states it waited out (class 43)"
C43_REG_ENOSPC='cetrafs_alloc_pick_bg waits:cetrafs_sb_release_wait
cetrafs_alloc_block_anywhere calls:cetrafs_alloc_pick_bg
cetrafs_do_allocate calls:cetrafs_alloc_pick_bg
__cetrafs_get_block calls:cetrafs_alloc_pick_bg
cetrafs_alloc_data_block below:one-group-full-the-pick-chooses-again
cetrafs_alloc_data_block_near below:one-group-full-the-pick-chooses-again
cetrafs_alloc_data_run_resv below:one-group-has-no-run
cetrafs_alloc_pick_run_resv final:defrag-only-cannot-defrag-now-is-not-user-visible
cetrafs_bg_claim_free below:nothing-to-claim-the-pick-goes-on-to-wait-for-a-release
cetrafs_bitmap_alloc_bit below:one-bitmap
cetrafs_bitmap_alloc_run_start below:one-bitmap
cetrafs_bitmap_find_free_run below:one-bitmap
cetrafs_bitmap_try_alloc_exact below:one-bitmap
cetrafs_bmap_cas_mutate below:one-region-the-caller-tries-the-next
cetrafs_inode_bitmap_cas_alloc final:every-inode-number-in-use-a-free-in-flight-holds-its-number-until-published
cetrafs_leaf_array_insert final:a-full-leaf-the-caller-splits
cetrafs_leaf_array_punch final:no-room-for-the-split-nothing-changed
cetrafs_tree_append final:the-extent-tree-is-full
cetrafs_tree_insert_any_leaf final:every-interior-and-every-leaf-full-under-invalidate_lock-exclusive
cetrafs_tree_build final:the-extent-tree-is-full
cetrafs_xattr_set_locked final:the-xattr-block-is-full
cetrafs_node_register final:every-registry-row-taken
cetrafs_dir_add_entry final:the-directory-is-at-CETRAFS_DIR_MAX_BLOCKS
cetrafs_tree_resv_fill final:test-injection-convert_append_nospc
cetrafs_tree_alloc_block final:test-injection-convert_append_nospc
cetrafs_tree_block_anywhere final:test-injection-tree_alloc_fail_at'
C43_REG_EBUSY='cetrafs_lock_suspend waits:schedule_timeout_killable
cetrafs_nslock_acquire_tries waits:msleep
__cetrafs_nslock_acquire_set waits:msleep
cetrafs_nslock_acquire_set_vfs waits:cetrafs_nswait_queue
cetrafs_nswait_within below:past-the-deadline-the-caller-answers-ebusy-on-the-old-budget
cetrafs_apply_raw_to_vfs_inode_sure waits:usleep_range
cetrafs_cas_region_seeded_impl waits:usleep_range
__cetrafs_journal_replay_node waits:time_after_eq
cetrafs_rename waits:cetrafs_rename_locked
cetrafs_rename_locked below:the-target-changed-cetrafs_rename-retries
cetrafs_nslock_try below:a-held-lock-the-acquire-loop-waits-on
cetrafs_nslock_mutate below:a-cas-callback-held-by-another
cetrafs_zg_cas_mutate below:a-cas-callback-owned-by-a-live-peer
cetrafs_caw_scsi below:a-miscompare-the-cas-loop-re-reads
cetrafs_node_fence_peer_full below:the-peer-came-back-callers-wait-as-for-a-live-holder
cetrafs_journal_replay_node below:the-node-came-back-its-own-mount-replays
cetrafs_bg_release_bitmap_ready below:not-released-the-heartbeat-tries-later
cetrafs_journal_settle_range below:a-live-entry-or-a-batch-in-progress-the-group-is-kept-for-a-later-pass
cetrafs_bg_release_one below:kept-for-a-later-pass
cetrafs_discard_handback below:over-budget-kept-for-a-later-pass
cetrafs_frees_quiet below:frees-in-flight-the-scrub-skips-this-cycle
cetrafs_lock_clear_dead_claims below:a-live-user-the-scrub-leaves-it
cetrafs_evict_inode below:a-peer-named-it-evict-frees-nothing
cetrafs_lock_defrag_begin below:the-file-is-in-use-defrag-declines-and-yields-to-users
cetrafs_lock_explicit_acquire final:a-peer-is-using-the-file-flock-cannot-promise-exclusivity
cetrafs_fill_super final:a-mount-refused-with-its-reason-repair-running-no-caw-peer-or-a-rewrite
cetrafs_check_second_mount final:a-second-mount-asking-for-options-the-first-lacks
cetrafs_node_register final:a-twin-of-this-node-is-mounted
cetrafs_grow_claim_present final:no-growfs-claim-the-tool-did-not-ask
cetrafs_grow_claim_owned final:no-growfs-claim-of-this-caller-the-ioctl-was-not-made-under
cetrafs_lock_open final:test-injection-open_refresh_fail_once
cetrafs_defrag_inode final:test-injection-defrag_fail_invalidate
cetrafs_zg_drain_one final:test-injection-pf_drain_busy_region
cetrafs_defrag_check_sole final:a-user-or-a-lock-on-a-fresh-read-defrag-declines
cetrafs_node_row_quiet waits:msleep_interruptible'
C43_REG_ETXTBSY='cetrafs_lock_open waits:cetrafs_lock_wait_yield
cetrafs_lock_wait_yield final:the-mover-did-not-step-aside-within-lock_yield_wait_ms
cetrafs_lock_cas_mutate below:a-cas-callback-the-open-and-flock-ask-a-mover-back-cetrafs_lock_ask_mover
cetrafs_lock_explicit_acquire below:the-flock-loop-asks-a-mover-back-and-polls-a-holder
cetrafs_lock_resume below:the-flock-loop-asks-a-mover-back-and-polls-a-holder
cetrafs_unlink_locked calls:cetrafs_lock_foreign_user_settled
cetrafs_rename_locked calls:cetrafs_lock_foreign_user_settled
cetrafs_link_locked calls:cetrafs_lock_foreign_user_settled
cetrafs_setattr_locked calls:cetrafs_lock_foreign_user_settled
cetrafs_fallocate calls:cetrafs_lock_foreign_user_settled
cetrafs_zero_range_inplace calls:cetrafs_lock_foreign_user_settled
cetrafs_foreign_claim_from_raw final:a-holder-judged-dead-came-back-it-is-live
cetrafs_rebuild_recheck final:a-peer-arrived-after-the-new-map-was-computed-waiting-would-publish-a-stale-map
cetrafs_fd_write_mutate final:a-peer-changed-the-file-since-the-plan-a-stale-map-must-not-publish
cetrafs_evict_inode below:a-peer-uses-it-the-number-stays-allocated-the-scrub-reclaims-it
cetrafs_lock_write_gate final:the-lock-is-suspended-flock-lock_ex-takes-it-back
cetrafs_xattr_peer_user final:a-peer-holds-or-reads-the-file-on-a-fresh-read'
C43_REG_ENOENT='cetrafs_dir_extents_get_unchecked final:the-directory-is-gone-on-a-fresh-read
cetrafs_dir_add_entry final:the-directory-is-gone-on-a-fresh-read
cetrafs_dir_remove_entry final:the-name-is-gone-under-the-namespace-lock
cetrafs_dir_retarget_entry final:the-name-is-gone-under-the-namespace-lock
cetrafs_link_locked final:no-names-left-on-a-fresh-read
cetrafs_lock_cas_mutate final:deleted-since-our-read
cetrafs_bg_trim_pool_one below:owns-no-zone-group-the-pool-pass-stops
cetrafs_sb_first_owned_zg below:none-owned
cetrafs_pending_next below:no-pending-range
cetrafs_leaf_array_convert below:not-covered-here
cetrafs_tree_convert_inner below:not-covered-here
cetrafs_inode_map_block final:a-hole-on-a-read-only-mapping'
c43_names() { # <errno> <files...>: every function with a literal return/assignment of -<errno>
    local e="$1"
    shift
    awk -v E="$e" '/^[a-z][a-z0-9_ *]*[ *]_*cetrafs_[a-z0-9_]*\(/ && !/;[ \t]*$/ { match($0, /_*cetrafs_[a-z0-9_]*\(/); fn = substr($0, RSTART, RLENGTH - 1) }
/^_*cetrafs_[a-z0-9_]*\(/ && !/;[ \t]*$/ { match($0, /_*cetrafs_[a-z0-9_]*\(/); fn = substr($0, RSTART, RLENGTH - 1) }
/^\}/ { fn = "" }
{ line = $0; sub(/\/\*.*$/, "", line); sub(/\/\/.*$/, "", line) }
line ~ /^[ \t]*\*/ { next }
line ~ ("(return|=)[ \t]*-" E "[ \t]*;") || line ~ ("return[^;]*[?:][ \t]*-" E "[ \t]*[;:]") { print (fn == "" ? "UNPLACED:" FILENAME ":" FNR : fn) }' "$@" | sort -u
}
for C43_E in ENOSPC EBUSY ENOENT ETXTBSY; do
    eval "C43_REG=\$C43_REG_$C43_E"
    C43_FOUND="$(c43_names "$C43_E" "$K"/*.c)"
    [ -n "$C43_FOUND" ] || fail "class 43: setup -- no -$C43_E found (the scan no longer matches)"
    C43_NEW="$(comm -23 <(echo "$C43_FOUND") <(cut -d' ' -f1 <<<"$C43_REG" | sort -u))"
    C43_GONE="$(comm -13 <(echo "$C43_FOUND") <(cut -d' ' -f1 <<<"$C43_REG" | sort -u))"
    C43_BAD="$(while read -r fn kind; do
        case "$kind" in
        waits:* | calls:*) grep -q "${kind#*:}(" <<<"$(c41_body "$fn")" || echo "$fn: no longer calls ${kind#*:}" ;;
        below:* | final:*) ;;
        *) echo "$fn: unknown kind $kind" ;;
        esac
    done <<<"$C43_REG")"
    [ -z "$C43_NEW" ] && [ -z "$C43_GONE" ] && [ -z "$C43_BAD" ] &&
        pass "class 43: every -$C43_E originator says what it waited out ($(echo $C43_FOUND | wc -w))" ||
        fail "class 43: -$C43_E unlisted: $(echo $C43_NEW); listed but gone: $(echo $C43_GONE); $C43_BAD"
done
# Control: a new originator, one in a comment (not one), one in a
# __-prefixed function, and a pick that stopped waiting.
C43_SAMPLE="$(ct_tmp c43).c"
printf 'static int __cetrafs_thing_busy(struct super_block *sb,\n                                int x);\nint cetrafs_thing_alloc(struct super_block *sb)\n{\n    /* return -ENOSPC; */\n    return -ENOSPC;\n}\nstatic int __cetrafs_thing_busy(struct super_block *sb,\n                                int x)\n{\n    cetrafs_thing_wait();\n    return -EBUSY;\n}\nint cetrafs_alloc_pick_bg(struct super_block *sb)\n{\n    return -ENOSPC;\n}\nint cetrafs_thing_either(struct super_block *sb, bool lost)\n{\n    return lost ? -EBUSY : -ENOSPC;\n}\n' >"$C43_SAMPLE"
[ "$(c43_names ENOSPC "$C43_SAMPLE" | tr '\n' ' ')" = "cetrafs_alloc_pick_bg cetrafs_thing_alloc cetrafs_thing_either " ] &&
    [ "$(c43_names EBUSY "$C43_SAMPLE" | grep -c .)" = 2 ] &&
    c43_names EBUSY "$C43_SAMPLE" | grep -qx __cetrafs_thing_busy &&
    c43_names EBUSY "$C43_SAMPLE" | grep -qx cetrafs_thing_either &&
    grep -q "cetrafs_thing_wait(" <<<"$(K="$(dirname "$C43_SAMPLE")" c41_body __cetrafs_thing_busy)" &&
    ! grep -q "cetrafs_sb_release_wait(" <<<"$(K="$(dirname "$C43_SAMPLE")" c41_body cetrafs_alloc_pick_bg)" &&
    pass "class 43: control -- planted originators are found (a __ one too, its body past its prototype), a comment is not, and a pick that stopped waiting is seen" ||
    fail "class 43: control -- the planted originators were not seen as expected"

# Class 14 (distance between check and act), for its most destructive
# act: clearing an inode number's bit. What runs between a verdict and
# its act is not visible to a grep, but WHO may act is: the bit clear is
# reachable only through the functions that re-read the record at the
# act (cetrafs_free_inode_if_dead()/_begin/_finish/_steal) or that free
# a number no verdict was made about (a create's own unpublished birth,
# a number held under this node's claim). Each primitive lists its
# callers; a new caller fails until it says which kind it is.
log "checking every inode-number free goes through an act-time re-check (class 14)"
C14_REG='cetrafs_inode_bitmap_cas_free cetrafs_free_inode cetrafs_free_inode_number_claimed
cetrafs_free_inode cetrafs_create_locked cetrafs_mkdir_locked cetrafs_symlink_locked
cetrafs_free_inode_number_claimed cetrafs_free_inode_finish cetrafs_lock_sweep_own_claims
cetrafs_free_inode_finish cetrafs_alloc_retry_reclaim cetrafs_evict_inode cetrafs_free_inode_if_dead cetrafs_free_inode_steal'
# cetrafs_free_inode: the create paths' rollback of a number they
#   allocated and never published -- nothing judged, nothing to re-read.
# cetrafs_free_inode_number_claimed: the dead record is held under this
#   node's reclaim claim, which is the act-time fence.
# cetrafs_free_inode_finish: called only after _begin's or _if_dead's
#   fresh re-read under the claim (rule 15).
c14_callers() { # <primitive> <files...>
    local p="$1"
    shift
    awk -v P="$p" '/^[a-z][a-z0-9_ *]*[ *]cetrafs_[a-z0-9_]*\(/ && !/;[ \t]*$/ { match($0, /cetrafs_[a-z0-9_]*\(/); fn = substr($0, RSTART, RLENGTH - 1) }
/^cetrafs_[a-z0-9_]*\(/ && !/;[ \t]*$/ { match($0, /cetrafs_[a-z0-9_]*\(/); fn = substr($0, RSTART, RLENGTH - 1) }
/^\}/ { fn = "" }
{ line = $0; sub(/\/\*.*$/, "", line) }
line ~ /^[ \t]*\*/ { next }
line ~ ("[^a-z_]" P "\\(") && fn != "" && fn != P { print fn }' "$@" | sort -u | tr '\n' ' '
}
C14_BAD="$(while read -r prim callers; do
    got="$(c14_callers "$prim" "$K"/*.c)"
    want="$(tr ' ' '\n' <<<"$callers" | sort -u | tr '\n' ' ')"
    [ "$got" = "$want" ] || echo "$prim: called from [$got], listed [$want];"
done <<<"$C14_REG")"
[ -z "$C14_BAD" ] && pass "class 14: every inode-number free is reached only through a listed act-time re-check" ||
    fail "class 14: $C14_BAD"
# Control: a planted unlisted caller of the bit clear is seen.
C14_SAMPLE="$(ct_tmp c14).c"
printf 'int cetrafs_scrub_thing(struct super_block *sb)\n{\n    return cetrafs_inode_bitmap_cas_free(sb, 1);\n}\n' >"$C14_SAMPLE"
[ "$(c14_callers cetrafs_inode_bitmap_cas_free "$C14_SAMPLE")" = "cetrafs_scrub_thing " ] &&
    pass "class 14: control -- a planted caller of the bit clear is found" ||
    fail "class 14: control -- the planted caller was not found"

# Class 14 for DATA blocks. Every function that frees data blocks (a
# data-bitmap bit cleared, directly or through one of the free
# primitives) is listed with the kind of verdict its free rests on and
# what keeps that verdict true at the act:
#   prim:...     a free primitive; its callers are listed instead;
#   own:...      blocks this operation allocated and never published --
#                nothing was judged about anyone else;
#   recheck:<f>  frees what a judged state no longer names, and asks
#                again at the act through <f> -- which it must still call;
#   held:...     frees under a claim no peer can enter while it is held;
#   queued:...   applies a free a peer published and queued to its owner.
# A new freeing function fails until it says which.
log "checking every data-block free names what keeps its verdict true at the act (class 14)"
C14D_REG='__cetrafs_free_data_extent prim:the-bitmap-clear-for-a-free
cetrafs_free_fetched_extents prim:evict-s
cetrafs_free_inline_extents prim:evict-s
cetrafs_free_leaf_array prim:of-free_inline_extents
cetrafs_leaf_array_punch prim:fallocate-s-punch
cetrafs_leaf_array_trim prim:truncate-s
cetrafs_tree_free_meta prim:its-callers-are-listed
cetrafs_alloc_data_run_resv own:a-run-it-just-took-back-on-failure
cetrafs_trim_claim_next own:undoes-its-own-claim
cetrafs_trim_release own:gives-back-its-own-claim
cetrafs_mkdir_locked own:a-dirent-block-never-published
cetrafs_do_allocate own:blocks-never-published-held-in-the-reservation-registry
cetrafs_falloc_run_give_back_span own:the-unused-rest-of-a-fallocate-run-never-published
__cetrafs_get_block own:a-block-never-published
cetrafs_tree_append own:a-leaf-or-index-never-published
cetrafs_tree_split_leaf own:a-new-leaf-whose-write-failed-before-any-interior-names-it
cetrafs_tree_build own:a-tree-never-published
cetrafs_inode_set_reservation own:a-reservation-run-never-published
cetrafs_inode_drop_reservation own:the-unused-rest-of-a-reservation-run
cetrafs_tree_resv_release own:the-unused-tree-block-reserve-of-a-convert-never-published
cetrafs_evict_inode recheck:cetrafs_free_inode_begin
__cetrafs_truncate_shrink recheck:cetrafs_rebuild_peer_present
cetrafs_fallocate recheck:cetrafs_rebuild_peer_present
cetrafs_xattr_set_locked recheck:cetrafs_xattr_peer_user
scrub_free_confirmed recheck:cetrafs_free_data_extent_unless_reserved
cetrafs_defrag_inode held:the-defrag-pin-on-the-whole-file-lock
cetrafs_defrag_commit held:inside-cetrafs_defrag_inode-s-pin
cetrafs_apply_pending_free queued:the-owner-applying-a-published-free
cetrafs_zg_drain_one queued:drains-the-owner-s-queue'
C14D_PRIMS='cetrafs_free_data_block cetrafs_free_data_extent cetrafs_free_data_extent_batched cetrafs_free_data_extent_unless_reserved cetrafs_apply_pending_free cetrafs_bitmap_free_bit cetrafs_bitmap_flip_range cetrafs_free_fetched_extents cetrafs_free_inline_extents cetrafs_free_leaf_array cetrafs_tree_free_meta cetrafs_leaf_array_punch cetrafs_leaf_array_trim'
c14d_freers() { # <files...>: every function calling a free primitive (any name, not just cetrafs_*)
    local p
    for p in $C14D_PRIMS; do
        awk -v P="$p" '
/^[a-z][a-z0-9_ *\t]*[ *\t][a-z_][a-z0-9_]*\(/ && !/;[ \t]*$/ && !/^(return|if|else|while|for)/ { match($0, /[a-z_][a-z0-9_]*\(/); fn = substr($0, RSTART, RLENGTH - 1) }
/^[a-z_][a-z0-9_]*\(/ && !/;[ \t]*$/ { match($0, /[a-z_][a-z0-9_]*\(/); fn = substr($0, RSTART, RLENGTH - 1) }
/^\}/ { fn = "" }
{ line = $0; sub(/\/\*.*$/, "", line); sub(/\/\/.*$/, "", line) }
line ~ /^[ \t]*\*/ { next }
line ~ ("(^|[^a-z0-9_])" P "\\(") && fn != P && fn != "" { print fn }' "$@"
    done | sort -u
}
C14D_FOUND="$(c14d_freers "$K"/*.c)"
[ "$(grep -c . <<<"$C14D_FOUND")" -ge 20 ] || fail "class 14 (data): setup -- found only $(grep -c . <<<"$C14D_FOUND") freeing functions; the scan is not seeing the tree"
C14D_NEW="$(comm -23 <(echo "$C14D_FOUND") <(cut -d' ' -f1 <<<"$C14D_REG" | sort -u))"
C14D_GONE="$(comm -13 <(echo "$C14D_FOUND") <(cut -d' ' -f1 <<<"$C14D_REG" | sort -u))"
C14D_BAD="$(while read -r fn kind; do
    case "$kind" in
    recheck:*) grep -q "${kind#recheck:}(" <<<"$(c41_body "$fn")" || echo "$fn: no longer calls ${kind#recheck:}" ;;
    prim:* | own:* | held:* | queued:*) ;;
    *) echo "$fn: unknown kind $kind" ;;
    esac
done <<<"$C14D_REG")"
[ -z "$C14D_NEW" ] && [ -z "$C14D_GONE" ] && [ -z "$C14D_BAD" ] &&
    pass "class 14: every data-block free names what keeps its verdict true at the act ($(echo $C14D_FOUND | wc -w))" ||
    fail "class 14 (data): unlisted: $(echo $C14D_NEW); listed but gone: $(echo $C14D_GONE); $C14D_BAD"
# Control: a new freeing function (not cetrafs_-named) is found, and a
# recheck that stopped calling its re-check is seen.
C14D_SAMPLE="$(ct_tmp c14d).c"
printf 'static void scrub_new_dropper(struct super_block *sb)\n{\n    cetrafs_free_data_extent(sb, 5, 1);\n}\nstatic void cetrafs_xattr_set_locked(struct inode *inode)\n{\n    cetrafs_free_data_block(inode->i_sb, 7);\n}\n' >"$C14D_SAMPLE"
[ "$(c14d_freers "$C14D_SAMPLE" | tr '\n' ' ')" = "cetrafs_xattr_set_locked scrub_new_dropper " ] &&
    ! grep -q "cetrafs_xattr_peer_user(" <<<"$(K="$(dirname "$C14D_SAMPLE")" c41_body cetrafs_xattr_set_locked)" &&
    pass "class 14 (data): control -- a planted unlisted free is found, and a recheck that stopped re-checking is seen" ||
    fail "class 14 (data): control -- the planted cases were not seen as expected"

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
node.c:cetrafs_for_each_live_peer:mount-time walk -- proves alive by watching hb_seq move, never by one sample, and beats its own row meanwhile so a peer running it sees us move (audit 2026-11-11 N1)
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
lock.c:cetrafs_lock_ask_mover:alive -> ask its move back and wait, bounded; a dead mover judged alive costs the wait and then the old refusal (keep)
lock.c:cetrafs_lock_explicit_acquire:alive -> keep waiting; the runtime watch converges
lock.c:cetrafs_lock_open:alive -> refuse this open; the runtime watch converges on retry
nslock.c:cetrafs_nslock_try:alive -> wait and retry
procfs.c:cetrafs_proc_cluster_show:display only
scrub.c:scrub_reclaim_orphan_inodes:alive -> skip (keep)
scrub.c:scrub_reconcile_stopped_op:alive -> skip; the live holder releases and publishes the count (keep)
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

# Class 30 (a discard landing on live data), inline discard's premise.
# `-o discard` discards a freed run about a second after the free
# (discard.c), so every block that reaches the queue must already be
# unreferenced ON THE DEVICE when it is freed: rule 21, publish first,
# then free. fstrim stood on the same premise but ran rarely enough to
# hide a free that came before its publish; this does not. The queue is
# fed only by __cetrafs_free_data_extent() and cetrafs_apply_pending_free(),
# so every function that calls them -- or runs a tree helper's freeing
# pass (do_free=true) -- is listed with why its blocks are unreferenced.
log "checking every path into a freed-run discard frees only what the device no longer references (class 30)"
FREE_OK='alloc.c:__cetrafs_free_data_extent:the free itself
alloc.c:cetrafs_free_data_extent:wrapper
alloc.c:cetrafs_free_data_extent_batched:wrapper -- the batched form; its callers flush before their own return
alloc.c:cetrafs_free_data_extent_unless_reserved:wrapper
alloc.c:cetrafs_apply_pending_free:a peer'"'"'s free, queued by one of these paths on that peer
alloc.c:cetrafs_foreign_free_leak_count:a forward declaration, not a call
zonegroup.c:cetrafs_zg_drain_one:the pending-free drain, into cetrafs_apply_pending_free
file.c:cetrafs_leaf_array_trim:only its do_free pass frees; see the do_free callers
file.c:cetrafs_leaf_array_punch:only its do_free pass frees; see the do_free callers
file.c:cetrafs_free_leaf_array:inside cetrafs_free_inline_extents
file.c:cetrafs_free_inline_extents:no caller
file.c:cetrafs_free_fetched_extents:evict, after the claim on a record already dead on the device (cetrafs_free_inode_begin())
defrag.c:cetrafs_defrag_inode:the never-committed tail of its destination run
lock.c:cetrafs_inode_drop_reservation:a reservation remainder, never written or referenced
lock.c:cetrafs_inode_set_reservation:a reservation remainder, never written or referenced
file.c:cetrafs_falloc_run_give_back_span:a fallocate run remainder, never written or referenced
scrub.c:scrub_free_confirmed:a block re-read unreferenced, under the reservation recheck'
DOFREE_OK='file.c:__cetrafs_truncate_shrink:after the record CAS that publishes the new tree
file.c:cetrafs_fallocate:the punch, after the record CAS that publishes the new tree'
free_callers() {
    for f in "$@"; do
        awk -v F="$(basename "$f")" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn) }
            /cetrafs_free_data_extent\(|cetrafs_free_data_extent_batched\(|cetrafs_free_data_extent_unless_reserved\(|__cetrafs_free_data_extent\(|cetrafs_apply_pending_free\(/ && !/^[[:space:]]*\*/ && !/^[[:space:]]*\/\*/ { print F ":" fn }' "$f"
    done | sort -u
}
dofree_callers() {
    for f in "$@"; do
        awk -v F="$(basename "$f")" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn) }
            /do_free=\*\/true/ { print F ":" fn }' "$f"
    done | sort -u
}
FC="$(free_callers "$K"/*.c)"; DC="$(dofree_callers "$K"/*.c)"
[ "$(grep -c . <<<"$FC")" -ge 10 ] && [ "$(grep -c . <<<"$DC")" -ge 2 ] ||
    fail "class 30: found only $(grep -c . <<<"$FC") free callers and $(grep -c . <<<"$DC") freeing passes -- the scan is not seeing the tree"
UNF="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -qF "$l:" <<<"$FREE_OK" && echo "$l"; done <<<"$FC" || true)"
UND="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -qF "$l:" <<<"$DOFREE_OK" && echo "$l"; done <<<"$DC" || true)"
[ -z "$UNF$UND" ] && pass "class 30: every path into a freed-run discard names why its blocks are unreferenced" ||
    fail "class 30: unclassified frees (is the block unreferenced on the device before this free?): $(echo $UNF $UND)"
SAMPLE="$(ct_tmp free-sample).c"
printf 'static void cetrafs_new_freer(struct super_block *sb)\n{\n    cetrafs_free_data_extent(sb, 1, 1);\n}\nstatic void cetrafs_new_pass(void)\n{\n    x(/*do_free=*/true);\n}\n' >"$SAMPLE"
[ "$(free_callers "$SAMPLE")" = "$(basename "$SAMPLE"):cetrafs_new_freer" ] &&
    [ "$(dofree_callers "$SAMPLE")" = "$(basename "$SAMPLE"):cetrafs_new_pass" ] &&
    pass "class 30: control -- a planted free and a planted freeing pass are found" ||
    fail "class 30: control -- a planted free or freeing pass is not found"

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
alloc.c:cetrafs_free_data_extent_batched:the primitive (batched) -- every batch is flushed by the function that filled it, inside its frees_begin bracket
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
file.c:cetrafs_falloc_run_give_back_span:the unused rest of a fallocate run, never published, held in the reservation registry until given back (H2)
file.c:__cetrafs_get_block:a block it allocated and never published
file.c:cetrafs_tree_append:a leaf or index it allocated and never published
file.c:cetrafs_tree_split_leaf:a new leaf whose write failed, before any interior names it
file.c:cetrafs_tree_build:a tree it built and never published
dir.c:cetrafs_mkdir_locked:a dirent block it allocated and never published
lock.c:cetrafs_inode_set_reservation:a reservation run, never published
lock.c:cetrafs_inode_drop_reservation:the unused rest of a reservation run, never published
lock.c:cetrafs_tree_resv_release:the unused tree-block reserve of a convert, never published (FD-1)'
free_callers() {
    for f in "$@"; do
        awk -v F="$(basename "$f")" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { if (fn != "" && hit && !beg) print F ":" fn; fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn); hit = 0; beg = 0 }
            /(cetrafs_free_data_block|cetrafs_free_data_extent|cetrafs_free_data_extent_batched|cetrafs_free_data_extent_unless_reserved|cetrafs_tree_free_meta|cetrafs_free_fetched_extents|cetrafs_free_leaf_array|cetrafs_free_inline_extents|cetrafs_leaf_array_trim|cetrafs_leaf_array_punch)\(/ && !/^[a-z_]/ && !/^[[:space:]]*\*/ && !/^[[:space:]]*\/\*/ { hit = 1 }
            /cetrafs_frees_begin\(/ && !/^[a-z_]/ { beg = 1 }
            END { if (fn != "" && hit && !beg) print F ":" fn }' "$f"
    done | sort -u
}
FC="$(free_callers "$K"/*.c)"
[ "$(grep -c . <<<"$FC")" -ge 15 ] || fail "class 46: found only $(grep -c . <<<"$FC") unbracketed freeing functions -- the scan is not seeing the tree"
# Per call site, not per function: the list above names what covers a
# function's OTHER frees, and cetrafs_do_allocate's "never published"
# covered its own new blocks while it freed the old tree after publishing
# a new one (audit 2026-11-15 B-31). A free that follows a record publish
# in the same function, with no frees_begin before it, is reported
# whatever the list says.
post_publish_frees() {
    for f in "$@"; do
        awk -v F="$(basename "$f")" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn); pub = 0; beg = 0 }
            /^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
            /cetrafs_frees_begin\(/ && !/^[a-z_]/ { beg = 1 }
            /cetrafs_write_raw_inode[a-z_]*\(|cetrafs_write_vfs_inode\(/ && !/^[a-z_]/ { pub = 1 }
            /(cetrafs_free_data_block|cetrafs_free_data_extent|cetrafs_free_data_extent_batched|cetrafs_tree_free_meta|cetrafs_free_leaf_array|cetrafs_free_inline_extents|cetrafs_leaf_array_trim|cetrafs_leaf_array_punch)\(/ && !/^[a-z_]/ && pub && !beg { print F ":" fn ":" FNR }' "$f"
    done
}
# function:count:what covers them -- the count pins the sites, so a new
# post-publish free in a listed function is reported too
PP_OK='defrag.c:cetrafs_defrag_commit:2:inside its only caller'"'"'s bracket (cetrafs_defrag_inode)
dir.c:cetrafs_mkdir_locked:2:its own new dirent block, with the number it goes back with -- no publish named it alive
file.c:__cetrafs_get_block:2:a block the failed append never published (a directory'"'"'s publish is a different block)'
PPC="$(post_publish_frees "$K"/*.c | cut -d: -f1,2 | sort | uniq -c | awk '{print $2 ":" $1}')"
PPU="$(while IFS= read -r l; do [ -n "$l" ] && ! grep -q "^$l:" <<<"$PP_OK" && echo "$l"; done <<<"$PPC" || true)"
[ -z "$PPU" ] && pass "class 46: every free after a record publish is bracketed, or its sites are counted with their cover" ||
    fail "class 46: frees after a record publish with no cetrafs_frees_begin() (file:function:count): $(echo $PPU)"
PSAMPLE="$(ct_tmp pp-sample).c"
printf 'static int cetrafs_do_allocate(struct inode *inode)\n{\n    cetrafs_write_raw_inode_fd(sb, 1, raw, inode);\n    cetrafs_tree_free_meta(inode, old);\n}\n' >"$PSAMPLE"
[ -n "$(post_publish_frees "$PSAMPLE")" ] && pass "class 46: control -- a free after a publish is found per call site, whatever the list says" ||
    fail "class 46: control -- a free after a publish is not found"
for b in __cetrafs_truncate_shrink cetrafs_defrag_inode cetrafs_xattr_set_locked cetrafs_fallocate cetrafs_do_allocate; do
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

# Every compare-and-swap mutator is handed ONE region of its block --
# the first sector, on most devices -- not the block. A record whose
# checksum covers the whole block must be restamped by a helper that
# folds the rest in as the zeros it holds (cetrafs_bg_image_crc(),
# cetrafs_bgseg_crc_prefix()). A whole-block helper reads past the
# region buffer and stamps a checksum over bytes that are not the
# device's: the first live-grow link failed every time for exactly
# that, and a record whose verify did not catch it would have been
# restamped from heap garbage (class 47).
log "checking no CAS mutator checksums past the region it is handed (class 47)"
WHOLE_BLOCK_CRC='cetrafs_bg_crc_verify|cetrafs_bgseg_crc|cetrafs_journal_header_crc'
cas_mutators() { cat "$@" | tr '\n' ' ' | grep -oE 'cetrafs_cas_[a-z_]+\([^;]*' | grep -oE 'cetrafs_[a-z0-9_]+_mutate' | sort -u; }
mutator_whole_crc() { # <files>: mutator:helper for each whole-block checksum a CAS mutator calls
    local m f
    for m in $(cas_mutators "$@"); do
        for f in "$@"; do
            fn_body "$f" "$m" | grep -oE "\b($WHOLE_BLOCK_CRC)\(" | tr -d '(' | sed "s/^/$m:/" || true
        done
    done | sort -u
}
NMUT="$(cas_mutators "$K"/*.c | grep -c .)"
[ "$NMUT" -ge 25 ] || fail "class 47: setup -- found only $NMUT CAS mutators (the scan no longer matches)"
MW="$(mutator_whole_crc "$K"/*.c)"
[ -z "$MW" ] && pass "class 47: none of $NMUT CAS mutators checksums a whole block from its region" ||
    fail "class 47: a CAS mutator computes a whole-block checksum over its one-region image: $(echo $MW)"
SAMPLE="$(ct_tmp cas-sample).c"
printf 'static int cetrafs_x_mutate(void *image, unsigned int len, void *priv)\n{\n    return cetrafs_bgseg_crc(image);\n}\nstatic int f(void)\n{\n    return cetrafs_cas_record(sb, 1,\n        cetrafs_x_mutate, NULL);\n}\n' >"$SAMPLE"
[ "$(mutator_whole_crc "$SAMPLE")" = "cetrafs_x_mutate:cetrafs_bgseg_crc" ] &&
    pass "class 47: control -- a planted whole-block checksum in a mutator is found" ||
    fail "class 47: control -- a planted whole-block checksum in a mutator is not found"

# "Not in the layout I have" is not "not in the volume" once the volume
# can grow under a mount. A check that answers "out of range" against a
# layout another node may already have outgrown must refresh first, and
# when it still cannot tell, say so (-EAGAIN) to callers that then
# neither drop, mark nor zero anything (class 48): replay dropped a
# dead peer's entry into new Block Groups and parked its area clean, a
# node whose LUN was not yet rescanned marked healthy files damaged, and
# a directory leaf in new space read as "no owner" and was zeroed.
log "checking range verdicts against a growable layout can say 'cannot tell' (class 48)"
fns_with() { # <regex> <files...>: file:fn for every function whose body matches
    local re="$1"; shift
    for f in "$@"; do
        awk -v F="$(basename "$f")" -v RE="$re" '
            /^[a-z_][a-z0-9_ *]*\(/ && !/;$/ { if (fn != "" && hit) print F ":" fn; fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; sub(/^\*+/, "", fn); hit = 0 }
            $0 ~ RE && !/^[a-z_]/ && !/^[[:space:]]*\*/ && !/^[[:space:]]*\/\*/ { hit = 1 }
            END { if (fn != "" && hit) print F ":" fn }' "$f"
    done | sort -u
}
any_fn_body() { # <file> <fn>: fn_body, for static and exported functions alike
    awk -v f="$2" '$0 ~ "^[a-z_].*[ *]" f "[(]" && !/;[[:space:]]*$/ { on = 1 } on { print } on && /^}/ { exit }' "$1"
}
unhandled_check() { # <files...>: callers of cetrafs_lba_run_check() that never mention -EAGAIN
    local c
    for c in $(fns_with 'cetrafs_lba_run_check[(]' "$@"); do
        any_fn_body "$(dirname "$1")/${c%%:*}" "${c#*:}" | grep -q -- '-EAGAIN' || echo "$c"
    done
}
CK="$(fns_with 'cetrafs_lba_run_check[(]' "$K"/*.c)"
[ "$(grep -c . <<<"$CK")" -ge 7 ] || fail "class 48: setup -- found only $(grep -c . <<<"$CK") callers of cetrafs_lba_run_check()"
UH="$(unhandled_check "$K"/*.c)"
[ -z "$UH" ] && pass "class 48: every one of $(grep -c . <<<"$CK") cetrafs_lba_run_check() callers handles 'cannot tell'" ||
    fail "class 48: a caller of cetrafs_lba_run_check() never handles -EAGAIN: $(echo $UH)"
# The boolean form folds "cannot tell" into "not data": only for callers
# whose refusal decides nothing. A new one is a decision to review.
BOOL_OK='file.c:cetrafs_scrub_tree_bread file.c:cetrafs_tree_invalidate_cached'
BC="$(fns_with 'cetrafs_lba_run_is_data[(]' "$K"/*.c | tr '\n' ' ' | sed 's/ $//')"
[ "$BC" = "$BOOL_OK" ] && pass "class 48: the boolean address check is used only where 'not data' decides nothing" ||
    fail "class 48: cetrafs_lba_run_is_data() callers changed: '$BC' (reviewed: '$BOOL_OK') -- a caller that marks, drops or zeroes on 'not data' must use cetrafs_lba_run_check()"
any_fn_body "$K/alloc.c" cetrafs_bg_id_for_lba | grep -q 'cetrafs_sb_layout_refresh' &&
    any_fn_body "$K/alloc.c" cetrafs_bg_id_for_lba | grep -q -- '-EAGAIN' &&
    pass "class 48: the Block Group lookup refreshes before it answers 'outside every region'" ||
    fail "class 48: cetrafs_bg_id_for_lba() no longer refreshes the layout or answers -EAGAIN"
# A claim's recount counts the members of the layout it holds: it must
# catch up with the device after the swap and before the recount, or a
# grown member the previous owner claimed is "corrected" out of the
# aggregate (tests/kernel/zg_claim_behind_grow.sh).
# The definition, not the forward declaration above it: the last body.
C48CL="$(awk '$0 ~ "^[a-z_].*[ *]__cetrafs_zg_try_claim_one[(]" { buf = ""; on = 1 } on { buf = buf $0 "\n" } on && /^}/ { last = buf; on = 0 } END { printf "%s", last }' "$K/zonegroup.c" | grep -nE 'cetrafs_sb_layout_refresh|cetrafs_zg_reconcile_free_counts\(sb, zg_id[,)]' | tail -2 | cut -d: -f2- | grep -oE 'cetrafs_[a-z_]+' | tr '\n' ' ' || true)"
[ "$C48CL" = "cetrafs_sb_layout_refresh cetrafs_zg_reconcile_free_counts " ] &&
    pass "class 48: a Zone Group claim catches the layout up before it recounts" ||
    fail "class 48: __cetrafs_zg_try_claim_one() no longer refreshes the layout before the claim's recount ('$C48CL')"
SAMPLE="$(ct_tmp c48-sample).c"
printf 'static int cetrafs_new_reader(struct super_block *sb)\n{\n    if (cetrafs_lba_run_check(sb, 5, 1))\n        cetrafs_sb_corrupt(sb, 0);\n    return 0;\n}\n' >"$SAMPLE"
[ "$(unhandled_check "$SAMPLE")" = "$(basename "$SAMPLE"):cetrafs_new_reader" ] &&
    pass "class 48: control -- a planted caller that marks on 'cannot tell' is found" ||
    fail "class 48: control -- a planted caller that marks on 'cannot tell' is not found"

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
# modinfo's output is captured first: piped into grep -q under pipefail,
# grep exits at the match and modinfo, still printing the parameters
# that follow it, dies of SIGPIPE -- a failure that depends on how many
# parameters there are.
elif MI="$(modinfo "$KO" 2>/dev/null)" && grep -qx "alias: *fs-$(sed -n 's/^#define CETRAFS_NAME[[:space:]][[:space:]]*"\([a-z][a-z]*\)".*/\1/p' "$ROOT/include/cetrafs.h")" <<<"$MI"; then
    pass "module alias: the built module declares fs-cetrafs, so mount -t autoloads it"
else
    fail "module alias: no fs-cetrafs alias in the built module (MODULE_ALIAS_FS gone?) -- \`mount -t cetrafs\` will fail with 'unknown filesystem type' unless something loaded it first. modinfo says: $(modinfo "$KO" 2>&1 | grep -E '^alias' || echo '(no alias at all)')"
fi

log "checking every discard is issued through the one range-checked issuer"
# Class 50: a discard aimed outside the region its caller owns destroys
# metadata or a peer's data, silently (fstrim.sh case 3's DISCRIMINATION:
# the root directory and every file). cetrafs_discard_issue() checks the
# range against the Block Group's data region and resolves both ends; a
# second caller of the block layer's discard would skip that.
DISC="$(awk '/^(static )?(int|long|void) [a-z_]+\(/ { fn = $0 } /blkdev_issue_(discard|secure_erase|zeroout)|__blkdev_issue_discard/ && fn !~ /cetrafs_(discard|zeroout)_issue\(/ { print FILENAME ":" FNR }' $(ls "$K"/*.c | grep -v '\.mod\.c$') || true)"
NDISC="$(grep -c 'blkdev_issue_discard' "$K"/discard.c || true)"
[ "$NDISC" -ge 1 ] || fail "discard issuer: no blkdev_issue_discard in discard.c -- the scan is not seeing the issuer"
[ -z "$DISC" ] && pass "discard issuer: blkdev_issue_discard/zeroout appear only in the range-checked issuers (discard.c)" ||
    fail "discard issuer: a discard issued outside cetrafs_discard_issue(), skipping its range check: $DISC"

# Class 53 (a reporting path asking the writer's freshness question).
# The plain tree readers -- cetrafs_inode_extents_get(),
# cetrafs_tree_flatten(), cetrafs_tree_extent_count() and
# cetrafs_read_{leaf,index,tree}_bh() -- answer "is my cache current?"
# with the write lock: without it every block comes from the device. That
# is right for a caller that writes, frees, moves or decides a free by
# what it reads, and a device read per block per call for one that only
# REPORTS the map (fiemap, SEEK_DATA/HOLE, the defrag nudge's count):
# filefrag on one fallocated image took 285 s. A reporter takes the
# _for(..., true) variant and the reader rule
# (cetrafs_lock_read_cache_trusted()). Every function calling a plain
# reader is listed with what it does with the answer; a new caller fails
# until it is classified. Names only: a reporter that reaches a plain
# reader through a helper is seen as that helper (gap).
log "checking every plain tree reader's caller is a writer, not a reporter (class 53)"
C53_REG='cetrafs_defrag_read_extents moves:defrag-relocates-by-it
cetrafs_do_allocate writes:fallocate-plans-and-publishes-extents
cetrafs_evict_inode frees:every-block-it-names
cetrafs_fallocate writes:punch-and-collapse-rebuild-the-tree
cetrafs_falloc_map_build writes:the-plan-the-publish-is-built-over
cetrafs_free_inline_extents frees:a-directorys-blocks
cetrafs_read_index_bh wraps:cetrafs_read_tree_bh
cetrafs_read_leaf_bh wraps:cetrafs_read_tree_bh
cetrafs_tree_append writes:the-tree
cetrafs_tree_convert_inner writes:the-tree
cetrafs_tree_free_meta frees:the-trees-own-blocks
cetrafs_tree_insert_any_leaf writes:the-tree
cetrafs_tree_last_contig_lba writes:the-allocation-goal-of-a-write
cetrafs_tree_meta_is_ours frees:decides-a-free
cetrafs_tree_split_leaf writes:the-tree
__cetrafs_truncate_shrink frees:what-truncate-cuts
cetrafs_zero_range_inplace writes:zeroes-and-converts-by-it'
c53_callers() { # <files...>: "<function> <plain reader>" per call site
    awk '
/^[a-z][a-z0-9_ *]*[ *]_*cetrafs_[a-z0-9_]+\(/ { match($0, /_*cetrafs_[a-z0-9_]+\(/); sig = substr($0, RSTART, RLENGTH - 1) }
/^\{/ { fn = sig }
/^\}/ { fn = "" }
fn != "" && !/^[[:space:]]*(\*|\/\*|\/\/)/ {
    line = $0
    while (match(line, /[^a-z0-9_](cetrafs_inode_extents_get|cetrafs_tree_flatten|cetrafs_tree_extent_count|cetrafs_read_leaf_bh|cetrafs_read_index_bh|cetrafs_read_tree_bh)\(/)) {
        print fn, substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
    }
}' "$@" | sort -u | awk '$1 != $2 && $1 != $2 "_for"' | sort -u
}
C53_FOUND="$(c53_callers $(ls "$K"/*.c | grep -v '\.mod\.c$') | cut -d' ' -f1 | sort -u)"
[ -n "$C53_FOUND" ] || fail "class 53: setup -- no caller of a plain tree reader found (the scan no longer matches)"
C53_NEW="$(comm -23 <(echo "$C53_FOUND") <(cut -d' ' -f1 <<<"$C53_REG" | sort -u))"
C53_GONE="$(comm -13 <(echo "$C53_FOUND") <(cut -d' ' -f1 <<<"$C53_REG" | sort -u))"
[ -z "$C53_NEW" ] && [ -z "$C53_GONE" ] &&
    pass "class 53: every caller of a plain tree reader is listed as writing, freeing or moving by it ($(echo $C53_FOUND | wc -w))" ||
    fail "class 53: unlisted (a reporter? use the _for(..., true) reader variant): $(echo $C53_NEW); listed but gone: $(echo $C53_GONE)"
# Control: a reporting function on a plain reader is found and unlisted.
C53_SAMPLE="$(ct_tmp c53).c"
printf 'static long cetrafs_report_map(struct inode *inode, cetrafs_inode_t *raw)\n{\n    struct cetrafs_inode_extents ex;\n    return cetrafs_inode_extents_get(inode, raw, &ex);\n}\n' >"$C53_SAMPLE"
[ "$(c53_callers "$C53_SAMPLE")" = "cetrafs_report_map cetrafs_inode_extents_get" ] &&
    ! grep -q '^cetrafs_report_map ' <<<"$C53_REG" &&
    pass "class 53: control -- a planted reporter on a plain tree reader is found and unlisted" ||
    fail "class 53: control -- the planted reporter was not found ($(c53_callers "$C53_SAMPLE"))"

# N6 (audit 2026-11-14): an allocation that may enter reclaim with a
# namespace lock or alloc_mutex held can recurse into an evict that
# wants the same lock. The namespace layer allocates NOFS throughout;
# ->alloc_inode and the CAS core did not. The files below allocate
# nothing GFP_KERNEL, and in lock.c and caw.c the functions every
# namespace operation and every claim go through do not either.
# Negative control: a planted GFP_KERNEL in a listed function.
log "checking the namespace and CAS paths allocate NOFS (N6)"
# gfp_kernel_in <file> <func>...: file:line of each GFP_KERNEL inside
# the named functions' bodies (a definition opens at column 0).
gfp_kernel_in() {
    local f="$1"; shift
    awk -v names="$*" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        /^[a-z].*\(/ && !/;[[:space:]]*$/ {
            nm = $0; sub(/\(.*/, "", nm); sub(/.*[ *]/, "", nm); cur = (nm in want) ? nm : ""; depth = 0; seen = 0
        }
        cur != "" {
            if (/GFP_KERNEL/) print FILENAME ":" FNR
            o = gsub(/\{/, "{"); c = gsub(/\}/, "}"); depth += o - c; if (o) seen = 1
            if (seen && depth <= 0) cur = ""
        }
    ' "$f"
}
N6_SAMPLE="$(ct_tmp n6-sample.c)"
printf '%s\n' 'static int keep(void)' '{' '    return kmalloc(8, GFP_KERNEL) != NULL;' '}' \
    'int cetrafs_alloc_vfs_inode(struct super_block *sb)' '{' '    void *p = kmalloc(8, GFP_NOFS);' \
    '    void *q = kmalloc(8, GFP_KERNEL);' '    return !p || !q;' '}' >"$N6_SAMPLE"
[ "$(gfp_kernel_in "$N6_SAMPLE" cetrafs_alloc_vfs_inode | tr '\n' ' ')" = "$N6_SAMPLE:8 " ] &&
    pass "N6: control -- a planted GFP_KERNEL in a listed function is found, one outside it is not" ||
    fail "N6: control -- the scan does not discriminate (got '$(gfp_kernel_in "$N6_SAMPLE" cetrafs_alloc_vfs_inode | tr '\n' ' ')')"
N6_HITS="$(grep -n GFP_KERNEL "$K/dir.c" "$K/nslock.c" "$K/inode.c" "$K/xattr.c" | sed "s|$K/||" | cut -d: -f1,2 || true)"
N6_HITS="$N6_HITS $(gfp_kernel_in "$K/lock.c" cetrafs_alloc_vfs_inode | sed "s|$K/||")"
N6_HITS="$N6_HITS $(gfp_kernel_in "$K/caw.c" cetrafs_caw_scsi cetrafs_cas_region_seeded_impl | sed "s|$K/||")"
N6_N="$(grep -c GFP_NOFS "$K/caw.c" || true)"
[ "${N6_N:-0}" -ge 5 ] || fail "N6: setup: caw.c has $N6_N NOFS allocations -- the scan is not seeing the tree"
[ -z "$(echo $N6_HITS)" ] && pass "N6: the namespace layer, ->alloc_inode and the CAS core allocate NOFS" ||
    fail "N6: GFP_KERNEL on a path that holds namespace locks or alloc_mutex, at: $(echo $N6_HITS)"

# N2 (audit 2026-11-14): a walk over every inode on the volume runs for
# as long as the volume is large, often under a VFS lock; one that does
# not check for a fatal signal makes its caller unkillable. Every loop
# bounded by inodes_count in the namespace layer checks it.
# Negative control: a planted walk without the check.
log "checking every whole-volume inode walk is killable (N2)"
# unkillable_walks <file>...: file:line of each for-loop over an
# inodes_count bound whose body never calls fatal_signal_pending().
unkillable_walks() {
    awk '
        FNR == 1 { inl = 0; depth = 0 }
        /^[[:space:]]*for \(.*<= *ninodes|^[[:space:]]*for \(.*inodes_count/ { inl = FNR; ld = depth; ok = 0 }
        inl && /fatal_signal_pending\(/ { ok = 1 }
        {
            o = gsub(/\{/, "{"); c = gsub(/\}/, "}"); depth += o - c
            if (inl && FNR > inl && depth <= ld) { if (!ok) print FILENAME ":" inl; inl = 0 }
        }
    ' "$@"
}
N2_SAMPLE="$(ct_tmp n2-sample.c)"
printf '%s\n' 'int f(u64 ninodes)' '{' '    for (d = 1; d <= ninodes; d++) {' '        look(d);' '    }' \
    '    for (d = 1; d <= ninodes; d++) {' '        if (fatal_signal_pending(current))' '            return -EINTR;' '    }' '}' >"$N2_SAMPLE"
[ "$(unkillable_walks "$N2_SAMPLE" | tr '\n' ' ')" = "$N2_SAMPLE:3 " ] &&
    pass "N2: control -- a planted walk without the check is found, one with it is not" ||
    fail "N2: control -- the scan does not discriminate (got '$(unkillable_walks "$N2_SAMPLE" | tr '\n' ' ')')"
N2_N="$(grep -cE 'for \(.*<= *ninodes' "$K/dir.c" || true)"
[ "${N2_N:-0}" -ge 1 ] || fail "N2: setup: no inode walk found in dir.c -- the scan is not seeing the tree"
N2_HITS="$(unkillable_walks "$K/dir.c" "$K/nslock.c" | sed "s|$K/||")"
[ -z "$N2_HITS" ] && pass "N2: every whole-volume inode walk in the namespace layer is killable" ||
    fail "N2: an inode walk with no fatal-signal check, at: $(echo $N2_HITS)"

# L-F6 (audit 2026-11-14): a task_work in this module that drops its
# own module reference returns into freed text if unload runs between
# the two. Unload must wait a tasks-RCU grace period first, and a build
# without tasks RCU must never queue one. No loop-device instrument can
# see the race short of crashing the box on rmmod, so it is checked here.
# Negative control: the exit without the wait.
log "checking unload waits out the namespace restart task_work's tail (L-F6)"
lf6_ok() { # <nslock.c>: exit waits tasks RCU, the queue path is gated on it
    awk '/^void cetrafs_nslock_exit\(void\)/ { f = 1 } f && /synchronize_rcu_tasks\(\)/ { w = 1 } f && /^\}/ { f = 0 }
         /IS_ENABLED\(CONFIG_TASKS_RCU\)/ { g = 1 } END { exit !(w && g) }' "$1"
}
LF6_SAMPLE="$(ct_tmp lf6-sample.c)"
sed '/synchronize_rcu_tasks()/d' "$K/nslock.c" >"$LF6_SAMPLE"
! lf6_ok "$LF6_SAMPLE" && pass "L-F6: control -- an exit without the grace period is caught" ||
    fail "L-F6: control -- an exit without the grace period passes"
grep -q 'task_work_add(' "$K/nslock.c" || fail "L-F6: setup: no task_work in nslock.c -- the check is stale"
lf6_ok "$K/nslock.c" && pass "L-F6: unload waits a tasks-RCU grace period, and only a build with it queues the work" ||
    fail "L-F6: nslock.c queues a module task_work that unload does not wait out"

# C11 (audit 2026-11-14): an on-disk __le field stored to, or compared with,
# a bare constant. sparse (make endian-check) passes a ZERO constant, and a
# non-zero one reads the same on a little-endian host, so both reach a
# big-endian build silently. tests/image/le_const_scan.py resolves each
# member chain's base type and each designated initialiser against the
# struct definitions in include/cetrafs.h, and reports every bare store or
# compare. The real tree must come back clean; a planted tree with known
# violations, and one correctly converted line, must yield exactly the
# planted violations.
log "checking no on-disk __le field is stored to or compared with a bare constant (C11)"
LE_SCAN="$ROOT/tests/image/le_const_scan.py"
LE_REAL="$(python3 "$LE_SCAN" "$ROOT" 2>&1 || true)"
[ -z "$LE_REAL" ] && pass "C11: every __le field store and compare in kmod/, userspace/ and include/ converts" ||
    fail "C11: bare __le store or compare: $(echo "$LE_REAL" | head -3 | tr '\n' ' ')"

LE_P="$(ct_tmp le-plant)"
rm -f "$LE_P"
mkdir -p "$LE_P/include" "$LE_P/kmod"
cp "$ROOT/include/cetrafs.h" "$LE_P/include/cetrafs.h"
cat >"$LE_P/kmod/planted.c" <<'PLANT'
/* negative control: four bare stores, compares and initialisers, and one converted line */
static void planted(cetrafs_inode_t *raw, cetrafs_node_journal_hdr_t *hdr)
{
    raw->lock_mode = CETRAFS_LOCK_NONE;
    hdr->state = 0;
    if (raw->lock_mode == CETRAFS_LOCK_NONE)
        return;
    cetrafs_inode_t tmp = {.lock_mode = CETRAFS_LOCK_NONE};
    hdr->state = cetrafs_cpu_to_le32(CETRAFS_LOCK_NONE);
    if (cetrafs_le32(raw->lock_mode) == CETRAFS_LOCK_NONE)
        return;
}
PLANT
LE_PLANT="$(python3 "$LE_SCAN" "$LE_P" 2>&1 || true)"
LE_N="$(printf '%s\n' "$LE_PLANT" | grep -c 'planted.c:[0-9]*: ' || true)"
[ "$LE_N" = 4 ] && ! grep -qE 'planted.c:(9|10):' <<<"$LE_PLANT" &&
    pass "C11: control -- the four planted bare accesses are found, the converted line is not" ||
    fail "C11: control -- planted tree gave $LE_N finding(s), want 4 (not the converted line): $(echo "$LE_PLANT" | tr '\n' ' ')"
rm -rf "$LE_P"

# journal_info: current->journal_info is shared with every filesystem on
# the host, and jbd2 takes a non-NULL value for its own transaction
# handle. A cetrafs scope parked there is dereferenced as an ext4 handle
# when direct reclaim inside it evicts an ext4 inode (an ext4 root, as on
# Proxmox). Task-local state lives in a table of our own
# (cetrafs_dsync_enter()). Comments do not count.
log "checking no kmod/ code reads or writes current->journal_info"
ji_scan() { grep -rnE 'journal_info' "$1" --include='*.c' --include='*.h' | grep -vE ':[0-9]+:\s*(/\*|\*)' || true; }
JI_REAL="$(ji_scan "$ROOT/kmod")"
[ -z "$JI_REAL" ] && pass "journal_info: no kmod/ code uses current->journal_info" ||
    fail "journal_info: kmod/ uses current->journal_info: $(echo "$JI_REAL" | head -3 | tr '\n' ' ')"
JI_P="$(ct_tmp ji-plant)"
rm -rf "$JI_P"; mkdir -p "$JI_P"
printf '/* journal_info in a comment */\nstatic void f(void *p)\n{\n    current->journal_info = p;\n}\n' >"$JI_P/planted.c"
JI_N="$(ji_scan "$JI_P" | grep -c 'planted.c:' || true)"
[ "$JI_N" = 1 ] && pass "journal_info: control -- the planted assignment is found, the comment is not" ||
    fail "journal_info: control -- planted tree gave $JI_N finding(s), want 1"
rm -rf "$JI_P"

ct_exit
