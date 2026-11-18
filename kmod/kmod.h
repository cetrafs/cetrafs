/* SPDX-License-Identifier: GPL-2.0-or-later */

#include <linux/mm.h>
#include <linux/workqueue.h>
#include <linux/refcount.h>

#include "cetrafs.h"

#include <linux/moduleparam.h>

/*
 * A TEST ONLY module parameter (audit R23). Each one removes or bends a
 * safety check -- the reader rule, the journal guard, the fence -- for
 * every mount of the module, and they are root-writable at run time
 * because the test suites flip them on a live mount. Declared through
 * this instead of module_param_named(), a write logs the knob and the
 * value it was given and taints the kernel (TAINT_USER), so a volume
 * damaged on a host where one was touched says so in dmesg and in every
 * later oops. tests/image/source_invariants.sh fails on a parameter
 * described as test-only and declared any other way.
 */
/* kmod.c: the one gate every TEST ONLY knob's set goes through -- refused
 * in a release build, warned and tainted otherwise. A knob with its own
 * ops calls it with its own setter (audit 2026-11-15 F-53). */
int cetrafs_test_param_set(const char *val, const struct kernel_param *kp,
                           int (*set)(const char *, const struct kernel_param *));
extern const struct kernel_param_ops cetrafs_test_param_ops_bool;
extern const struct kernel_param_ops cetrafs_test_param_ops_uint;
extern const struct kernel_param_ops cetrafs_test_param_ops_int;
extern const struct kernel_param_ops cetrafs_test_param_ops_ullong;
/* A release build (no CETRAFS_TESTING) shows each knob read-only and
 * refuses every set (kmod.c, M-30). */
#ifdef CETRAFS_TESTING
#define CETRAFS_TEST_PARAM_PERM(perm) (perm)
#else
#define CETRAFS_TEST_PARAM_PERM(perm) 0444
#endif
#define cetrafs_test_param(name, value, type, perm)                                                            \
    param_check_##type(name, &(value));                                                                        \
    module_param_cb(name, &cetrafs_test_param_ops_##type, &(value), CETRAFS_TEST_PARAM_PERM(perm));            \
    __MODULE_PARM_TYPE(name, #type)

/*
 * Blocks are not pages, and on the hardware this is usually built for
 * they happen to be the same size -- which is exactly what makes the
 * confusion invisible.
 *
 * This filesystem addresses in 4 KiB BLOCKS; the page cache indexes in
 * PAGES. On a 4K-page kernel block N is also page N, so handing a block
 * index to a function that wants a page index works by accident. arm64
 * can be built with 16K or 64K pages (CONFIG_ARM64_16K_PAGES and
 * friends), and there the two differ by 4x or 16x: the call silently
 * addresses a quarter, or a sixteenth, of what the caller meant. That
 * is how a block index reached invalidate_inode_pages2_range() in
 * defrag, where the page left behind still mapped blocks that the next
 * line freed.
 *
 * So: convert, never assume. And the assumptions that remain are
 * asserted here rather than left implicit -- nothing in this module
 * checked them at all before.
 */
static_assert(PAGE_SIZE >= CETRAFS_BLOCK_SIZE, "a page must hold at least one whole filesystem block");
static_assert((PAGE_SIZE % CETRAFS_BLOCK_SIZE) == 0, "the page size must be a whole number of filesystem blocks");

/* The page holding file block 'blk' -- for the page-cache helpers that
 * index in pages (invalidate_inode_pages2_range(), filemap_get_folio(),
 * ...). The byte-offset helpers (truncate_inode_pages_range(),
 * unmap_mapping_range(), filemap_write_and_wait_range()) want
 * blk * CETRAFS_BLOCK_SIZE instead and are not this. */
static inline pgoff_t cetrafs_blk_to_pgoff(u64 blk)
{
    return (pgoff_t) ((blk * CETRAFS_BLOCK_SIZE) >> PAGE_SHIFT);
}

/* The page holding the LAST byte of file block 'blk' -- what the
 * inclusive 'end' of a page-index range needs. Rounding outward is
 * required, not sloppy: a page that only partly covers the range still
 * carries buffer_heads for the blocks inside it, so it has to go. */
static inline pgoff_t cetrafs_blk_end_pgoff(u64 blk)
{
    return (pgoff_t) ((blk * CETRAFS_BLOCK_SIZE + CETRAFS_BLOCK_SIZE - 1) >> PAGE_SHIFT);
}

/* Per-operation trace: every lookup/create/iget/statfs and the like.
 * Compiled in but OFF by default -- pr_debug() sites are switched at
 * runtime by the kernel's dynamic debug, per site, file or module:
 *
 *   echo 'module cetrafs +p' > /sys/kernel/debug/dynamic_debug/control
 *
 * This replaced a compile-time -DCETRAFS_DEBUG that the Makefile turned
 * ON unconditionally, so every build traced every operation into dmesg
 * in production. (On a kernel without CONFIG_DYNAMIC_DEBUG, pr_debug
 * compiles out entirely -- the same quiet default, re-enabled only by a
 * -DDEBUG build.) The level argument is kept so the 26 call sites did
 * not have to churn; everything routed here is debug by definition. */
#define fs_debug(level, fmt, ...) pr_debug(fmt, ##__VA_ARGS__)

/* Heartbeat tuning: how often this node refreshes its
 * own Node Registry row (node.c/heartbeat.c), and how long another
 * node's row can go unrefreshed before its ZGs/locks are treated as
 * abandoned and eligible for reclaim (zonegroup.c/lock.c). The stale
 * threshold stays a comfortable multiple of the interval -- a few
 * missed ticks, not one -- so ordinary scheduling jitter or a slow disk
 * never gets mistaken for a dead node. */
/* CETRAFS_HEARTBEAT_INTERVAL_SECS / CETRAFS_NODE_STALE_SECS now live in
 * include/cetrafs.h -- the userspace tools need the same definition of
 * "still mounted somewhere" that cetrafs_node_is_stale() uses. */

/* CETRAFS_EXT_BLOCK_MAX_LEAVES now lives in include/cetrafs.h: it is a
 * property of the on-disk format, and fsck needs it to parse an external
 * extent-leaf block. */

/* Automatic background defrag (defrag.c): kernel-triggered from the
 * last-writer close once a file crosses the extent threshold. Module
 * params (kmod.c): auto_defrag=0 disables, auto_defrag_extents tunes. */
extern bool cetrafs_auto_defrag;
extern unsigned int cetrafs_auto_defrag_min_pct;
extern unsigned int cetrafs_auto_defrag_quiet_secs;
extern unsigned int cetrafs_auto_defrag_min_extents;

/* Fragmentation index (defrag.c): extents expressed as a percentage of
 * the minimum extent count a file of 'nblocks' blocks could possibly
 * occupy, given the per-extent length cap. 100 == perfectly contiguous
 * (even a huge multi-block-group file); 200 == twice the necessary
 * extents, etc. The ideal baseline is what makes raw extent count (or
 * block-group spread) the WRONG trigger -- a big contiguous file scores
 * exactly 100. Pure function; shared by the auto trigger and procfs. */
unsigned int cetrafs_frag_index_pct(u64 nblocks, u32 extents);

// fs.c
int cetrafs_init_fs_context(struct fs_context *fc);
void cetrafs_kill_sb(struct super_block *sb);
/* true: the mount ended stopped (its put_super must write nothing) */
bool cetrafs_free_sb_info(struct super_block *sb);
const cetrafs_superblock_t *cetrafs_sb_raw(struct super_block *sb);

/*
 * Is [lba, lba+count) an address a FILE's blocks may legally occupy?
 *
 * cetrafs_blk_struct_ok_magic() validates the COUNTS and LENGTHS read
 * off the disk -- name_len, value_len, eh_entries -- and says so in its
 * own comment. It never covered the ADDRESSES beside them, and those
 * are trusted absolutely: cetrafs_leaf_array_lookup() turns
 * ee_start_hi/lo straight into the LBA cetrafs_get_block() hands to
 * map_bh(). An extent pointing into the global tables therefore makes
 * an ordinary write(2) land on them. Measured on a 560 MiB image with
 * one inode's extent moved to the inode table and its CRCs restamped:
 * the write destroyed the records of inodes 1..4 and fsck then reported
 * "root is not a dir" -- the volume, and on a shared LUN every node's
 * view of it, gone. Reading the same file returned the root inode's
 * record as file content.
 *
 * Note which side of this the filesystem already got right:
 * __cetrafs_free_data_extent() resolves the BG, checks the region
 * bounds and the ZG ownership before freeing, and fsck's
 * fsck_mark_run() refuses the same extent with "outside every data
 * region". The block about to be FREED was validated; the block about
 * to be WRITTEN was not.
 *
 * No I/O, and O(1) on a never-grown volume, which is what lets it sit
 * on the per-block mapping path (docs/PERFORMANCE.md invariant 1) next
 * to the generation compare already there. Everything below bg_regions_start is a global table --
 * superblock, ZG and BG tables, inode bitmap, inode table, Node
 * Registry, journals, pending-free queues -- so one pair of comparisons
 * fences a file's blocks away from all of them.
 *
 * On a grown volume the box is [bg_regions_start, bg_data_end), and the
 * Block Group table segments earlier grows left in holes inside it are
 * refused by name (cetrafs_sb_lba_run_hits_bg_table(): a loop over the
 * grows, zero iterations on a volume never grown).
 *
 * Inside the box, a run must also lie in ONE Block Group's data region
 * (cetrafs_sb_lba_run_in_bg_data(), from geometry the mount kept in
 * memory): a group's header and bitmap sit between two data regions,
 * and an extent aimed at a bitmap made a file write mark other files'
 * live blocks free for the allocator to hand out (audit 2026-11-14
 * M-40; tests/kernel/extent_aims_bitmap.sh). This used to be left
 * uncaught as "one group's bookkeeping" -- it is every file with a
 * block in that group.
 */
bool cetrafs_sb_lba_run_hits_bg_table(struct super_block *sb, u64 lba, u64 count);
bool cetrafs_sb_lba_run_in_bg_data(struct super_block *sb, u64 lba, u64 count);
int cetrafs_lba_run_past_end(struct super_block *sb, u64 lba, u64 count);
/*
 * 0: [lba, lba+count) is data. -EUCLEAN: it is not, against a layout
 * known to be current -- damage, and the caller marks it so. -EAGAIN:
 * it lies past the end of the layout this node has, and this node could
 * not learn whether a grow put it there (the device smaller than the
 * grown volume until it is rescanned, block 0 unreadable or refused).
 * That is not damage: the caller refuses the I/O (-EIO) and marks
 * nothing, because a mark is sticky and the address may be valid on
 * every node that caught up (GROWFS-LIVE-REVIEW H2).
 */
static inline int cetrafs_lba_run_check(struct super_block *sb, u64 lba, u64 count)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 lo, hi, data_end;

    if (!raw_sb)
        return -EUCLEAN;
    lo = le64_to_cpu(raw_sb->bg_regions_start);
    hi = le64_to_cpu(raw_sb->total_blocks);
    /* A grown volume's data area ends at bg_data_end; past it is the
     * current reserve, holding the newest table segment. */
    data_end = le64_to_cpu(raw_sb->bg_data_end);
    if (data_end && data_end < hi)
        hi = data_end;

    if (!count || lba < lo)
        return -EUCLEAN;
    /* Past the end this node knows of: refused only once the layout is
     * known to be current -- a peer may have grown the volume and
     * allocated in the new space before our heartbeat caught up. Off
     * the per-block budget: a valid address never gets here. */
    if (count > hi || lba > hi - count)
        return cetrafs_lba_run_past_end(sb, lba, count);
    /* And inside the box, one Block Group's data region: not a header
     * or bitmap between two of them, nor a hole an earlier grow left
     * holding an older table segment. */
    return cetrafs_sb_lba_run_in_bg_data(sb, lba, count) ? 0 : -EUCLEAN;
}
/* For callers whose refusal is not destructive and marks nothing (a
 * skipped invalidation, a scrub candidate dropped): "not known to be
 * data" is enough. A caller that marks damage, or that DECIDES something
 * from "this is not data", uses cetrafs_lba_run_check(). */
static inline bool cetrafs_lba_run_is_data(struct super_block *sb, u64 lba, u64 count)
{
    return cetrafs_lba_run_check(sb, lba, count) == 0;
}
int cetrafs_sb_adjust_free_inodes(struct super_block *sb, s64 delta);
int cetrafs_sb_get_free_inodes(struct super_block *sb, u64 *out);
int cetrafs_sb_get_node_id(struct super_block *sb, u32 *out);
bool cetrafs_sb_node_registered(struct super_block *sb);
/*
 * What a watch of a registry row remembers: the beat, and WHO beat it.
 * hb_seq alone restarts at 1 when a row is registered afresh, so a
 * sample of one holder could match another's beat and read "has not
 * moved". node_uuid names the machine (for a REPAIR claim, its per-claim
 * nonce); incarnation names the mount session, drawn anew at every
 * registration and re-attach (format 0x000A). A row is "the same as
 * sampled" only when all three match. A fresh registration can redraw
 * the old incarnation by chance: 1 in 2^32, and only together with an
 * exact hb_seq collision.
 */
struct cetrafs_row_mark {
    u64 hb_seq;
    u32 incarnation;
    u8 uuid[CETRAFS_NODE_UUID_LEN];
};

static inline void cetrafs_row_mark_of(struct cetrafs_row_mark *m, const cetrafs_node_entry_t *ne)
{
    m->hb_seq = cetrafs_le64(ne->hb_seq);
    m->incarnation = cetrafs_le32(ne->incarnation);
    memcpy(m->uuid, ne->node_uuid, CETRAFS_NODE_UUID_LEN);
}

static inline bool cetrafs_row_mark_same(const struct cetrafs_row_mark *m, const cetrafs_node_entry_t *ne)
{
    return m->hb_seq == cetrafs_le64(ne->hb_seq) && m->incarnation == cetrafs_le32(ne->incarnation) &&
           !memcmp(m->uuid, ne->node_uuid, CETRAFS_NODE_UUID_LEN);
}

/* Observer-local peer liveness: has this row stood still (same mark)
 * for longer than its stale window of OUR clock? Uses no cross-node
 * timestamp, so clock skew cannot affect it. */
bool cetrafs_sb_peer_progress_stale(struct super_block *sb, u32 node_id, const cetrafs_node_entry_t *ne);
void cetrafs_sb_peer_watch_forget(struct super_block *sb, u32 node_id);
bool cetrafs_sb_peer_judged_mark(struct super_block *sb, u32 node_id, struct cetrafs_row_mark *out);
void cetrafs_sb_peer_note_fenced(struct super_block *sb, u32 node_id, const struct cetrafs_row_mark *m);
bool cetrafs_sb_peer_fenced_mark(struct super_block *sb, u32 node_id, struct cetrafs_row_mark *out);
void cetrafs_sb_set_incarnation(struct super_block *sb, u32 inc);
u32 cetrafs_sb_incarnation(struct super_block *sb);
void cetrafs_node_report_clock_skew(struct super_block *sb);
void cetrafs_node_seed_peer_watch(struct super_block *sb);
bool cetrafs_cluster_all_advertise(struct super_block *sb, u32 cap);
int cetrafs_node_my_uuid(u8 out[CETRAFS_NODE_UUID_LEN]);
int cetrafs_node_live_peer_exists(struct super_block *sb, const u8 *my_uuid, bool *out_exists);
int cetrafs_node_repair_claim_exists(struct super_block *sb, bool *out_exists, char *out_label, size_t label_sz);
/* The file-lock mode a LIVE peer advertises (the first mounter's choice),
 * or CETRAFS_FLOCK_MODE_UNSET if no live peer -- so a joining node inherits
 * the cluster's mode and the first mounter leads. See node.c. */
int cetrafs_node_cluster_file_lock_mode(struct super_block *sb, const u8 *my_uuid, u32 my_mode, u32 *out_mode);
/* Post-registration re-check: does any live peer now disagree with our mode?
 * Closes the simultaneous-mount race the pre-registration scan cannot. */
int cetrafs_node_file_lock_mode_conflict(struct super_block *sb, const u8 *my_uuid, u32 my_mode, bool *out_conflict);
/* Post-registration re-check for a no-CAW volume: is ANY live foreign row
 * registered? Closes the simultaneous-mount race the pre-registration gate
 * cannot (two racers can each pass it before the other's row exists). */
int cetrafs_node_single_mounter_conflict(struct super_block *sb, const u8 *my_uuid, bool *out_conflict);
int cetrafs_node_nocaw_peer_exists(struct super_block *sb, const u8 *my_uuid, bool *out_exists);
extern unsigned int cetrafs_stale_secs;
extern bool cetrafs_stale_param_unbounded; /* node.c, TEST ONLY */
extern unsigned int cetrafs_hb_interval_secs;
/* sb->s_max_links: half the u32 nlink field, see fs.c */
#define CETRAFS_MAX_LINKS 0x7fffffffu
/* fs.c: the two above as a mount may take them -- bounded */
unsigned int cetrafs_param_hb_interval_secs(void);
unsigned int cetrafs_param_stale_secs(void);
u64 cetrafs_sb_get_fence_epoch(struct super_block *sb);
void cetrafs_sb_set_fence_epoch(struct super_block *sb, u64 epoch);
int cetrafs_sb_get_node_uuid(struct super_block *sb, u8 out[CETRAFS_NODE_UUID_LEN]);
struct cetrafs_journal *cetrafs_sb_get_journal(struct super_block *sb);
struct xarray *cetrafs_sb_deferred(struct super_block *sb);
struct cetrafs_defrag *cetrafs_sb_get_defrag(struct super_block *sb);
void cetrafs_sb_cache_zg_ownership(struct super_block *sb, u32 zg_id);
void cetrafs_sb_uncache_zg_ownership(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_owned_cached(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_note_unreadable(struct super_block *sb, u32 zg_id);
u32 cetrafs_sb_zg_unreadable_count(struct super_block *sb);
extern bool cetrafs_zg_unreadable_fatal;
bool cetrafs_sb_zg_pf_backoff_active(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_pf_residue(struct super_block *sb, u32 zg_id);
void cetrafs_sb_zg_pf_set_residue(struct super_block *sb, u32 zg_id, bool left);
bool cetrafs_sb_pf_full_sweep_due(struct super_block *sb, u32 every);
bool cetrafs_sb_zg_pf_note_drop(struct super_block *sb, u32 zg_id, u32 runs, u64 blocks, unsigned int backoff_ms);
bool cetrafs_sb_zg_pf_take_drops(struct super_block *sb, u32 zg_id, u64 *runs, u64 *blocks);
bool cetrafs_sb_owns_any_zg(struct super_block *sb);
bool cetrafs_sb_bg_is_ours(struct super_block *sb, u32 bg_id);
u32 cetrafs_sb_alloc_cursor(struct super_block *sb);
void cetrafs_sb_set_alloc_cursor(struct super_block *sb, u32 bg_id);
/* fs.c: the error policy -- docs/internal/ERRORS.md. A stopped mount
 * (any cause) does no I/O and refuses every VFS access; cetrafs_sb_is_fenced()
 * is true for every cause, not only a peer's fence. */
enum cetrafs_stop_cause {
    CETRAFS_STOP_NONE = 0,
    CETRAFS_STOP_FENCED,      /* a peer revoked our Node Registry lease */
    CETRAFS_STOP_LEASE,       /* our own lease ran out before a renewal landed */
    CETRAFS_STOP_ERROR,       /* cetrafs_sb_fatal(): we no longer know what is on the device */
    CETRAFS_STOP_CORRUPTION,  /* damaged metadata, under corruption=stop */
    CETRAFS_STOP_MANUAL,      /* FS_IOC_SHUTDOWN or procfs controls 'shutdown' */
    CETRAFS_STOP_DEVICE_GONE, /* the block device went away */
};
void cetrafs_sb_stop(struct super_block *sb, enum cetrafs_stop_cause cause, const char *reason);
void cetrafs_sb_fence(struct super_block *sb, const char *reason);
bool cetrafs_sb_is_fenced(struct super_block *sb);
/* fs.c: is the caller the lease renewal itself (A-4: it never waits for space)? */
bool cetrafs_sb_in_renewal(struct super_block *sb);
const char *cetrafs_sb_stop_cause_name(struct super_block *sb);
__printf(2, 3) void cetrafs_sb_fatal(struct super_block *sb, const char *fmt, ...);
void cetrafs_sb_corrupt(struct super_block *sb, u64 ino);
void cetrafs_sb_corrupt_inode(struct inode *inode);
void cetrafs_sb_corrupt_owner(struct super_block *sb, u64 ino, u64 generation);
bool cetrafs_tree_damage_unowned(void); /* ioutil.c, TEST ONLY knob */
unsigned int cetrafs_sb_corruptions(struct super_block *sb);
void cetrafs_sb_record_damage(struct super_block *sb);
u64 cetrafs_sb_fsck_needed(struct super_block *sb, u32 *out_node);
void cetrafs_sb_copy_status(cetrafs_superblock_t *dst, const cetrafs_superblock_t *src);
bool cetrafs_sb_inode_damaged(struct inode *inode);
void cetrafs_sb_ino_reborn(struct super_block *sb, u64 ino);
bool cetrafs_sb_errors_panic(struct super_block *sb);
bool cetrafs_sb_corruption_stop(struct super_block *sb);
bool cetrafs_sb_posix_lock_local(struct super_block *sb);
int cetrafs_read_gate(struct super_block *sb);
int cetrafs_write_gate(struct inode *inode);
/* Older uapi headers lack the generic name; ext4, XFS and f2fs used
 * this same number before it was one. */
#ifndef FS_IOC_SHUTDOWN
#define FS_IOC_SHUTDOWN _IOR('X', 125, __u32)
#define FS_SHUTDOWN_FLAGS_DEFAULT 0x0
#define FS_SHUTDOWN_FLAGS_LOGFLUSH 0x1
#define FS_SHUTDOWN_FLAGS_NOLOGFLUSH 0x2
#endif
long cetrafs_shutdown_ioctl(struct super_block *sb, u32 __user *argp);
/* inode.c */
int cetrafs_getattr(struct mnt_idmap *idmap, const struct path *path, struct kstat *stat, u32 request_mask,
                    unsigned int query_flags);
u64 cetrafs_lease_clock(void);
void cetrafs_sb_lease_renewed(struct super_block *sb, u64 t0, unsigned int lease_secs);
unsigned int cetrafs_sb_lease_secs(unsigned int imin, unsigned int imax, unsigned int smin);
void cetrafs_sb_mount_lease(struct super_block *sb, u64 t0);
u32 cetrafs_peer_window_floor_secs(u32 interval_secs, u32 stale_secs);
int cetrafs_sb_mount_beat(struct super_block *sb);
bool cetrafs_sb_defrag_draining(struct super_block *sb);
bool cetrafs_sb_queue_cold(struct super_block *sb, struct work_struct *w);
u64 cetrafs_lock_close_deferral_count(void);
void cetrafs_sb_cold_close(struct super_block *sb);
#define CETRAFS_COLD_RETRIES_MAX 8u /* heartbeat ticks a failed reconcile is retried for */
bool cetrafs_sb_cold_park(struct super_block *sb, struct list_head *e);
bool cetrafs_sb_cold_retry_begin(struct super_block *sb);
void cetrafs_sb_cold_retry_end(struct super_block *sb);
void cetrafs_sb_cold_take(struct super_block *sb, struct list_head *out);
void cetrafs_sb_cold_unpark(struct super_block *sb, struct list_head *e);
unsigned int cetrafs_sb_cold_parked_count(struct super_block *sb);
/* lock.c */
void cetrafs_lock_retry_cold(struct super_block *sb);
void cetrafs_lock_cold_drop_parked(struct super_block *sb, struct list_head *parked);
/* Per-mount defragmentation switches (procfs.c's 'controls' file).
 * _defrag_enabled() gates defragmentation entirely, the ioctl included;
 * _auto_defrag_enabled() gates only the background janitor. */
bool cetrafs_sb_defrag_enabled(struct super_block *sb);
bool cetrafs_sb_auto_defrag_enabled(struct super_block *sb);
bool cetrafs_sb_file_lock_enabled(struct super_block *sb);
/* fs.c: block 0's copy as found at mount (A-7) */
#define CETRAFS_SB_COPY_OK    0
#define CETRAFS_SB_COPY_STALE 1
#define CETRAFS_SB_COPY_BAD   2
const char *cetrafs_sb_copy_state_name(struct super_block *sb);
void cetrafs_sb_row_silent_note(struct super_block *sb, u32 idx, const cetrafs_node_entry_t *ne);
bool cetrafs_sb_row_silent(struct super_block *sb, u32 idx, const cetrafs_node_entry_t *ne);
extern atomic_t cetrafs_sb_kills; /* fs.c: kill_sb calls since load */
extern bool cetrafs_ro_mount_leads; /* fs.c, TEST ONLY */
void cetrafs_sb_set_defrag_enabled(struct super_block *sb, bool on);
/* UNMAP state (fs.c; see cetrafs_sb_info.discard_enabled). */
bool cetrafs_sb_discard_enabled(struct super_block *sb);
void cetrafs_sb_set_discard_enabled(struct super_block *sb, bool on);
struct mutex *cetrafs_sb_trim_mutex(struct super_block *sb);
void cetrafs_sb_set_trim_claim(struct super_block *sb, u32 bg_id, u64 lba, u64 count);
bool cetrafs_sb_trim_holds(struct super_block *sb, u64 lba);
/* Block Groups kept drained after a hand-back discard of unknown outcome. */
bool cetrafs_sb_bg_discard_pending(struct super_block *sb, u32 bg_id);
bool cetrafs_sb_set_bg_discard_pending(struct super_block *sb, u32 bg_id, bool on);
unsigned int cetrafs_sb_discard_pending_count(struct super_block *sb);
void cetrafs_sb_set_auto_defrag_enabled(struct super_block *sb, bool on);
/* Cluster timing for THIS mount (procfs 'controls'); the module params
 * are the defaults. */
unsigned int cetrafs_sb_hb_interval_secs(struct super_block *sb);
unsigned int cetrafs_sb_stale_secs(struct super_block *sb);
bool cetrafs_sb_half_landed_aged(struct super_block *sb, u64 ino, u32 ns_crc);
void cetrafs_sb_half_landed_forget(struct super_block *sb, u64 ino);
void cetrafs_sb_set_hb_interval_secs(struct super_block *sb, unsigned int v);
void cetrafs_sb_set_stale_secs(struct super_block *sb, unsigned int v);
const struct cetrafs_caw_info *cetrafs_sb_caw(struct super_block *sb);
bool cetrafs_sb_caw_available(struct super_block *sb);
bool cetrafs_sb_mount_has_caw(struct super_block *sb);
void cetrafs_sb_cas_lock(struct super_block *sb);
int cetrafs_sb_cas_lock_killable(struct super_block *sb);
void cetrafs_sb_cas_unlock(struct super_block *sb);
void cetrafs_sb_alloc_lock(struct super_block *sb);
void cetrafs_sb_alloc_unlock(struct super_block *sb);
bool cetrafs_sb_zg_claim_lock(struct super_block *sb, unsigned int *nofs);
int cetrafs_sb_zg_claim_lock_killable(struct super_block *sb, unsigned int *nofs);
bool cetrafs_sb_zg_claim_held(struct super_block *sb);
void cetrafs_sb_zg_claiming_set(struct super_block *sb, u32 zg_id, bool on);
bool cetrafs_sb_zg_claiming(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_any_claiming(struct super_block *sb);
int cetrafs_sb_zg_claiming_wait(struct super_block *sb);
bool cetrafs_sb_zg_claim_busy(struct super_block *sb);
bool cetrafs_sb_proc_closing(struct super_block *sb);
void cetrafs_sb_check_device_size(struct super_block *sb);
void cetrafs_sb_zg_claim_unlock(struct super_block *sb, unsigned int nofs);
void cetrafs_sb_release_lock(struct super_block *sb);
void cetrafs_sb_release_unlock(struct super_block *sb);
void cetrafs_sb_release_wait(struct super_block *sb);
int cetrafs_sb_release_read_lock(struct super_block *sb);
void cetrafs_sb_release_read_unlock(struct super_block *sb);
int cetrafs_sb_release_seq(struct super_block *sb);
bool cetrafs_sb_release_ended_since(struct super_block *sb, int seq);
u64 cetrafs_enospc_rescan_count(void);
u64 cetrafs_alloc_adopt_skip_count(void);
void cetrafs_sb_zg_want_adopt(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_adopt_is_wanted(struct super_block *sb, u32 zg_id);
void cetrafs_sb_zg_adopt_done(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_has_heartbeat(struct super_block *sb);
bool cetrafs_sb_zg_adopt_wait(struct super_block *sb, u32 zg_id);
void cetrafs_zg_adopt_wanted(struct super_block *sb, u32 my_node_id);
u64 cetrafs_zg_claim_replay_deferral_count(void);
u64 cetrafs_zg_claim_replay_skip_count(void);
bool cetrafs_sb_in_reclaim_lock(struct super_block *sb);
bool cetrafs_sb_ro_refuses(struct super_block *sb, const char *what);
void cetrafs_inode_set_wb_failed(struct inode *inode, bool failed);
/* lock.c: the shared-lock O_DIRECT overwrite count (file.c). */
void cetrafs_inode_shared_dio_adjust(struct inode *inode, int delta);
bool cetrafs_inode_shared_dio_active(struct inode *inode);
bool cetrafs_inode_wb_failed(struct inode *inode);
u64 cetrafs_sb_stamp_ns(struct super_block *sb);
u64 cetrafs_sb_stamp_now(struct super_block *sb);
bool cetrafs_sb_own_seq_older(struct super_block *sb, u64 a, u64 b, u64 noted_at);
void cetrafs_sb_note_unclean_reattach(struct super_block *sb);
bool cetrafs_sb_unclean_reattach(struct super_block *sb);
/* inode.c: advance a record's namespace stamp (dirent_seq) */
void cetrafs_ns_stamp_advance(cetrafs_inode_t *rec);
/* as_node: whose change the new file_seq says it is (the replayed node). */
int cetrafs_inode_advance_change_stamp(struct super_block *sb, u64 ino, u64 generation, bool dir, u32 as_node);
/* lock.c: clear every claim a previous incarnation of this node left */
int cetrafs_lock_sweep_own_claims(struct super_block *sb, u32 my_node_id);
u64 cetrafs_deferred_orphaned_count(void);
u64 cetrafs_deferred_adopted_count(void);
int cetrafs_lock_resweep_own_claims(struct super_block *sb, u32 my_node_id, bool (*stop)(struct super_block *));
u64 cetrafs_late_claims_cleared_count(void);
/* lock.c: clear a dead node's claims on a deleted record (the orphan scrub) */
int cetrafs_lock_clear_dead_claims(struct super_block *sb, u64 ino, u32 my_node_id);
/* Live speculative-run registry: lock.c publishes, scrub.c reads. A
 * reserved run is bitmap-set and referenced by no extent, which is
 * exactly what the scrub frees -- see cetrafs_sb_info.resv_list.
 *
 * One span per inode, embedded (no allocation). The list and its lock
 * live entirely in fs.c: every entry point below takes the lock itself
 * and tolerates a superblock whose s_fs_info is already gone, because
 * the mount-failure unwind evicts inodes after fill_super has torn it
 * down. */
struct cetrafs_resv_span {
    struct list_head link;
    u64 start;
    u32 count;
};
void cetrafs_resv_publish(struct super_block *sb, struct cetrafs_resv_span *span, u64 start, u32 count);
void cetrafs_resv_unpublish(struct super_block *sb, struct cetrafs_resv_span *span);
bool cetrafs_resv_covers(struct super_block *sb, u64 lba);

/* FITRIM claims (alloc.c): a free run held, bits set, while discard.c
 * discards it. */
struct cetrafs_trim_run {
    struct cetrafs_resv_span span;
    u64 lba;
    u64 count;
    u32 bg_id;
    u32 owner_zg;
    bool claimed;
};
int cetrafs_trim_claim_next(struct super_block *sb, u32 bg_id, u64 *cursor, u64 minlen, u64 maxlen,
                            struct cetrafs_trim_run *run);
int cetrafs_trim_hold_durable(struct super_block *sb, const struct cetrafs_trim_run *run);
void cetrafs_trim_release(struct super_block *sb, struct cetrafs_trim_run *run, bool keep);
u64 cetrafs_trim_leaked_count(void);
int cetrafs_bg_data_region(struct super_block *sb, u32 bg_id, u64 *out_start, u64 *out_count, u32 *out_owner_zg);
int cetrafs_bg_id_of_lba(struct super_block *sb, u64 lba, u32 *out_bg_id);

/* discard.c */
struct fstrim_range;
bool cetrafs_discard_supported(struct super_block *sb);
int cetrafs_zeroout_issue(struct super_block *sb, u64 lba, u64 count, bool unmap);
int cetrafs_discard_space_probe(struct super_block *sb, unsigned int *tries); /* BM-15, F-57, F-58 */
/* One space probe at a time per volume, its answer shared by every failed
 * O_DIRECT write that waited for it (discard.c, F-58). */
struct cetrafs_space_probe_state {
    struct mutex mutex;  /* one probe at a time */
    u64 done;            /* probes completed, under mutex (read lockless) */
    int verdict;         /* the last one's answer: -ENOSPC or 0 */
    unsigned long at;    /* jiffies it was reached */
    atomic_t trim_yield; /* a probe waiting for trim_mutex: its holders let it in between runs */
};
struct cetrafs_space_probe_state *cetrafs_sb_space_probe(struct super_block *sb); /* fs.c */
bool cetrafs_discard_handback_would_send(struct super_block *sb, bool force);
int cetrafs_discard_handback(struct super_block *sb, u32 bg_id, unsigned long *pass_started, bool pending,
                             bool force, bool *discarded);
long cetrafs_fitrim_ioctl(struct file *file, struct fstrim_range __user *arg);
u64 cetrafs_discard_cmds_count(void);
u64 cetrafs_discard_blocks_count(void);
u64 cetrafs_discard_errors_count(void);
u64 cetrafs_discard_refused_count(void);
u64 cetrafs_discard_handback_count(void);
u64 cetrafs_discard_handback_deferred_count(void);
u64 cetrafs_discard_handback_unknown_count(void);
/* Inline discard (`-o discard`): frees noted, a worker discards them. */
struct cetrafs_inline_discard;
struct cetrafs_inline_discard *cetrafs_inline_discard_create(struct super_block *sb, bool on);
void cetrafs_inline_discard_close(struct cetrafs_inline_discard *d);
void cetrafs_inline_discard_destroy(struct cetrafs_inline_discard *d);
bool cetrafs_inline_discard_on(struct super_block *sb);
void cetrafs_inline_discard_set(struct super_block *sb, bool on);
void cetrafs_inline_discard_pressure(struct super_block *sb);
void cetrafs_inline_discard_note(struct super_block *sb, u32 bg, u64 lba, u32 count);
void cetrafs_inline_discard_counts(struct super_block *sb, u64 *queued, u64 *dropped, u64 *gave_up, u64 *cmds,
                                   u64 *blocks);
struct cetrafs_inline_discard *cetrafs_sb_inline_discard(struct super_block *sb); /* fs.c */
/* BG free counts (v0x0004): accrued per BG, applied by one epoch-guarded
 * CAS per dirty BG at the durability boundaries -- never left dirty in
 * the buffer cache (background writeback could land a stale count on a
 * stealing peer's fresh reconcile). See fs.c's bg_free_delta comment. */
/* Un-durable data-bitmap allocations: marked by the allocator, drained
 * at every durability boundary BEFORE the reference is published. See
 * cetrafs_bg_chunk.bmap_alloc_dirty. */
void cetrafs_sb_note_bmap_alloc(struct super_block *sb, u32 bg_id);
bool cetrafs_sb_take_bmap_alloc_dirty(struct super_block *sb, u32 bg_id);
u64 cetrafs_bmap_gate_walks_count(void);
u64 cetrafs_sweep_name_walk_count(void);
u64 cetrafs_bmap_gate_entry_count(void);
u64 cetrafs_pf_apply_bmap_lookup_count(void);
u64 cetrafs_run_claim_bmap_lookup_count(void);
u64 cetrafs_dio_privs_xattr_reads_count(void);
u32 cetrafs_sb_next_bmap_alloc_dirty(struct super_block *sb, u32 from);
u32 cetrafs_sb_next_release_check(struct super_block *sb, u32 from);
void cetrafs_sb_set_release_check(struct super_block *sb, u32 bg_id, bool on);
unsigned int cetrafs_sb_waive_pending_discards(struct super_block *sb);
bool cetrafs_sb_bg_discard_waived(struct super_block *sb, u32 bg_id);
u32 cetrafs_sb_next_discard_pending(struct super_block *sb, u32 from);
u64 cetrafs_release_visit_count(void);
int cetrafs_sb_bmap_flush_begin(struct super_block *sb);
void cetrafs_sb_bmap_flush_end(struct super_block *sb);
bool cetrafs_sb_bmap_flush_inflight(struct super_block *sb);
int cetrafs_alloc_flush_bitmaps(struct super_block *sb);
bool cetrafs_sb_bmap_alloc_any_dirty(struct super_block *sb);
int cetrafs_alloc_flush_bitmaps_if_dirty(struct super_block *sb);
void cetrafs_sb_accrue_bg_free(struct super_block *sb, u32 bg_id, s64 delta);
u64 cetrafs_sb_bg_alloc_seq(struct super_block *sb, u32 bg_id);
u32 cetrafs_sb_bg_flight_gen(struct super_block *sb, u32 bg_id);
bool cetrafs_sb_bg_free_settle(struct super_block *sb, u32 bg_id, u32 gen, s64 desc, s64 *out);
int cetrafs_sb_bg_flush_lock(struct super_block *sb, u32 bg_id);
void cetrafs_sb_bg_flush_unlock(struct super_block *sb, u32 bg_id);
s64 cetrafs_sb_bg_flight_begin(struct super_block *sb, u32 bg_id, s64 desc);
void cetrafs_sb_bg_flight_end(struct super_block *sb, u32 bg_id, s64 requeue);
s64 cetrafs_sb_bg_flight_begin_value(struct super_block *sb, u32 bg_id, s64 value);
bool cetrafs_sb_bg_delta_pending(struct super_block *sb, u32 bg_id);
u64 cetrafs_release_held_delta_count(void);
void cetrafs_sb_bg_flight_settle_end(struct super_block *sb, u32 bg_id, s64 requeue);
u64 cetrafs_sb_bg_epoch(struct super_block *sb, u32 bg_id);
s64 cetrafs_sb_set_bg_epoch(struct super_block *sb, u32 bg_id, u64 seq);
void cetrafs_sb_set_bg_epoch_keep(struct super_block *sb, u32 bg_id, u64 seq);
void cetrafs_sb_accrue_zg_free(struct super_block *sb, u32 zg_id, s64 delta);

/* fs.c: namespace locks whose release did not commit, retried by the
 * heartbeat rather than left for a stale-reclaim that will not come
 * while this node is alive. */
struct cetrafs_nsrel_pending {
    u64 ino;
    u64 generation;
};
void cetrafs_sb_nslock_defer(struct super_block *sb, u64 ino, u64 generation);
u32 cetrafs_sb_nslock_take_deferred(struct super_block *sb, struct cetrafs_nsrel_pending *out, u32 max);
void cetrafs_sb_nslock_retry_begin(struct super_block *sb);
void cetrafs_sb_nslock_retry_end(struct super_block *sb);
int cetrafs_sb_nslock_forget(struct super_block *sb, u64 ino, u64 *generation);
/* nslock.c: one retry pass over them, called from the heartbeat tick. */
void cetrafs_nslock_retry_deferred(struct super_block *sb);
/* fs.c + lock.c: last-writer closes whose publish or lock clear failed,
 * finished by the heartbeat. */
#define CETRAFS_FLOCK_DEFERRED_MAX 32
void cetrafs_sb_flock_defer(struct super_block *sb, u64 ino, u64 generation);
u32 cetrafs_sb_flock_take_deferred(struct super_block *sb, struct cetrafs_nsrel_pending *out, u32 max);
void cetrafs_lock_retry_deferred(struct super_block *sb);
/* fs.c + lock.c: presence bits whose withdraw failed, finished by the
 * heartbeat. */
#define CETRAFS_PRESENCE_DEFERRED_MAX 32
void cetrafs_sb_presence_defer(struct super_block *sb, u64 ino, u64 generation);
u32 cetrafs_sb_presence_take_deferred(struct super_block *sb, struct cetrafs_nsrel_pending *out, u32 max);
/* An inode-number reclaim claim (RELEASE, or a create's BIRTH_ABORT)
 * whose give-back did not land. Kept: the record stays locked by this
 * node, every scrub skips it, peers abandon the number -- for good, while
 * this node beats. Retried by the heartbeat (cetrafs_alloc_retry_reclaim()).
 * 'seq' is the claim's stamp, which a RELEASE must still match. */
struct cetrafs_reclaim_pending {
    u64 ino;
    u64 generation;
    u64 seq;
    int mode;
};
#define CETRAFS_RECLAIM_DEFERRED_MAX 32
void cetrafs_sb_reclaim_defer(struct super_block *sb, const struct cetrafs_reclaim_pending *p);
u32 cetrafs_sb_reclaim_take_deferred(struct super_block *sb, struct cetrafs_reclaim_pending *out, u32 max);
void cetrafs_alloc_retry_reclaim(struct super_block *sb); /* alloc.c */
void cetrafs_lock_retry_presence(struct super_block *sb);
s64 cetrafs_sb_take_zg_free_delta(struct super_block *sb, u32 zg_id);
int cetrafs_flush_dirty_free_counts(struct super_block *sb);
/* Zone Groups carrying an unapplied free-count delta. A delta must
 * never outlive ownership of its ZG -- see fs.c. */
u32 cetrafs_sb_pending_zg_deltas(struct super_block *sb);
bool cetrafs_sb_zg_delta_pending(struct super_block *sb, u32 zg_id);
u32 cetrafs_sb_zg_flight_gen(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_free_settle(struct super_block *sb, u32 zg_id, u32 gen, s64 rec, s64 *out);
int cetrafs_sb_zg_write_lock(struct super_block *sb, u32 zg_id);
void cetrafs_sb_zg_write_unlock(struct super_block *sb, u32 zg_id);
void cetrafs_sb_zg_flight_image(struct super_block *sb, u32 zg_id, s64 cur);
u64 cetrafs_sb_total_data_blocks(struct super_block *sb);
loff_t cetrafs_sb_max_file_size(struct super_block *sb);
int cetrafs_sb_capacity_for(struct super_block *sb, loff_t end, loff_t *cap);
int cetrafs_fill_super(struct super_block *sb, struct fs_context *fc);

// caw.c -- generic cross-transport COMPARE AND WRITE (ATS) primitive +
// capability discovery. STANDALONE: nothing wires these in yet.
enum cetrafs_caw_class {
    CETRAFS_CAW_NONE = 0,
    CETRAFS_CAW_SCSI,
    CETRAFS_CAW_NVME,
};
struct cetrafs_caw_info {
    enum cetrafs_caw_class klass;
    unsigned int logical_block_size; /* bytes */
    unsigned int max_caw_blocks;     /* atomic compare-and-write length, in logical blocks; 0 = unsupported */
};
int cetrafs_caw_discover(struct block_device *bdev, struct cetrafs_caw_info *out);

// dmpath.c -- what lies under a device-mapper node (multipath above all).
// dm has no scsi_device and no passthrough path for a CDB, so caw.c sends
// its COMPARE AND WRITE to a SCSI device underneath while ordinary I/O
// keeps going through dm. This only enumerates; caw.c decides usability.
#define CETRAFS_DM_MAX_SLAVES 16
#define CETRAFS_DM_MAX_DEPTH 3
int cetrafs_dm_underlying(struct block_device *bdev, dev_t *out, unsigned int max, unsigned int *out_n);
struct scsi_device;
/* A referenced scsi_device to send 'bdev's passthrough commands to when
 * bdev itself is not SCSI; NULL if none is usable. caller scsi_device_put()s. */
int cetrafs_dmpath_probe(struct block_device *bdev, struct scsi_device **out);
struct scsi_device *cetrafs_dmpath_sdev(struct block_device *bdev, bool killable);
void cetrafs_dmpath_forget(struct block_device *bdev);
/* Report that a path just failed a command with a TRANSPORT error, so the
 * next resolution picks a different one. Never called for a MISCOMPARE. */
void cetrafs_dmpath_failed(struct block_device *bdev, struct scsi_device *sdev);
/* caw.c, shared with dmpath.c: the scsi_device a bdev IS, if any. */
struct scsi_device *cetrafs_caw_get_sdev(struct block_device *bdev);
/* Mutator for cetrafs_cas_record(): edit the current CAS-region image in
 * place. Return 0 to swap it in, >0 for "no change needed" (succeeds
 * without writing), <0 to abort with that error. May be called more than
 * once -- a lost race re-reads and re-invokes it with the new image. */
typedef int (*cetrafs_cas_fn)(void *image, unsigned int len, void *priv);
int cetrafs_cas_record(struct super_block *sb, u64 fs_lba, cetrafs_cas_fn mutate, void *priv);
int cetrafs_cas_record_nointr(struct super_block *sb, u64 fs_lba, cetrafs_cas_fn mutate, void *priv);
unsigned int cetrafs_cas_region_size(struct super_block *sb);
u64 cetrafs_cas_miscompare_count(void);
u64 cetrafs_cas_undecided_nap_count(void);
/* Device round trips an operation costs, made countable because neither
 * is visible in /sys/block: a CAW is a passthrough request the block
 * layer does not account, and a record write is one 4 KiB write among
 * many. */
u64 cetrafs_cas_op_count(void);
void cetrafs_cas_op_counted(void);
u64 cetrafs_record_write_count(void);
/* fdatasync's task-local scope (file.c, inode.c): see cetrafs_sync_inode_meta(). */
struct cetrafs_dsync_scope {
    struct list_head node;
    struct task_struct *task;
    struct inode *inode;
    bool times_dropped; /* a time-only change was left unpublished in this scope */
};
void cetrafs_dsync_enter(struct cetrafs_dsync_scope *s);
void cetrafs_dsync_exit(struct cetrafs_dsync_scope *s);
bool cetrafs_dsync_drop_times(struct inode *inode);
/* Foreign-free appends to a peer's pending-free queue (zonegroup.c). Zero
 * on a single-node/loop volume by construction; the only confirmation the
 * append path runs on a real multi-node volume. */
u64 cetrafs_pending_free_append_count(void);
u64 cetrafs_pf_append_read_count(void);
u64 cetrafs_pending_free_entry_count(void);
/* Replay-claim outcomes (journal.c): how many of a dead peer's journal
 * areas this node replayed, and how many it found another node already
 * on. The loser of that race returns success silently, so the decline
 * count is the only evidence the race occurred. */
u64 cetrafs_journal_replay_count(void);
u64 cetrafs_journal_replay_decline_count(void);
u64 cetrafs_journal_replay_refused_count(void);
u64 cetrafs_journal_replay_torn_count(void);
u64 cetrafs_journal_replay_live_kept_count(void);
u64 cetrafs_journal_replay_own_opener_count(void);
u64 cetrafs_journal_replay_scoped_ok_count(void);
u64 cetrafs_journal_replay_kept_count(void);
u64 cetrafs_evict_rereads_changed_count(void);
u64 cetrafs_bmap_flush_batch_count(void);
u64 cetrafs_flock_backout_count(void);
u64 cetrafs_xattr_inplace_fallback_count(void);
extern bool cetrafs_read_trust_writer_defers; /* lock.c, TEST ONLY */
extern bool cetrafs_pf_force_foreign;
u64 cetrafs_pf_full_scans_count(void);
u64 cetrafs_pf_drain_blocks_count(void);
u64 cetrafs_pf_drain_sweeps_count(void);
u64 cetrafs_pf_drain_held_count(void);
u64 cetrafs_pf_drain_busy_waits_count(void);
u64 cetrafs_bg_recount_count(void);
u64 cetrafs_pf_drop_runs_count(void);
u64 cetrafs_pf_drop_blocks_count(void);
u64 cetrafs_journal_replay_skipped_count(void);
u64 cetrafs_journal_replay_applied_count(void);

/* file.c: FS_IOC_FIEMAP, shared with dir.c's inode_operations table */
int cetrafs_fiemap(struct inode *inode, struct fiemap_extent_info *fi, u64 start, u64 len);

/* ---- extwalk.c: the one traversal of an extent tree ---- */
/* How a walk reads its external blocks: the file's reader or writer trust
 * rule (cetrafs_read_tree_bh_for()), or the scrub's, which has no inode. */
enum cetrafs_tw_read {
    CETRAFS_TW_READER,
    CETRAFS_TW_WRITER,
    CETRAFS_TW_SCRUB,       /* cached: a proposing pass */
    CETRAFS_TW_SCRUB_FRESH, /* forced fresh, tail-checked: a deciding pass */
};

/* Hook answers. A negative errno aborts the walk with it. */
#define CETRAFS_TW_DESCEND 0 /* read this child and walk it */
#define CETRAFS_TW_STOP    1 /* end the walk; cetrafs_tree_walk() returns this */
#define CETRAFS_TW_SKIP    2 /* leave this child unread */

#define CETRAFS_TW_SKIP_UNREADABLE 0x1 /* an unreadable child is skipped, w->unknown set */
#define CETRAFS_TW_SCRUB_KNOBS     0x2 /* the scrub walk's TEST ONLY leaf knobs apply */
#define CETRAFS_TW_ONE             0x4 /* one child at a time, nothing allocated: a per-block point query */

struct cetrafs_tw;
struct cetrafs_tw_ops {
    /* An index entry whose child is at 'level', under its node's buffer
     * lock: decide only -- no I/O, no other buffer lock. Never asked of
     * the record's root slots, whose ranges are not maintained. */
    int (*want)(struct cetrafs_tw *w, const cetrafs_extent_idx_t *ie, int level);
    /* A wanted child, outside every lock, before it is read: may act on
     * it, or answer for it (CETRAFS_TW_SKIP leaves it unread). */
    int (*child)(struct cetrafs_tw *w, const cetrafs_extent_idx_t *ie, int level);
    /* A leaf's entries: under the leaf's buffer lock (lba 0 for the
     * record's inline array, which has none). */
    int (*leaf)(struct cetrafs_tw *w, const cetrafs_extent_t *arr, u32 n, u64 lba);
    /* A child block once read and checked, before its entries are
     * walked, outside every lock (a nonzero answer ends the walk). */
    int (*node)(struct cetrafs_tw *w, struct buffer_head *bh, u64 lba, int level);
    /* After a child's whole subtree, outside every lock; rd is its read's
     * result (-EIO when it could not be read). */
    int (*done)(struct cetrafs_tw *w, u64 lba, int level, int rd);
};

struct cetrafs_tw {
    const struct cetrafs_tw_ops *ops;
    struct inode *inode;     /* NULL for the scrub's reads */
    struct super_block *sb;  /* filled from inode when NULL */
    enum cetrafs_tw_read read;
    unsigned int flags;
    void *ctx;
    bool unknown;            /* out: an unreadable subtree was skipped */
    u64 nodes;               /* out: external blocks walked */
};

int cetrafs_tree_walk(struct cetrafs_tw *w, const cetrafs_inode_t *raw);
struct buffer_head *cetrafs_tree_last_node(struct inode *inode, const cetrafs_inode_t *raw, int upto, bool reader,
                                           u32 *counts);
struct buffer_head *cetrafs_scrub_tree_bread(struct super_block *sb, u64 lba, u32 magic, bool fresh);

/* ---- ioutil.c: the whole-block tail checksum ---- */
/* A torn read is a peer's write in flight: milliseconds on a LUN. The
 * budget is therefore measured in milliseconds -- 1, 2, 4 ... 128 ms
 * between attempts, about a quarter of a second in all -- and paid only
 * on a mismatch (cetrafs_tear_backoff(); audit 2026-11-11 X1). */
#define CETRAFS_BLK_TAIL_READ_RETRIES 9
void cetrafs_tear_backoff(int attempt);
bool cetrafs_tear_injected(void);
bool cetrafs_record_tear_injected(const char *what);
void cetrafs_blk_tail_stamp(struct buffer_head *bh, u32 magic);
bool cetrafs_blk_tail_valid(const struct buffer_head *bh, u32 magic);
bool cetrafs_blk_read_accepts(const struct buffer_head *bh, u32 magic);
/* Structure sanity on its own, for the CACHED read paths that skip the
 * tail verification: a block nobody else can be writing is still not
 * necessarily a block that makes sense. */
bool cetrafs_blk_struct_ok_magic(const struct buffer_head *bh, u32 magic);
bool cetrafs_blk_image_valid(const void *img, u32 magic);
/* ino/generation: the file whose tree or xattr block this is, marked
 * damaged when the block is (0 when no one file owns it). */
struct buffer_head *cetrafs_blk_tail_bread(struct super_block *sb, u64 ino, u64 generation, u64 lba, u32 magic,
                                          const char *what);
int cetrafs_cas_region(struct super_block *sb, u64 fs_lba, unsigned int region_idx, cetrafs_cas_fn mutate, void *priv);
int cetrafs_cas_region_judged(struct super_block *sb, u64 fs_lba, unsigned int region_idx, cetrafs_cas_fn mutate,
                              void *priv, bool *image_only);
/* Seeded variants: pass the caller's already-fresh image of the region to
 * skip the CAS's own read on the first attempt. A stale seed costs one
 * failed CAW and falls back to a fresh re-read -- never correctness. */
int cetrafs_cas_record_seeded(struct super_block *sb,
                              u64 fs_lba,
                              const void *seed,
                              unsigned int seed_len,
                              cetrafs_cas_fn mutate,
                              void *priv);
int cetrafs_cas_record_fd_seeded(struct super_block *sb,
                                 u64 fs_lba,
                                 const void *seed,
                                 unsigned int seed_len,
                                 cetrafs_cas_fn mutate,
                                 void *priv);
int cetrafs_cas_region_seeded(struct super_block *sb,
                              u64 fs_lba,
                              unsigned int region_idx,
                              const void *seed,
                              unsigned int seed_len,
                              cetrafs_cas_fn mutate,
                              void *priv);
int cetrafs_caw(struct block_device *bdev, u64 lba, unsigned int nblocks, const void *compare, const void *write_data,
                bool killable);
const char *cetrafs_caw_class_name(enum cetrafs_caw_class klass);
void cetrafs_caw_probe_at_load(void);
void cetrafs_cas_selftest(struct super_block *sb, u32 my_node_id);
void cetrafs_cas_stress(struct super_block *sb, u32 my_node_id);
extern bool cetrafs_cas_selftest_enabled;

// ioutil.c
struct buffer_head *cetrafs_bread_uncached(struct super_block *sb, sector_t block);
int cetrafs_publish_flush(struct super_block *sb);
void cetrafs_bh_snapshot(struct buffer_head *bh, void *dst, unsigned int len, unsigned int split,
                         unsigned int stall_ms, bool unlocked);
void cetrafs_invalidate_block(struct super_block *sb, sector_t block);
void cetrafs_forget_block(struct super_block *sb, sector_t block);
unsigned long cetrafs_drop_dirty_metadata(struct super_block *sb);
/* Keep a cached block coherent with a swap that went straight to the
 * device, without throwing the cached copy away -- see ioutil.c. */
void cetrafs_cache_region_after_cas(struct super_block *sb,
                                    sector_t block,
                                    unsigned int off,
                                    const void *src,
                                    unsigned int len);
/* Call before modifying any cached buffer the forced-fresh readers above
 * can also reach -- see ioutil.c. */
void cetrafs_bh_begin_update(struct buffer_head *bh);
u32 cetrafs_bh_begin_update_crc(struct buffer_head *bh);
/* begin_update on a block claimed WITHOUT reading it: for a write that
 * replaces every byte. See ioutil.c. */
struct buffer_head *cetrafs_getblk_overwrite(struct super_block *sb, sector_t block);
void cetrafs_bh_end_update(struct super_block *sb, struct buffer_head *bh);
/* Dirty for writeback, as before A-15: test hooks only (ioutil.c). */
void cetrafs_bh_end_update_dirty(struct buffer_head *bh);
void cetrafs_write_pending_buffer(struct super_block *sb, struct buffer_head *bh, unsigned int op_flags);
bool cetrafs_refusal_definite(int err);
u64 cetrafs_journal_op_refusal_count(void);
void cetrafs_write_bhs_status(struct super_block *sb, struct buffer_head **bhs, unsigned int n, int *st);
int cetrafs_sync_buffer_op_refusable(struct super_block *sb, struct buffer_head *bh);
void cetrafs_bh_read_lock(struct buffer_head *bh);
void cetrafs_bh_read_unlock(struct buffer_head *bh);
/* Synchronous write whose result is TRUE, unlike sync_dirty_buffer()'s
 * here -- see ioutil.c. _keep never discards the cached bytes on error. */
int cetrafs_sync_buffer(struct super_block *sb, struct buffer_head *bh);
int cetrafs_sync_buffer_refusable(struct super_block *sb, struct buffer_head *bh);
int cetrafs_sync_buffer_keep(struct super_block *sb, struct buffer_head *bh);
int cetrafs_sync_buffers_keep(struct super_block *sb, struct buffer_head **bhs, unsigned int n, int *res);
int cetrafs_sync_new_buffer(struct super_block *sb, struct buffer_head *bh);
int cetrafs_sync_new_buffers(struct super_block *sb, struct buffer_head **bhs, unsigned int n);
u64 cetrafs_meta_nospc_count(void);
u64 cetrafs_tree_half_full_count(void); /* file.c */
u64 cetrafs_close_nospc_drop_count(void); /* lock.c */
u64 cetrafs_held_flush_batch_count(void); /* ioutil.c */
u64 cetrafs_ibmap_abandoned_count(void); /* alloc.c */
u64 cetrafs_ibmap_busy_skip_count(void); /* alloc.c */
extern bool cetrafs_convert_append_nospc; /* lock.c, test-only */
bool cetrafs_bh_test_stable(struct buffer_head *bh, bool (*test)(const void *data, void *arg), void *arg);
void cetrafs_bh_copy_stable(struct buffer_head *bh, void *out, size_t len);
void cetrafs_bh_copy_settled(struct buffer_head *bh, void *out);
void cetrafs_bh_copy_stable_at(struct buffer_head *bh, unsigned int off, void *out, size_t len);
int cetrafs_bh_memcmp_stable_at(struct buffer_head *bh, unsigned int off, const void *buf, size_t len);
void cetrafs_bh_abort_update(struct buffer_head *bh);
/* sb_bread() that tolerates a concurrent invalidation of the same block
 * -- use for anything cetrafs_invalidate_block() can target. */
#define CETRAFS_BREAD_RETRIES 12
struct buffer_head *cetrafs_bread_retry(struct super_block *sb, sector_t block);
struct buffer_head *cetrafs_bread_uncached_retry(struct super_block *sb, sector_t block);
int cetrafs_bread_uncached_batch(struct super_block *sb, sector_t start, u32 n, struct buffer_head **bhs);
const char *cetrafs_block_role(struct super_block *sb, u64 lba);
int cetrafs_bread_uncached_list(struct super_block *sb, const sector_t *list, u32 n, struct buffer_head **bhs);
/* inode.c -- read an inode's external extent-leaf block at the right
 * freshness for who currently owns the file. */
struct buffer_head *cetrafs_read_leaf_bh(struct inode *inode, u64 lba);

/* lock.c: one remembered extent per inode -- see cetrafs_inode_info's
 * ext_valid comment for what keys it and what may not be cached. */
struct cetrafs_ext_span {
    u32 block; /* first file-relative block the extent covers */
    u32 len;   /* blocks */
    u64 lba;   /* device block 'block' lives at */
    bool uninit;
};
bool cetrafs_inode_ext_cache_lookup(struct inode *inode,
                                    const cetrafs_inode_t *raw,
                                    u32 iblock,
                                    u64 *out_lba,
                                    u32 *out_run,
                                    bool *out_uninit);
void cetrafs_inode_ext_cache_store(struct inode *inode,
                                   const cetrafs_inode_t *raw,
                                   u32 ext_block,
                                   u32 ext_len,
                                   u64 ext_lba,
                                   bool uninit,
                                   u32 gen);
u32 cetrafs_inode_ext_cache_gen(struct inode *inode);
u64 cetrafs_ext_cache_stale_refused_count(void);
void cetrafs_inode_ext_cache_drop(struct inode *inode);
u64 cetrafs_ext_cache_hit_count(void);
u64 cetrafs_ext_cache_miss_count(void);
struct buffer_head *cetrafs_read_dir_leaf_bh(struct inode *inode, u64 lba, bool fresh);
struct buffer_head *cetrafs_read_tree_bh(struct inode *inode, u64 lba, u32 tail_magic, const char *what);
struct buffer_head *cetrafs_read_index_bh(struct inode *inode, u64 lba);
struct buffer_head *cetrafs_read_tree_bh_for(struct inode *inode, u64 lba, u32 tail_magic, const char *what, bool reader);
struct buffer_head *cetrafs_read_leaf_bh_for(struct inode *inode, u64 lba, bool reader);
struct buffer_head *cetrafs_read_index_bh_for(struct inode *inode, u64 lba, bool reader);
int cetrafs_flush_tree_blocks(struct inode *inode, const cetrafs_inode_t *raw, bool mapping_locked);
void cetrafs_tree_invalidate_cached(struct inode *inode, const cetrafs_inode_t *raw);
int cetrafs_tree_flatten(struct inode *inode, const cetrafs_inode_t *raw, cetrafs_extent_t **out_arr, u32 *out_n);
int cetrafs_tree_build(struct inode *inode, const cetrafs_extent_t *flat, u32 n, cetrafs_inode_t *raw, u64 *out_meta);
void cetrafs_tree_free_meta(struct inode *inode, const cetrafs_inode_t *raw);
void cetrafs_tree_free_meta_except(struct inode *inode, const cetrafs_inode_t *raw, const cetrafs_inode_t *keep);
int cetrafs_tree_patch(struct inode *inode, cetrafs_inode_t *raw, u64 start, u64 end, const cetrafs_extent_t *add,
                       u32 add_n, u32 want_n, u64 want_data, u64 *out_meta);
u64 cetrafs_tree_patch_count(void);
u64 cetrafs_defrag_segment_count(void);
u64 cetrafs_tree_patch_write_count(void);
u32 cetrafs_tree_extent_count(struct inode *inode, const cetrafs_inode_t *raw);
u32 cetrafs_tree_extent_count_for(struct inode *inode, const cetrafs_inode_t *raw, bool reader);
u64 cetrafs_flat_data_blocks(const cetrafs_extent_t *flat, u32 n);

// inode.c
struct inode *cetrafs_iget(struct super_block *sb, u64 ino);
int cetrafs_write_vfs_inode(struct inode *inode);
/* inode.c: a table walk's read -- -ENODATA for a never-written record (F-7) */
bool cetrafs_inode_half_born(const cetrafs_inode_t *in, u64 ino);
bool cetrafs_inode_half_landed(const cetrafs_inode_t *in, u64 ino);
int cetrafs_inode_stamp_unborn(struct super_block *sb, u64 ino);
bool cetrafs_walk_zero_owns_nothing_test(void);
int cetrafs_read_raw_inode_walk(struct super_block *sb, u64 ino, cetrafs_inode_t *out);
int cetrafs_read_raw_inode(struct super_block *sb, u64 ino, cetrafs_inode_t *out);
int cetrafs_write_raw_inode(struct super_block *sb, u64 ino, const cetrafs_inode_t *in, bool sync);
int cetrafs_write_raw_inode_new(struct super_block *sb, u64 ino, const cetrafs_inode_t *in);
void cetrafs_test_nospc_once(sector_t block); /* ioutil.c, TEST ONLY */
u64 cetrafs_record_op_refusal_count(void);
int cetrafs_write_raw_inode_self(struct inode *self, const cetrafs_inode_t *in, bool sync); /* inode.c: holds fd_pub */
void cetrafs_invalidate_raw_inode(struct super_block *sb, u64 ino);
/*
 * Compile-time trace instrumentation.
 *
 * ctrace() marks the probes that located the 2026-10 cross-node
 * corruption bugs: dirent add/remove attribution, inode alloc/free
 * lifecycle, the CAS images every inode-bitmap compare-and-write ran
 * with, the SCSI path each CAW took, namespace-lock hold windows, and
 * the bytes a failing record read actually saw. Rebuilding these by
 * hand cost two days once; they stay in the source instead.
 *
 * OFF by default and compiled out entirely -- production builds carry
 * no overhead and no log noise. Enable with:
 *
 *     make mod CETRAFS_TRACE=1
 *
 * The messages are a debugging interface, not ABI: grep-stable tags
 * (ADDNAME, REMNAME, RETGT, DISCARD, ADDREC, INOALLOC, INOFREE, IBCAS,
 * CAWPATH, NSHOLD, DSHRINK, EUCLEANDUMP, DIRTYREC, the block-free
 * lifecycle set BLKALLOC, BLKFREE, BLKQUEUE, BLKAPPLY, PFDRAIN,
 * EVICTFREE that located the referenced-but-free double free, and the
 * file-domain shadow set FDSTAGE, FDTAKE, FDPUB that located the
 * publish-window lost-update leak) with key=value fields, consumed by
 * the analysers under ctest/tools/.
 */
#ifdef CETRAFS_TRACE
#define ctrace(fmt, ...) pr_warn(fmt, ##__VA_ARGS__)
#else
#define ctrace(fmt, ...) \
    do {                 \
    } while (0)
#endif

u64 cetrafs_inode_lba(struct super_block *sb, u64 ino);
/* inode.c: record publish epochs (BUG-CLASSES class 29) */
void cetrafs_rec_epoch_bump(struct super_block *sb, u64 lba);
u64 cetrafs_rec_epoch_sample(struct super_block *sb, u64 ino);
#define CETRAFS_REC_EPOCH_NONE U64_MAX
u32 cetrafs_inode_crc_ns(const cetrafs_inode_t *in);
u32 cetrafs_inode_crc_fd(const cetrafs_inode_t *in);
bool cetrafs_inode_crcs_ok(const cetrafs_inode_t *in);
void cetrafs_inode_stamp_crc(struct super_block *sb, cetrafs_inode_t *in); /* whole record: echoes + both sector CRCs */
void cetrafs_inode_stamp_crc_ns(cetrafs_inode_t *in);                      /* sector 0 only (the CAS mutates) */
void cetrafs_inode_stamp_crc_fd(struct super_block *sb, cetrafs_inode_t *in);
u64 cetrafs_file_seq_new(struct super_block *sb); /* sector 1 only (the file-path publish) */
int cetrafs_apply_raw_to_vfs_inode(struct inode *inode, const cetrafs_inode_t *raw);
int cetrafs_apply_raw_to_vfs_inode_sure(struct inode *inode, const cetrafs_inode_t *raw);
int cetrafs_refresh_vfs_inode_if_newer(struct inode *inode);
void cetrafs_refresh_counters(u64 *stalls, u64 *candidates, u64 *refused); /* procfs info */
u64 cetrafs_inode_new_generation(struct super_block *sb);

// dir.c
int cetrafs_dir_add_entry(struct inode *dir, const struct qstr *name, u64 ino, u8 file_type);
/* Counts a stopped operation left behind its entries (dir.c). */
int cetrafs_ns_reconcile(struct super_block *sb, u64 ino, u64 generation, struct inode *self);
int cetrafs_ns_reconcile_counted(struct super_block *sb, u64 ino, u64 generation, struct inode *self,
                                 const u32 *counted);
/* nslock.c: set or clear CETRAFS_INODE_COUNT_UNVERIFIED, holding the lock. */
int cetrafs_ns_set_unverified(struct super_block *sb, u64 ino, u64 generation, bool set);
int cetrafs_ns_count_names(struct super_block *sb, const u64 *inos, u32 n, u32 *counts);
int cetrafs_ns_publish_nlink(struct super_block *sb, u64 ino, u64 generation, const cetrafs_inode_t *seed,
                             u32 want, struct inode *self);
u64 cetrafs_ns_recounts_count(void);
int cetrafs_dir_remove_entry(struct inode *dir, const struct qstr *name, u64 expect_ino, u64 *out_ino,
                             u8 *out_file_type);
int cetrafs_dirent_block_init(struct super_block *sb, u64 lba, bool *keep);
int cetrafs_dir_update_dotdot(struct inode *dir, u64 new_parent_ino);
extern const struct inode_operations cetrafs_inode_ops;
extern const struct file_operations cetrafs_dir_ops;
extern const struct dentry_operations cetrafs_dentry_ops;

// defrag.c -- per-file relocation core + automatic background defrag
struct cetrafs_defrag; /* opaque; owned entirely by defrag.c */
int cetrafs_defrag_inode(struct inode *inode, struct cetrafs_defrag_stats *out_stats);
int cetrafs_defrag_init(struct super_block *sb, struct cetrafs_defrag **out_d);
void cetrafs_defrag_stop(struct cetrafs_defrag *d);
void cetrafs_defrag_consider(struct inode *inode, u32 extents, u64 nblocks);
void cetrafs_defrag_rejudge(struct inode *inode);
u64 cetrafs_defrag_stale_req_count(void);
u32 cetrafs_defrag_pin_count(void);
u64 cetrafs_lock_yield_ask_count(void);
u64 cetrafs_defrag_yield_count(void);
u64 cetrafs_defrag_pass_count(void);
u64 cetrafs_defrag_growth_cancel_count(void);
u64 cetrafs_defrag_max_step_blocks(void);

// nslock.c -- the per-inode namespace lock
int cetrafs_nslock_acquire(struct inode *inode);
void cetrafs_nslock_release(struct inode *inode);
/* The widest set any single operation needs: rename's two parents, the
 * moved inode, a replaced target, and -- for a directory changing
 * parent -- the root directory, whose lock orders every such move
 * cluster-wide (see cetrafs_rename()). */
#define CETRAFS_NSLOCK_MAX_SET 5
int cetrafs_nslock_acquire_set(struct inode **inodes, int n);
int cetrafs_nslock_acquire_set_vfs(struct inode **inodes, int n);
u64 cetrafs_nslock_restart_count(void);
u64 cetrafs_nslock_silent_extend_count(void);
u64 cetrafs_nslock_settle_deferred_count(void);
void cetrafs_nslock_exit(void);
void cetrafs_nslock_release_set(struct inode **inodes, int n);

// file.c
int cetrafs_inode_map_block(struct inode *inode, u32 iblock, bool create, u64 *out_lba);
void cetrafs_free_inline_extents(struct inode *dir, const cetrafs_inode_t *raw);

/* file.c: an inode's extent list, resolved at any depth. Evict holds one
 * ACROSS the inode-number arbitration: the list has to be proven
 * readable before the number is handed back, or a failure there leaks
 * the blocks with nothing left naming them. */
struct cetrafs_inode_extents {
    cetrafs_extent_t *heap;      /* an external tree's flattened copy, freed by _put; NULL inline */
    const cetrafs_extent_t *arr; /* heap, or the record's inline array */
    u32 entries; /* u32: a tree can hold far more than 65535 extents */
};
int cetrafs_inode_extents_get(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_inode_extents *ex);
void cetrafs_inode_extents_put(struct cetrafs_inode_extents *ex);
void cetrafs_free_fetched_extents(struct inode *dir, const cetrafs_inode_t *raw, struct cetrafs_inode_extents *ex);

/* file.c: an inode's extents in logical order, for the walks that report
 * the map (fiemap, SEEK_DATA/SEEK_HOLE). */
struct cetrafs_ext_run {
    u64 start, len, phys;
    bool uninit;
};
/* A sorted map, shared by reference: the per-inode cache keeps one and
 * every caller holds its own while it walks. 'key' is the tree's
 * identity (cetrafs_tree_identity()); 'overlap' that some runs overlap
 * (damage: every run is then data). */
struct cetrafs_smap {
    refcount_t ref;
    u64 key;
    u32 n;
    bool overlap;
    struct cetrafs_ext_run runs[];
};
void cetrafs_smap_put(struct cetrafs_smap *m);
u64 cetrafs_smap_hit_count(void);
u64 cetrafs_smap_build_count(void);
/* lock.c: the per-inode cache of the above. */
struct cetrafs_smap *cetrafs_inode_smap_get(struct inode *inode, u64 key);
void cetrafs_inode_smap_store(struct inode *inode, struct cetrafs_smap *m);
void cetrafs_inode_smap_drop(struct inode *inode);
int cetrafs_setattr(struct mnt_idmap *idmap, struct dentry *dentry, struct iattr *attr);
extern const struct inode_operations cetrafs_symlink_iops;
extern const struct file_operations cetrafs_file_ops;
extern const struct address_space_operations cetrafs_aops;

// xattr.c
ssize_t cetrafs_listxattr(struct dentry *dentry, char *list, size_t size);
extern const struct xattr_handler *const cetrafs_xattr_handlers[];
/* Let the active LSM stamp a newly created inode (security.*). Called
 * from dir.c's creation paths before the name is published. */
int cetrafs_init_security(struct inode *inode, struct inode *dir, const struct qstr *qstr);

// alloc.c
u64 cetrafs_bg_lookup_reads_count(void);
u64 cetrafs_cas_seed_refused_count(void);
u64 cetrafs_cas_seed_reverdict_count(void); /* caw.c */
u64 cetrafs_zg_copy_torn_count(void); /* zonegroup.c: ZG copies that failed their re-check */
u64 cetrafs_hb_row_read_count(void);
u64 cetrafs_hb_sweep_count(void); /* heartbeat.c */
int cetrafs_alloc_inode(struct super_block *sb, u64 *out_ino);
int cetrafs_free_inode(struct super_block *sb, u64 ino);
/* The scrub's conditioned variant: frees ONLY if a fresh read still shows
 * the record dead (nlink==0) and unchanged (same generation as the
 * caller's verdict read). -ESTALE means the number was reborn. */
int cetrafs_free_inode_if_dead(struct super_block *sb, u64 ino, u64 generation, u64 verdict_seq);
int cetrafs_free_inode_begin(struct super_block *sb, u64 ino, u64 generation, u64 verdict_seq, u64 *seq);
int cetrafs_free_inode_steal(struct super_block *sb, u64 ino, u64 generation, u64 verdict_seq, u32 from);
int cetrafs_free_inode_finish(struct super_block *sb, u64 ino, u64 generation, u64 seq);
void cetrafs_free_inode_abort(struct super_block *sb, u64 ino, u64 generation, u64 seq);
int cetrafs_free_inode_number_claimed(struct super_block *sb, u64 ino);
int cetrafs_alloc_data_block(struct super_block *sb, u32 bg_id, u64 *out_lba);
int cetrafs_alloc_data_block_near(struct super_block *sb, u32 bg_id, u64 preferred_lba, u64 *out_lba);
int cetrafs_alloc_block_anywhere(struct super_block *sb, u32 *out_bg, u64 *out_lba);
int cetrafs_alloc_data_run(struct super_block *sb, u32 bg_id, u64 count, u64 *out_lba);
u32 cetrafs_alloc_run_after(struct super_block *sb, u32 bg_id, u64 start_lba, u32 max);
long cetrafs_falloc_alloc_call_count(void); /* file.c: allocator calls made by fallocate */
long cetrafs_falloc_tree_lookup_count(void); /* file.c: tree lookups the fallocate planner made */
int cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count);

/* Foreign frees gathered by one operation and queued as one batch
 * (alloc.c, zonegroup.c). A pending-free swap covers one CAS region of a
 * queue block -- 16 entries on a 512-byte logical block -- so a batch of
 * this many is a few swaps, not one per extent. The entries keep their own
 * stamps: a batch can span Block Groups whose free_gen differ. */
#define CETRAFS_FREE_BATCH 32
struct cetrafs_pf_ent {
    u64 lba;
    u32 count;
    u64 stamp; /* its free_gen: applied only while the group's still equals it */
};
struct cetrafs_free_batch {
    u32 n;   /* entries held */
    u32 zg;  /* the owning Zone Group every held entry is aimed at */
    struct cetrafs_pf_ent ents[CETRAFS_FREE_BATCH];
};
static inline void cetrafs_free_batch_init(struct cetrafs_free_batch *fb)
{
    fb->n = 0;
    fb->zg = 0;
}
/* Free [lba, lba+count) as part of batch fb: a foreign extent is held in fb
 * and queued by the batch's flush, a block of ours is cleared now. Every
 * batch MUST be flushed before the operation that filled it returns, inside
 * the same frees_begin/frees_end bracket the frees belong to. */
int cetrafs_free_data_extent_batched(struct super_block *sb, u64 lba, u32 count, struct cetrafs_free_batch *fb);
int cetrafs_free_batch_flush(struct super_block *sb, struct cetrafs_free_batch *fb);
/* Inline so the BLKFREE/BLKQUEUE traces' from=%pS names the real caller,
 * not this wrapper. */
/*
 * Single blocks are what the extent tree, xattrs and directories free
 * their METADATA through -- blocks this node wrote via the buffer cache,
 * a regular file's extent leaf deliberately left dirty until the next
 * durability boundary. Such a buffer must be forgotten before the block
 * goes back: writeback would otherwise put the dead leaf on top of
 * whatever the block's next owner writes, here or on a peer
 * (tests/kernel/freed_leaf_writeback.sh). Whole-extent frees of file
 * DATA do not pay for this: file data never lives in this cache.
 */
static inline int cetrafs_free_data_block(struct super_block *sb, u64 lba)
{
    cetrafs_forget_block(sb, lba);
    return cetrafs_free_data_extent(sb, lba, 1);
}
int cetrafs_apply_pending_free(struct super_block *sb, u64 lba, u32 count, u32 expect_zg, u64 stamp);
int cetrafs_bg_bump_free_gen(struct super_block *sb, u32 bg_id);
u64 cetrafs_pf_stale_drop_count(void);
u64 cetrafs_bg_gen_bump_count(void);
int cetrafs_count_free_inodes(struct super_block *sb, u64 *out_free);
int cetrafs_bg_data_block_stats(struct super_block *sb, u32 bg_id, u64 *out_total, u64 *out_free);
int cetrafs_bg_mount_info(struct super_block *sb, const cetrafs_superblock_t *raw_sb, u32 bg_id, u64 desc_lba,
                          bool fresh, u64 *out_total, u32 *out_owner, u64 *out_start, u64 *out_len, u16 *out_flags,
                          u64 *out_data_start);

/* Which Zone Group owns this Block Group, from the owners recorded at
 * mount -- no device read. CETRAFS_NODE_ID_NONE if out of range.
 * Replaces asking a Zone Group for its contiguous range of members
 * (docs/internal/BG-OWNERSHIP-DESIGN.md). */
u32 cetrafs_sb_bg_owner(struct super_block *sb, u32 bg_id);
void cetrafs_sb_set_bg_owner(struct super_block *sb, u32 bg_id, u32 zg_id);
/* The LBA of a Block Group's descriptor. The table is a chain, so this
 * is no longer bg_table_start + bg_id. docs/internal/BG-OWNERSHIP-DESIGN.md */
u64 cetrafs_sb_bg_desc_lba(struct super_block *sb, u32 bg_id);
int cetrafs_sb_first_owned_zg(struct super_block *sb, u32 *out_zg);
/* Claim a Block Group nobody owns into zg_id, with one compare-and-swap.
 * -ENOSPC if there is none free. docs/internal/BG-OWNERSHIP-DESIGN.md */
int cetrafs_bg_claim_free(struct super_block *sb, u32 zg_id, u32 *out_bg_id);
int cetrafs_bg_trim_pool_one(struct super_block *sb, u32 b, u64 *out_blocks);
void cetrafs_bg_refresh_owner_map(struct super_block *sb);
/* Hand back every empty Block Group of zg_id. The hoarding fix.
 * docs/internal/BG-OWNERSHIP-DESIGN.md */
/* pass_started: 0 before a heartbeat pass's first call, then left to the
 * callee -- the hand-back discard budget runs per pass (discard.c). */
int cetrafs_bg_release_empty(struct super_block *sb, u32 zg_id, u32 *out_released, u32 *out_deferred,
                             unsigned long *pass_started);
bool cetrafs_sb_drain_bg(struct super_block *sb, u32 bg_id);
void cetrafs_sb_undrain_bg(struct super_block *sb, u32 bg_id);

/* Iterate every Block Group this node may allocate from. Flat: it does
 * not care which Zone Group each one belongs to, or whether a Zone
 * Group's members are contiguous. */
u32 cetrafs_sb_next_owned_bg(struct super_block *sb, u32 from);
/* Live grow: catch up with a grown superblock (fs.c). 1 = published a
 * new layout, 0 = nothing to do, negative = kept the current one. */
int cetrafs_sb_layout_refresh(struct super_block *sb);

/* Live grow (grow.c, fs.c). The plan is filled in by fs.c's layout walk
 * -- which checks everything the grow describes before anything is
 * written -- and carried out by cetrafs_grow_commit(). */
struct cetrafs_grow_plan {
    const cetrafs_superblock_t *cur; /* the published superblock, as on the device */
    const cetrafs_superblock_t *nw;  /* the one the grow publishes */
    u32 old_count, new_count;        /* Block Groups before and after */
    u64 new_seg_lba;                 /* the table segment the grow adds */
    u64 tail_lba;                    /* the segment that links to it; 0 = the superblock does (first grow) */
    u32 nshards;                     /* pool shards: one per Zone Group */
    u64 *shard_credit;               /* capacity each shard gains */
    const cetrafs_grow_arg_t *claim; /* the caller's growfs claim, re-checked at the publish */
};
int cetrafs_sb_layout_grow(struct super_block *sb, const cetrafs_superblock_t *nw, const cetrafs_grow_arg_t *claim);
int cetrafs_grow_claim_held(struct super_block *sb, const cetrafs_grow_arg_t *arg);
int cetrafs_grow_commit(struct super_block *sb, const struct cetrafs_grow_plan *plan);
int cetrafs_grow_check_bg_header(struct super_block *sb, u32 bg_id, u64 start, u64 len);
long cetrafs_grow_ioctl(struct file *file, const cetrafs_grow_arg_t __user *arg);
int cetrafs_grow_heal_pool(struct super_block *sb);
u32 cetrafs_bgseg_crc(const cetrafs_bg_segment_t *seg);
u32 cetrafs_bgseg_crc_prefix(const void *img, unsigned int len);
u64 cetrafs_layout_refresh_count(void);
u64 cetrafs_owned_derive_overlap_count(void);
void cetrafs_sb_owned_bgs_check(struct super_block *sb, u32 *stray, u32 *missing);
u64 cetrafs_layout_refresh_refused_count(void);
/* Recompute a BG's cached free count from its bitmap and correct it
 *. *out_delta is (truth - cached), for the caller to fix
 * the owning ZG's aggregate with. Only meaningful at a moment when this
 * node provably owns the BG. */
/* How many Block Groups cetrafs_get_block() will try before giving a
 * write ENOSPC. Each miss RECOUNTS the BG that lied, so every iteration
 * removes one wrong answer from the pool -- this bounds the work, it is
 * not a hope that retrying helps. */
#define CETRAFS_ALLOC_PICK_RETRIES 8u

int cetrafs_bg_reconcile_free_count(struct super_block *sb, u32 bg_id, s64 *out_delta, bool keep_epoch);
int cetrafs_bg_reconcile_free_count_uncached(struct super_block *sb, u32 bg_id, u32 zg_id, s64 *out_delta,
                                             bool keep_epoch);
u64 cetrafs_reconcile_epoch_kept_count(void);
void cetrafs_bg_prefetch_bitmap(struct super_block *sb, u32 bg_id);
/* Apply one accrued BG free-count delta as an epoch-guarded CAS. 0 means
 * consumed (applied, or loudly dropped as stale); negative only for real
 * I/O trouble, where the caller re-accrues. */
int cetrafs_bg_apply_free_delta(struct super_block *sb, u32 bg_id);
/* Seed this node's in-memory count epoch for every BG of a ZG whose
 * ownership entered the cache WITHOUT a reconcile (the tick re-attach
 * path) -- deltas accrued under an unseeded epoch would all be dropped. */
int cetrafs_bg_seed_count_epochs(struct super_block *sb, u32 zg_id);
/* Minimum gap between whole-volume foreign-descriptor sweeps. The
 * counts they refresh are caches; the allocator's warm descriptors are
 * not. See the sweep's comment in procfs.c. */
#define CETRAFS_BG_SWEEP_MIN_SECS 30u

/* A node that is allocating is demonstrably active, and its peers are
 * the ones filling its pending-free queue. Draining only on the
 * heartbeat (15s) let a burst of cross-ZG frees overflow in
 * milliseconds and stay overflowed, so every free leaked and each one
 * cost ~6.5 ms of queue-full retry. */
#define CETRAFS_PF_DRAIN_MIN_MS 500u

unsigned long cetrafs_sb_pf_drain_last(struct super_block *sb);
void cetrafs_sb_set_pf_drain_last(struct super_block *sb, unsigned long when);
struct mutex *cetrafs_sb_pf_drain_mutex(struct super_block *sb);
unsigned long cetrafs_sb_bg_sweep_last(struct super_block *sb);
void cetrafs_sb_set_bg_sweep_last(struct super_block *sb, unsigned long when);
void cetrafs_bg_desc_refresh_foreign(struct super_block *sb, u32 bg_id);
u64 cetrafs_bg_desc_kept_count(void);
u64 cetrafs_bg_desc_refreshed_count(void);
u64 cetrafs_bg_pick_cursor_count(void);
u64 cetrafs_bg_pick_scan_count(void);
u64 cetrafs_map_call_count(void);
u64 cetrafs_map_block_count(void);
u64 cetrafs_dio_fallback_count(void);
u64 cetrafs_dio_convert_count(void);
u64 cetrafs_dio_overwrite_count(void);
int cetrafs_xattr_caps_size(struct inode *inode);
int cetrafs_bg_owner_zg_for_lba(struct super_block *sb, u64 lba, u32 *out_zg_id);
int cetrafs_bg_invalidate_cache(struct super_block *sb, u32 bg_id);
int cetrafs_bg_recount_after_enospc(struct super_block *sb, u32 bg_id, s64 *out_delta);
u64 cetrafs_bmap_flush_visit_count(void);
extern bool cetrafs_bg_invalidate_fail_ignored; /* test-only */
extern bool cetrafs_alloc_shadow_enabled;
void cetrafs_shadow_set(struct super_block *sb, u64 lba, u64 count, const char *who);
void cetrafs_shadow_seed(struct super_block *sb);
bool cetrafs_shadow_active(struct super_block *sb);
/* Birth registry: a number between cetrafs_alloc_inode() and its first
 * published name. The orphan scrub must not judge it (see fs.c). */
void cetrafs_sb_birth_begin(struct super_block *sb, u64 ino);
void cetrafs_sb_birth_end(struct super_block *sb, u64 ino);
bool cetrafs_sb_birth_active(struct super_block *sb, u64 ino);
unsigned int cetrafs_sb_birth_gate(struct super_block *sb, bool reclaim);
void cetrafs_sb_birth_ungate(struct super_block *sb, bool reclaim, unsigned int nofs);
void cetrafs_shadow_clear(struct super_block *sb, u64 lba, u64 count, const char *who);

// super_ops.c
extern const struct super_operations cetrafs_super_ops;

// uuid.c
const char *get_stable_machine_uuid(void);

// node.c
int cetrafs_node_register(struct super_block *sb,
                          u32 file_lock_mode,
                          u32 *out_node_id,
                          u8 out_uuid[CETRAFS_NODE_UUID_LEN]);
int cetrafs_node_mark_offline(struct super_block *sb, u32 my_node_id);
int cetrafs_node_renew_heartbeat(struct super_block *sb, u32 my_node_id);
int cetrafs_node_set_frees(struct super_block *sb, u32 my_node_id, bool on);
int cetrafs_node_frees_snapshot(struct super_block *sb, u32 my_node_id, bool self_from_row,
                                u32 seqs[CETRAFS_MAX_READER_NODES], bool *busy);
int cetrafs_node_is_stale(struct super_block *sb, u32 node_id, bool *out_stale);
int cetrafs_node_declare_dead(struct super_block *sb, u32 node_id, u32 incarnation);
int cetrafs_node_is_stale_entry(struct super_block *sb, u32 node_id, const cetrafs_node_entry_t *row, bool *out_stale);
bool cetrafs_node_prefetch_rows(struct super_block *sb);
int cetrafs_node_get_entry_prefetched(struct super_block *sb, u32 idx, cetrafs_node_entry_t *out);
/* The fence lease -- see cetrafs_node_entry_t.fence_epoch. */
int __must_check cetrafs_node_fence_peer(struct super_block *sb, u32 node_id, const char *what);
bool cetrafs_node_reattached_since_fence(struct super_block *sb, u32 node_id);
void cetrafs_node_test_stall_before_swap(void);
int cetrafs_node_self_fence_check(struct super_block *sb, u32 my_node_id, bool *out_fenced);
/* fs.c: is_fenced, and the own row read fresh first at a boundary (B-18). */
bool cetrafs_sb_fence_witnessed(struct super_block *sb);
extern bool cetrafs_sync_regate_off; /* fs.c, TEST ONLY (B-30) */
u64 cetrafs_sb_fence_witness_reads(void); /* fs.c: count, for the suites */
bool cetrafs_sb_fence_witnessed_f8(struct super_block *sb);
void cetrafs_node_log_fencer(struct super_block *sb, u32 my_node_id);
int cetrafs_node_get_entry(struct super_block *sb, u32 idx, cetrafs_node_entry_t *out);
int cetrafs_node_peer_beating(struct super_block *sb, u32 node_id, bool *beating);
bool cetrafs_sb_peer_sample(struct super_block *sb, u32 node_id, const cetrafs_node_entry_t *ne, bool *first,
                            unsigned long *since);
u64 cetrafs_node_row_lba(struct super_block *sb, u32 idx);

// zonegroup.c
/* at_mount: reconcile the cached free counts of ZGs we re-attach to
 * against their bitmaps. True only from fill_super() --
 * a node re-attaching to its own ZG after its own crash is the case
 * that needs it; the heartbeat tick's re-attach cannot have drifted. */
int cetrafs_zg_claim_unowned(struct super_block *sb,
                             u32 my_node_id,
                             const u8 my_uuid[CETRAFS_NODE_UUID_LEN],
                             bool at_mount);
int cetrafs_zg_release_surplus(struct super_block *sb, u32 my_node_id);
int cetrafs_zg_release_all_rdonly(struct super_block *sb, u32 my_node_id);
int cetrafs_zg_scrub_adopt_one_stale(struct super_block *sb, bool *out_adopted);
/* Append n entries to zg_id's queue, as many per swap as its regions take.
 * Returns 0 when every entry is queued or deliberately dropped (*dropped
 * counts the drops: leaked on purpose, reclaimed by the scrub or fsck -r),
 * or a hard error with the entries from *dropped on not queued. */
int cetrafs_zg_queue_foreign_frees(struct super_block *sb,
                                   u32 zg_id,
                                   const struct cetrafs_pf_ent *ents,
                                   u32 n,
                                   u32 *dropped);
/* may_wait: back off on a busy region (heartbeat, mount); false on the
 * allocation path, where a write is waiting. */
int cetrafs_zg_drain_pending_frees(struct super_block *sb, bool may_wait);
/* Read-only walk of a ZG's pending-free queue: the scrub must not treat
 * a block with a free already queued against it as a leak. */
int cetrafs_zg_pending_free_for_each(struct super_block *sb, u32 zg_id, void (*cb)(void *, u64, u32), void *ctx);
int cetrafs_alloc_pick_bg(struct super_block *sb, u32 *out_bg_id);
int cetrafs_alloc_pick_run(struct super_block *sb, u64 count, u64 *out_lba);
int cetrafs_alloc_pick_run_resv(struct super_block *sb, u64 count, u64 *out_lba, struct cetrafs_resv_span *span);
int cetrafs_alloc_data_run_resv(struct super_block *sb, u32 bg_id, u64 count, u64 *out_lba,
                                struct cetrafs_resv_span *span);
int cetrafs_free_data_extent_unless_reserved(struct super_block *sb, u64 lba, u32 count, u64 resv_seq,
                                             const u64 *alloc_seq, u64 *out_freed);
u64 cetrafs_sb_resv_seq(struct super_block *sb);
/* fs.c: frees in flight between a publish and its frees (cetrafs_frees_begin()). */
struct cetrafs_frees_snap {
    u64 local;
    u32 seqs[CETRAFS_MAX_READER_NODES];
};
int cetrafs_frees_begin(struct super_block *sb, bool *foreign);
void cetrafs_frees_end(struct super_block *sb, bool foreign);
u64 cetrafs_frees_announced_count(void);
/* alloc.c / file.c: whether the blocks a freeing operation drops all lie
 * in Block Groups this node owns -- if so, no peer's scrub judges them,
 * and the operation need not announce itself in its registry row. */
bool cetrafs_lba_run_is_ours(struct super_block *sb, u64 lba, u64 count);
bool cetrafs_flat_range_is_ours(struct super_block *sb, const cetrafs_extent_t *arr, u32 n, u64 from, u64 to);
bool cetrafs_tree_meta_is_ours(struct inode *inode, const cetrafs_inode_t *raw);
void cetrafs_frees_heartbeat(struct super_block *sb);
int cetrafs_frees_quiet(struct super_block *sb, struct cetrafs_frees_snap *snap, bool compare);
struct cetrafs_zg_info {
    u32 owner_node_id; /* CETRAFS_NODE_ID_NONE if unclaimed */
    u64 free_data_blocks;
    u64 pool_free_blocks; /* capacity of unowned BGs sharded here */
    /* No member list: a Zone Group no longer describes which Block
     * Groups belong to it. Ask the Block Group -- cetrafs_sb_bg_owner()
     * -- or walk cetrafs_sb_next_owned_bg() for the ones this node may use.
     * docs/internal/BG-OWNERSHIP-DESIGN.md */
};
int cetrafs_zg_get_info(struct super_block *sb, u32 zg_id, struct cetrafs_zg_info *out);
bool cetrafs_zg_prefetch_all(struct super_block *sb);
extern bool cetrafs_zg_prefetch_off; /* test-only */
int cetrafs_zg_get_info_prefetched(struct super_block *sb, u32 zg_id, struct cetrafs_zg_info *out);
int cetrafs_zg_adjust_free_blocks(struct super_block *sb, u32 zg_id, s64 delta);
int cetrafs_zg_apply_free_delta(struct super_block *sb, u32 zg_id, s64 delta);
int cetrafs_zg_flush_free_delta(struct super_block *sb, u32 zg_id, s64 delta);
int cetrafs_zg_pool_grow_credit(struct super_block *sb, u32 zg_id, u64 published_gen, u64 gen, u64 id, u64 credit,
                                u64 *took);
int cetrafs_zg_pool_grow_takeback(struct super_block *sb, u32 zg_id, u64 gen, u64 id, u64 *took);
int cetrafs_zg_pool_grow_marker(struct super_block *sb, u32 zg_id, u64 *gen, u64 *id);
int cetrafs_zg_adjust_pool_blocks(struct super_block *sb, u32 bg_id, s64 delta);
loff_t cetrafs_max_file_size_for(u64 data_blocks);

// lock.c
int cetrafs_init_inode_cache(void);
void cetrafs_destroy_inode_cache(void);
struct inode *cetrafs_alloc_vfs_inode(struct super_block *sb);
void cetrafs_free_vfs_inode(struct inode *inode);
int cetrafs_lock_open(struct inode *inode, struct file *file);
int cetrafs_lock_release(struct inode *inode, struct file *file);
void cetrafs_inode_drop_reservation(struct inode *inode);
bool cetrafs_inode_take_reserved(struct inode *inode, u64 want_lba, u64 *out_lba);
void cetrafs_inode_set_reservation(struct inode *inode, u64 next, u32 count, u32 bg);
u32 cetrafs_inode_next_run_len(struct inode *inode, u32 base, u32 max);
int cetrafs_lock_foreign_claim_exists(struct super_block *sb, u64 ino, u32 my_node_id, bool *out_exists);
int cetrafs_lock_foreign_reader_exists(struct super_block *sb, u64 ino, u32 my_node_id, bool *out_exists);
/* Both of the above from ONE forced-fresh read, for the three sites
 * that ask both before destroying a file. */
int cetrafs_lock_foreign_user_exists(struct super_block *sb,
                                     u64 ino,
                                     u32 my_node_id,
                                     bool *out_writer,
                                     bool *out_reader);
/* The same, also returning what it judged: the foreign lock owner it
 * read (CETRAFS_NODE_ID_NONE: none) and the foreign presence bits. A
 * later CAS can then refuse anything that appeared since. */
int cetrafs_lock_foreign_user_judged(struct super_block *sb,
                                     u64 ino,
                                     u32 my_node_id,
                                     bool *out_writer,
                                     bool *out_reader,
                                     u32 *judged_owner,
                                     u64 *judged_readers);
/* The same for a user's operation: a peer's background-move pin is
 * asked back and waited for rather than reported as a writer. */
bool cetrafs_lock_foreign_user_would_wait(struct inode *inode, u32 my_node_id);
int cetrafs_nslock_defer_settle(struct inode *inode);
int cetrafs_lock_foreign_user_settled(struct inode *inode,
                                      u32 my_node_id,
                                      bool *out_writer,
                                      bool *out_reader,
                                      u32 *judged_owner,
                                      u64 *judged_readers);
bool cetrafs_lock_held_for_write_locally(struct inode *inode);
int cetrafs_lock_write_gate(struct inode *inode); /* -ETXTBSY while this node's lock is suspended */
bool cetrafs_lock_read_cache_trusted(struct inode *inode);
bool cetrafs_lock_alloc_tree_trusted(struct inode *inode, const cetrafs_inode_t *fresh);
u64 cetrafs_tree_cold_mark_count(void);
void cetrafs_inode_mark_tree_cold(struct inode *inode);
bool cetrafs_lock_identity_cache_trusted(struct inode *inode);
/* lock.c: default-mount lock suspension counters (procfs `info`). */
u64 cetrafs_lock_suspend_count(void);
u64 cetrafs_lock_resume_count(void);
u64 cetrafs_open_peer_settled_count(void);
u64 cetrafs_alloc_trust_cold_count(void);
u64 cetrafs_peer_zeroed_count(void);
u64 cetrafs_punch_early_refusal_count(void);
u64 cetrafs_open_peer_waits_count(void);
/* file.c: the close-equivalent durability boundary for a file staying open. */
int cetrafs_file_make_durable(struct file *file, bool locked);
/* file.c: buffered-write blocks not yet marked written (enum cetrafs_gb_mode). */
int cetrafs_convert_pending_locked(struct inode *inode);
int cetrafs_convert_pending(struct inode *inode);
int cetrafs_inode_sync_pending(struct inode *inode);
/* lock.c: the per-inode set those blocks live in. */
int cetrafs_pending_add(struct inode *inode, u32 first, u32 count);
u32 cetrafs_pending_run(struct inode *inode, u32 block);
int cetrafs_pending_next(struct inode *inode, u32 from, u32 *first, u32 *last);
/* lock.c: O_DIRECT writes in flight into preallocated blocks (G-1) */
bool cetrafs_dio_is_track(void *p);
void *cetrafs_dio_track_add(struct inode *inode, void *cur, u32 first, u32 count);
void cetrafs_dio_track_done(struct inode *inode, void *p);
bool cetrafs_unit_dio_busy(struct inode *inode, u32 first, u32 count);
bool cetrafs_pending_any(struct inode *inode);
bool cetrafs_conv_unflushed(struct inode *inode);
void cetrafs_conv_unflushed_set(struct inode *inode, bool unflushed);
bool cetrafs_pending_wb_failed(struct inode *inode);
void cetrafs_pending_clear(struct inode *inode, u32 first, u32 last);
void cetrafs_pending_drop_all(struct inode *inode);
int cetrafs_tree_resv_fill(struct inode *inode);
int cetrafs_tree_alloc_block(struct inode *inode, u32 *bg, u64 *lba);
int cetrafs_tree_block_anywhere(struct super_block *sb, u32 *bg, u64 *lba);
u64 cetrafs_tree_alloc_count(void);
void cetrafs_tree_resv_release(struct inode *inode);
void cetrafs_tree_resv_drop(struct inode *inode);
void cetrafs_tree_mark_convert_append(struct inode *inode, bool on);
bool cetrafs_inode_foreign_opener_cached(struct inode *inode);
void cetrafs_lock_expire_verdicts(struct inode *inode);
void cetrafs_inode_set_generation(struct inode *inode, u64 gen);

/*
 * The stat fields of the on-disk record as THIS node last saw them --
 * the baseline for ->write_inode's three-way merge.
 *
 * Writeback is reachable with no cross-node lock held, and under
 * nofilelock there is no lock to hold: a node can be holding a stale
 * copy of a record a peer has since advanced. Stamping our whole stat
 * block over it reverts the peer; dropping our dirt instead means we can
 * never persist our own metadata (a peer being open IS the normal state
 * during a handoff). Neither is right, so the merge needs to tell
 * "fields we changed" from "fields we merely hold an old copy of", and
 * that needs a baseline to compare both sides against.
 */
struct cetrafs_stat_baseline {
    bool valid;
    u32 mode, uid, gid, nlink;
    u64 size, blocks;
    u64 atime, mtime, ctime;
};
void cetrafs_inode_stat_baseline_set(struct inode *inode, const cetrafs_inode_t *raw);
bool cetrafs_inode_stat_baseline_get(struct inode *inode, struct cetrafs_stat_baseline *out);
void cetrafs_inode_stat_baseline_set_size(struct inode *inode, u64 size, u64 blocks);
/* inode.c: the cold reconcile applies the fresh record's size (B-10). */
int cetrafs_inode_apply_size_from_raw(struct inode *inode, const cetrafs_inode_t *raw);
/* For the paths that persist stat through a CAS stamp (lock.c's close
 * and lock-clear), where the committed record equals the in-core block. */
void cetrafs_inode_stat_baseline_from_incore(struct inode *inode);
/* inode.c: the three-way merge itself (declared here, after the struct). */
u64 cetrafs_inode_get_generation(struct inode *inode);
void cetrafs_inode_adopt_identity(struct inode *inode, const cetrafs_inode_t *raw); /* clears S_NOSEC */
u64 cetrafs_inode_dirent_seq_cached(struct inode *inode);
void cetrafs_inode_set_dirent_seq_cached(struct inode *inode, u64 seq);
void cetrafs_inode_note_local_file_seq(struct inode *inode, u64 seq);
u64 cetrafs_inode_local_file_seq(struct inode *inode);
u64 cetrafs_inode_local_file_seq_at(struct inode *inode);
u64 cetrafs_file_cache_drop_count(void);
u64 cetrafs_verdict_fill_count(void);
u64 cetrafs_journal_write_count(void);
u64 cetrafs_journal_held_slots(struct super_block *sb); /* journal.c: slots held by kept entries */
u64 cetrafs_bg_geom_read_count(void);
u64 cetrafs_pf_drain_count(void);
u64 cetrafs_pf_whole_sweep_count(void); /* zonegroup.c, BM-3 */
u64 cetrafs_giveback_block_count(void);
u64 cetrafs_convert_leaf_full_count(void);
u64 cetrafs_leaf_split_count(void);
u64 cetrafs_convert_spill_count(void);
u64 cetrafs_convert_widened_count(void);
u64 cetrafs_convert_healed_count(void);
u64 cetrafs_sparse_unit_count(void);
u64 cetrafs_convert_unit_busy_count(void);
u64 cetrafs_tree_any_leaf_count(void);
u64 cetrafs_tree_move_rerun_count(void);
u64 cetrafs_zero_inplace_block_count(void);
u64 cetrafs_tree_block_count(void);
u64 cetrafs_tree_read_count(void);
u64 cetrafs_file_cache_reconcile_count(void);
u64 cetrafs_foreign_free_leak_count(void);
u64 cetrafs_free_bmap_lookup_count(void);
/* Stage a record update for the namespace lock's release to publish --
 * see lock.c. Only for an inode in the lock set, and only for the
 * operation's last update to that record. */
void cetrafs_inode_stage_record(struct inode *inode, const cetrafs_inode_t *rec, bool fd_too, u32 read_nlink);
u32 cetrafs_inode_staged_nlink_base(struct inode *inode);
void cetrafs_inode_drop_staged_record(struct inode *inode);
bool cetrafs_inode_take_staged_record(struct inode *inode, cetrafs_inode_t *out, bool *out_fd_too);
bool cetrafs_inode_peek_staged_record(struct inode *inode, cetrafs_inode_t *out);
int cetrafs_inode_ns_mutex_lock(struct inode *inode);
void cetrafs_inode_ns_mutex_unlock(struct inode *inode);
void cetrafs_inode_ns_adopt(struct inode *inode);
void cetrafs_inode_ns_holder_set(struct inode *inode, bool held);
void cetrafs_inode_fd_stage(struct inode *inode, const cetrafs_inode_t *raw);
void cetrafs_inode_fd_overlay(struct inode *inode, cetrafs_inode_t *raw);
bool cetrafs_inode_fd_dirty_snap(struct inode *inode);
int cetrafs_inode_fd_overlay_checked(struct inode *inode, cetrafs_inode_t *raw, bool dirty_before);
/* read_raw_inode + fd_overlay as one torn-read-safe unit -- see inode.c */
int cetrafs_read_raw_inode_overlaid(struct super_block *sb, struct inode *inode, cetrafs_inode_t *raw);
bool cetrafs_inode_fd_take(struct inode *inode, cetrafs_inode_t *out, u64 *out_seq);
bool cetrafs_inode_fd_dirty(struct inode *inode);
void cetrafs_inode_fd_fold(struct inode *inode, cetrafs_inode_t *raw);
void cetrafs_inode_fd_published(struct inode *inode, u64 seq);
u64 cetrafs_inode_fd_seq(struct inode *inode);
void cetrafs_inode_fd_pub_lock(struct inode *inode);
void cetrafs_inode_fd_pub_unlock(struct inode *inode);
unsigned int *cetrafs_inode_tree_move_seq(struct inode *inode);
/* inode.c: a record's size, bounded by what the format can address. */
#define CETRAFS_MAX_FILE_BYTES (CETRAFS_MAX_FILE_BLOCKS * (u64) CETRAFS_BLOCK_SIZE)
static inline bool cetrafs_size_sane(u64 size)
{
    return size <= CETRAFS_MAX_FILE_BYTES;
}
int cetrafs_inode_ns_cas(struct super_block *sb,
                         u64 ino,
                         u64 generation,
                         const cetrafs_inode_t *seed,
                         void (*apply)(cetrafs_inode_t *rec, void *arg),
                         void *arg);
int cetrafs_write_raw_inode_fd(struct super_block *sb, u64 ino, const cetrafs_inode_t *src, struct inode *self);
int cetrafs_write_raw_inode_fd_planned(struct super_block *sb, u64 ino, const cetrafs_inode_t *src,
                                       struct inode *self, u64 plan_seq);
int cetrafs_inode_ns_zero_nlink(struct super_block *sb, u64 ino, const cetrafs_inode_t *seed);
/* Inode-number arbitration between a creator and an orphan scrub, on the
 * record itself -- see inode.c. */
int cetrafs_inode_birth_claim(struct super_block *sb, u64 ino, const cetrafs_inode_t *seed, bool *out_lost);
#define CETRAFS_RECLAIM_CLAIM 0
#define CETRAFS_RECLAIM_RELEASE 1
#define CETRAFS_RECLAIM_BIRTH_ABORT 2
/* Deferred queue only, never a record mutation: an evict's free whose
 * number could not be cleared -- clear it, THEN release (alloc.c,
 * cetrafs_free_inode_finish()). */
#define CETRAFS_RECLAIM_FINISH 3
/* Record mutations of a held free claim (inode.c, cetrafs_reclaim_mutate()):
 * take over a stale claimant's claim, and drop the xattr pointer of a
 * record whose number is about to be freed. */
#define CETRAFS_RECLAIM_STEAL 4
#define CETRAFS_RECLAIM_FORGET 5
int cetrafs_inode_reclaim_claim(struct super_block *sb, u64 ino, u64 generation, int mode, u64 *seq);
int cetrafs_inode_reclaim_claim_at(struct super_block *sb, u64 ino, u64 generation, int mode, u64 *seq, u64 expect,
                                   u32 from);
int cetrafs_inode_forget_tree(struct super_block *sb, u64 ino, u64 generation, u64 *seq);
bool cetrafs_inode_ns_held_by_current(struct inode *inode);
/* ->flock: the standard flock(2) interface onto the userspace-driven
 * whole-file exclusive lock, meaningful only under nofilelock. Fd-scoped
 * (released on the fd's close). See lock.c. */
struct file_lock;
int cetrafs_flock(struct file *file, int cmd, struct file_lock *fl);
int cetrafs_posix_lock_refuse(struct file *file, int cmd, struct file_lock *fl);
int cetrafs_lock_defrag_begin(struct inode *inode);
bool cetrafs_defrag_nofilelock_refused(void); /* lock.c, test-only control */
void cetrafs_lock_defrag_end(struct inode *inode);
bool cetrafs_lock_defrag_try_queue(struct inode *inode);
void cetrafs_lock_defrag_unqueue(struct inode *inode);
void cetrafs_lock_defrag_quiet_for(struct inode *inode, unsigned int secs);
bool cetrafs_lock_defrag_quiet(struct inode *inode);
bool cetrafs_lock_has_local_writer(struct inode *inode);
void cetrafs_lock_defrag_yielded_for(struct inode *inode, unsigned int secs);
void cetrafs_lock_defrag_rejudge_on_close(struct inode *inode);
bool cetrafs_lock_defrag_yielded(struct inode *inode);
bool cetrafs_lock_defrag_stop_asked(struct inode *inode);
void cetrafs_inode_identity_init(struct inode *inode);
extern struct kmem_cache *cetrafs_inode_cache;

// heartbeat.c
struct cetrafs_heartbeat {
    struct super_block *sb;
    struct delayed_work work;  /* the lease renewal, and nothing else */
    struct delayed_work maint; /* reclaim/drain/replay: unbounded, and not on the lease's clock */
    bool stopping;             /* unmount: no new maintenance pass (cetrafs_heartbeat_stop()) */
};
int cetrafs_heartbeat_start(struct super_block *sb, struct cetrafs_heartbeat **out_hb);
unsigned int cetrafs_heartbeat_interval_secs(struct super_block *sb);
void cetrafs_heartbeat_stop(struct cetrafs_heartbeat *hb);

// scrub.c -- background leaked-block reclaim
struct cetrafs_scrub; /* opaque; owned entirely by scrub.c */
int cetrafs_scrub_start(struct super_block *sb, struct cetrafs_scrub **out_s);
void cetrafs_scrub_stop(struct cetrafs_scrub *s);
u64 cetrafs_scrub_set_bytes_peak_count(void);
u64 cetrafs_scrub_cand_deferred_count(void); /* scrub.c: groups that kept no candidates for the candidate budget */
u64 cetrafs_scrub_unknown_record_count(void);
u64 cetrafs_half_born_settled_count(void);
u64 cetrafs_scrub_free_call_count(void);
u64 cetrafs_scrub_inode_ra_count(void);
u64 cetrafs_scrub_reclaimed_count(void);
u64 cetrafs_scrub_inflight_skip_count(void);
u64 cetrafs_scrub_dead_journal_skip_count(void);
u64 cetrafs_scrub_dead_journal_kept_count(void);
u64 cetrafs_scrub_orphans_count(void);
u64 cetrafs_scrub_cycle_count(void);
u64 cetrafs_scrub_last_start_unix(void);
u64 cetrafs_scrub_last_duration_ms(void);
/* raw-record extent walk (file.c) + BG data/bitmap geometry (alloc.c), both
 * consumed by the scrub. */
int cetrafs_raw_inode_holds_meta_block(struct super_block *sb, const cetrafs_inode_t *raw, u64 lba, bool *held);
int cetrafs_raw_inode_for_each_owned_block(struct super_block *sb,
                                           const cetrafs_inode_t *raw,
                                           void (*cb)(void *ctx, u64 phys, u32 len),
                                           void *ctx,
                                           bool fresh);
int cetrafs_bg_data_layout(struct super_block *sb,
                           u32 bg_id,
                           u64 *out_data_start,
                           u64 *out_data_count,
                           u64 *out_bmap_lba,
                           u64 *out_bmap_blocks);
int cetrafs_inode_is_allocated(struct super_block *sb, u64 ino, bool *out_set);
int cetrafs_data_block_is_allocated(struct super_block *sb, u64 lba, bool *out_set);
/* Handing a Block Group's bitmap over (BG release, ZG release): provably
 * empty on the bitmap and durable before the CAS; dropped from the cache
 * after it. See alloc.c. */
int cetrafs_bg_release_bitmap_ready(struct super_block *sb, u32 b);
void cetrafs_bg_release_drop_bitmap(struct super_block *sb, u32 b);

// journal.c -- per-NODE journal
struct cetrafs_journal; /* opaque; owned entirely by journal.c */
int cetrafs_journal_init(struct super_block *sb, struct cetrafs_journal **out_j);
void cetrafs_journal_free(struct cetrafs_journal *j);
int cetrafs_journal_attach_node(struct super_block *sb, u32 node_id);
int cetrafs_journal_sweep_own_claims(struct super_block *sb, u32 my_node_id);
/* The inode a journaled block belongs to (cetrafs_journal_header_t.owner_ino). */
struct cetrafs_journal_owner {
    u64 ino;
    u64 generation;
};
struct cetrafs_journal_owner cetrafs_journal_owner_of(struct inode *inode);
int cetrafs_journal_write_block(struct super_block *sb, struct cetrafs_journal_owner owner, struct buffer_head *bh,
                                u32 prev_crc);
unsigned int cetrafs_journal_batch_capacity(struct super_block *sb);
int cetrafs_journal_drain_retiring(struct super_block *sb);
int cetrafs_journal_settle_range(struct super_block *sb, u64 first, u64 count);
u64 cetrafs_release_journal_drain_count(void);
u64 cetrafs_convert_source_flush_count(void);
u64 cetrafs_deferred_batch_count(void);
u64 cetrafs_deferred_batch_flush_count(void);
int cetrafs_journal_write_deferred(struct super_block *sb, struct buffer_head **bhs,
                                   const struct cetrafs_journal_owner *owners, const u32 *disk_crc, unsigned int n,
                                   bool *written, u32 *wcrc);

/* leafdefer.c: a regular file's tree blocks, held back from the device
 * until a boundary and then journaled in one batch. A deferred buffer is
 * NOT dirty -- writeback must never write it -- so it carries its own
 * bit, and every "does this buffer hold a write the device has not seen?"
 * asks cetrafs_bh_pending(). */
#include <linux/buffer_head.h>
enum { BH_CetraDeferred = BH_PrivateStart, BH_CetraTailStale, BH_CetraHeld, BH_CetraBmap };
BUFFER_FNS(CetraDeferred, cetra_deferred)
/* ioutil.c: an allocation-bitmap block modified in cache and HELD from
 * the device until cetrafs writes it at one of its own gated points
 * (cetrafs_held_flush()). Not dirty, so the block layer's writeback
 * never writes it -- after a freeze that outlived the lease, writeback
 * used to race the self-fence's sweep and lay this node's stale bitmap
 * over a peer's (audit 2026-11-14 A-15). Pinned and listed per sb. */
BUFFER_FNS(CetraHeld, cetra_held)
TAS_BUFFER_FNS(CetraHeld, cetra_held)
/* alloc.c: a data-allocation bitmap block, of a Block Group this node
 * owns -- the one held block whose refused write may wait for a retry
 * (cetrafs_keep_refusal_survivable(), A-4). Set by every update. */
BUFFER_FNS(CetraBmap, cetra_bmap)
u64 cetrafs_bmap_refusal_count(void);
u64 cetrafs_held_refusal_count(void);
u64 cetrafs_space_wait_count(void);
u64 cetrafs_close_space_wait_count(void);
void cetrafs_bh_end_update_held(struct super_block *sb, struct buffer_head *bh, bool changed);
int cetrafs_held_flush(struct super_block *sb);
int cetrafs_held_flush_nowait(struct super_block *sb);
unsigned long cetrafs_held_drop_all(struct super_block *sb);
struct xarray *cetrafs_sb_held(struct super_block *sb);
u64 cetrafs_held_unlisted_count(void); /* ioutil.c, F-27 */
u64 cetrafs_keep_lock_deferred_count(void); /* ioutil.c */
u64 cetrafs_dio_nospc_probe_count(void); /* file.c, BM-15 */
u64 cetrafs_dio_nospc_found_count(void); /* file.c, BM-15 */
void cetrafs_held_unlist(struct super_block *sb, struct buffer_head *bh);
unsigned long cetrafs_held_listed(struct super_block *sb);
u64 cetrafs_held_flush_count(void);
/* A held-back tree block edited since its tail was last stamped: the
 * eh_generation and magic are current, the tail CRC is not. Stamped once
 * where the image leaves memory (cetrafs_blk_tail_settle()), under the
 * buffer lock. Only ever set on a buffer that is also CetraDeferred. */
BUFFER_FNS(CetraTailStale, cetra_tail_stale)
TAS_BUFFER_FNS(CetraTailStale, cetra_tail_stale)
void cetrafs_blk_tail_settle(struct buffer_head *bh);
u64 cetrafs_tail_lazy_count(void);
static inline bool cetrafs_bh_pending(const struct buffer_head *bh)
{
    return buffer_dirty(bh) || buffer_cetra_deferred(bh) || buffer_cetra_held(bh);
}
int cetrafs_bh_defer_update(struct inode *inode, struct buffer_head *bh, u32 prev_crc);
int cetrafs_write_deferred_target(struct super_block *sb, struct buffer_head *bh, u32 *wcrc);
struct cetrafs_dtarget_io {
    struct completion done;
    int status;
};
int cetrafs_submit_deferred_target(struct super_block *sb, struct buffer_head *bh, u32 *wcrc,
                                   struct cetrafs_dtarget_io *io);
int cetrafs_wait_deferred_target(struct super_block *sb, struct buffer_head *bh, struct cetrafs_dtarget_io *io);
bool cetrafs_tree_refusal_survivable(struct super_block *sb, sector_t block, int status);
u64 cetrafs_tree_refusal_count(void);
u64 cetrafs_alloc_damaged_skip_count(void); /* zonegroup.c, BM-6 */
int cetrafs_wait_meta_write(struct super_block *sb, struct buffer_head *bh);
void cetrafs_bh_end_update_deferred(struct buffer_head *bh);
void cetrafs_bh_deferred_unlist(struct super_block *sb, struct buffer_head *bh, bool drop);
void cetrafs_bh_deferred_settle(struct super_block *sb, struct buffer_head *bh, u32 written_crc);
void cetrafs_deferred_unlist_locked(struct super_block *sb, struct buffer_head *bh, bool drop);
void cetrafs_deferred_settle_locked(struct super_block *sb, struct buffer_head *bh, u32 written_crc);
u32 cetrafs_deferred_disk_crc(struct super_block *sb, struct buffer_head *bh, u32 fallback);
void cetrafs_deferred_forget_range(struct super_block *sb, u64 lba, u32 count);
void cetrafs_deferred_evict(struct inode *inode);
struct list_head *cetrafs_inode_deferred(struct inode *inode);
bool cetrafs_deferred_inode_pending(struct inode *inode); /* leafdefer.c */
extern bool cetrafs_deferred_flush_no_inode; /* leafdefer.c, TEST ONLY */
time64_t *cetrafs_inode_label_seen_at(struct inode *inode);
u64 cetrafs_label_invalidation_count(void);
u64 cetrafs_refresh_ns_reread_count(void);
struct list_head *cetrafs_sb_deferred_orphans(struct super_block *sb);
void cetrafs_deferred_capped(struct inode *inode);
int cetrafs_deferred_room(struct inode *inode);
u64 cetrafs_deferred_room_refusal_count(void);
u64 cetrafs_deferred_cap_flush_count(void);
/* Held-back tree blocks' update path (P9): CRCs computed by the update
 * and stamp paths, re-holds of an already-held block, and the list steps
 * the eager control walks. leafdefer.c / ioutil.c. */
u64 cetrafs_update_crc_count(void);
bool cetrafs_deferred_eager(void);
u64 cetrafs_deferred_hold_count(void);
u64 cetrafs_deferred_list_step_count(void);
int cetrafs_deferred_flush_inode(struct inode *inode, bool mapping_locked);
int cetrafs_deferred_flush_orphans_of(struct super_block *sb, u64 ino);
int cetrafs_deferred_flush_all(struct super_block *sb);
unsigned long cetrafs_deferred_drop_all(struct super_block *sb);
int cetrafs_journal_write_new_block(struct super_block *sb, struct buffer_head *bh);
void cetrafs_journal_shutdown(struct super_block *sb);
int cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim);
#define CETRAFS_REPLAY_STRICT U64_MAX
/* The blocks stale nodes' dirty journals can name (journal.c, F-40). */
struct cetrafs_journal_ref {
    u64 phys, len;
};
struct cetrafs_journal_refs {
    struct cetrafs_journal_ref *v;
    u32 n, cap;
};
int cetrafs_journal_dead_refs(struct super_block *sb, struct cetrafs_journal_refs *r, bool *out_any);
int cetrafs_journal_retire_node(struct super_block *sb, u32 node_id, u32 incarnation, u32 *out);
void cetrafs_journal_refs_free(struct cetrafs_journal_refs *r);
int cetrafs_journal_replay_node_scoped(struct super_block *sb, u32 node_id, bool wait_for_claim, u64 scope);
int cetrafs_journal_node_is_dirty(struct super_block *sb, u32 node_id, bool *out_dirty);
int cetrafs_journal_node_redo_pending(struct super_block *sb, u32 node_id, bool *out_pending);
void cetrafs_journal_retry_release(struct super_block *sb);
bool cetrafs_journal_release_pending(struct super_block *sb);
int cetrafs_journal_fence_park(struct super_block *sb, u32 node_id);

// procfs.c
struct cetrafs_proc_mount; /* opaque; owned entirely by procfs.c */
int cetrafs_proc_module_init(void);
void cetrafs_proc_module_exit(void);
int cetrafs_proc_mount_init(struct super_block *sb, struct cetrafs_proc_mount **out_pm);
void cetrafs_proc_mount_exit(struct cetrafs_proc_mount *pm);
