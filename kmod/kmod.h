/* SPDX-License-Identifier: GPL-2.0-or-later */

#include <linux/workqueue.h>

#include "cetrafs.h"

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
void cetrafs_free_sb_info(struct super_block *sb);
const cetrafs_superblock_t *cetrafs_sb_raw(struct super_block *sb);
int cetrafs_sb_adjust_free_inodes(struct super_block *sb, s64 delta);
int cetrafs_sb_get_free_inodes(struct super_block *sb, u64 *out);
int cetrafs_sb_get_node_id(struct super_block *sb, u32 *out);
/* Observer-local peer liveness: has this row's hb_seq stopped advancing
 * for longer than CETRAFS_NODE_STALE_SECS of OUR clock? Uses no
 * cross-node timestamp, so clock skew cannot affect it. */
bool cetrafs_sb_peer_progress_stale(struct super_block *sb, u32 node_id, u64 hb_seq, u32 peer_hb_interval);
void cetrafs_node_report_clock_skew(struct super_block *sb);
void cetrafs_node_seed_peer_watch(struct super_block *sb);
int cetrafs_node_my_uuid(u8 out[CETRAFS_NODE_UUID_LEN]);
int cetrafs_node_live_peer_exists(struct super_block *sb, const u8 *my_uuid, bool *out_exists);
/* The file-lock mode a LIVE peer advertises (the first mounter's choice),
 * or CETRAFS_FLOCK_MODE_UNSET if no live peer -- so a joining node inherits
 * the cluster's mode and the first mounter leads. See node.c. */
int cetrafs_node_cluster_file_lock_mode(struct super_block *sb, const u8 *my_uuid, u32 *out_mode);
/* Post-registration re-check: does any live peer now disagree with our mode?
 * Closes the simultaneous-mount race the pre-registration scan cannot. */
int cetrafs_node_file_lock_mode_conflict(struct super_block *sb, const u8 *my_uuid, u32 my_mode, bool *out_conflict);
/* Post-registration re-check for a no-CAW volume: is ANY live foreign row
 * registered? Closes the simultaneous-mount race the pre-registration gate
 * cannot (two racers can each pass it before the other's row exists). */
int cetrafs_node_single_mounter_conflict(struct super_block *sb, const u8 *my_uuid, bool *out_conflict);
extern unsigned int cetrafs_stale_secs;
extern unsigned int cetrafs_hb_interval_secs;
u64 cetrafs_sb_get_fence_epoch(struct super_block *sb);
void cetrafs_sb_set_fence_epoch(struct super_block *sb, u64 epoch);
int cetrafs_sb_get_node_uuid(struct super_block *sb, u8 out[CETRAFS_NODE_UUID_LEN]);
struct cetrafs_journal *cetrafs_sb_get_journal(struct super_block *sb);
struct cetrafs_defrag *cetrafs_sb_get_defrag(struct super_block *sb);
void cetrafs_sb_cache_zg_ownership(struct super_block *sb, u32 zg_id, u32 first_bg_id, u32 bg_count);
void cetrafs_sb_uncache_zg_ownership(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_owned_cached(struct super_block *sb, u32 zg_id, u32 *out_first_bg_id, u32 *out_bg_count);
bool cetrafs_sb_zg_pf_backoff_active(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_pf_note_drop(struct super_block *sb, u32 zg_id, u32 count, unsigned int backoff_ms);
bool cetrafs_sb_zg_pf_take_drops(struct super_block *sb, u32 zg_id, u64 *runs, u64 *blocks);
bool cetrafs_sb_owns_any_zg(struct super_block *sb);
bool cetrafs_sb_bg_is_ours(struct super_block *sb, u32 bg_id);
u32 cetrafs_sb_alloc_cursor(struct super_block *sb);
void cetrafs_sb_set_alloc_cursor(struct super_block *sb, u32 bg_id);
void cetrafs_sb_fence(struct super_block *sb, const char *reason);
bool cetrafs_sb_is_fenced(struct super_block *sb);
bool cetrafs_sb_defrag_draining(struct super_block *sb);
/* Per-mount defragmentation switches (procfs.c's 'controls' file).
 * _defrag_enabled() gates defragmentation entirely, the ioctl included;
 * _auto_defrag_enabled() gates only the background janitor. */
bool cetrafs_sb_defrag_enabled(struct super_block *sb);
bool cetrafs_sb_auto_defrag_enabled(struct super_block *sb);
bool cetrafs_sb_file_lock_enabled(struct super_block *sb);
void cetrafs_sb_set_defrag_enabled(struct super_block *sb, bool on);
void cetrafs_sb_set_auto_defrag_enabled(struct super_block *sb, bool on);
/* Cluster timing for THIS mount (procfs 'controls'); the module params
 * are the defaults. */
unsigned int cetrafs_sb_hb_interval_secs(struct super_block *sb);
unsigned int cetrafs_sb_stale_secs(struct super_block *sb);
void cetrafs_sb_set_hb_interval_secs(struct super_block *sb, unsigned int v);
void cetrafs_sb_set_stale_secs(struct super_block *sb, unsigned int v);
const struct cetrafs_caw_info *cetrafs_sb_caw(struct super_block *sb);
bool cetrafs_sb_caw_available(struct super_block *sb);
void cetrafs_sb_cas_lock(struct super_block *sb);
void cetrafs_sb_cas_unlock(struct super_block *sb);
void cetrafs_sb_alloc_lock(struct super_block *sb);
void cetrafs_sb_alloc_unlock(struct super_block *sb);
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
/* BG free counts (v0x0004): accrued per BG, applied by one epoch-guarded
 * CAS per dirty BG at the durability boundaries -- never left dirty in
 * the buffer cache (background writeback could land a stale count on a
 * stealing peer's fresh reconcile). See fs.c's bg_free_delta comment. */
/* Un-durable data-bitmap allocations: marked by the allocator, drained
 * at every durability boundary BEFORE the reference is published. See
 * cetrafs_sb_info.bmap_alloc_dirty. */
void cetrafs_sb_note_bmap_alloc(struct super_block *sb, u32 bg_id);
bool cetrafs_sb_take_bmap_alloc_dirty(struct super_block *sb, u32 bg_id);
int cetrafs_alloc_flush_bitmaps(struct super_block *sb);
void cetrafs_sb_accrue_bg_free(struct super_block *sb, u32 bg_id, s64 delta);
s64 cetrafs_sb_bg_pending_delta(struct super_block *sb, u32 bg_id);
u64 cetrafs_sb_bg_epoch(struct super_block *sb, u32 bg_id);
void cetrafs_sb_set_bg_epoch(struct super_block *sb, u32 bg_id, u64 seq);
void cetrafs_sb_accrue_zg_free(struct super_block *sb, u32 zg_id, s64 delta);
int cetrafs_flush_dirty_free_counts(struct super_block *sb);
/* Zone Groups carrying an unapplied free-count delta. A delta must
 * never outlive ownership of its ZG -- see fs.c. */
u32 cetrafs_sb_pending_zg_deltas(struct super_block *sb);
bool cetrafs_sb_zg_delta_pending(struct super_block *sb, u32 zg_id);
s64 cetrafs_sb_zg_pending_delta(struct super_block *sb, u32 zg_id);
u64 cetrafs_sb_total_data_blocks(struct super_block *sb);
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
#define CETRAFS_DM_MAX_DEPTH  3
int cetrafs_dm_underlying(struct block_device *bdev, dev_t *out, unsigned int max, unsigned int *out_n);
struct scsi_device;
/* A referenced scsi_device to send 'bdev's passthrough commands to when
 * bdev itself is not SCSI; NULL if none is usable. caller scsi_device_put()s. */
struct scsi_device *cetrafs_dmpath_sdev(struct block_device *bdev);
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
unsigned int cetrafs_cas_region_size(struct super_block *sb);
u64 cetrafs_cas_miscompare_count(void);
/* Device round trips an operation costs, made countable because neither
 * is visible in /sys/block: a CAW is a passthrough request the block
 * layer does not account, and a record write is one 4 KiB write among
 * many. */
u64 cetrafs_cas_op_count(void);
void cetrafs_cas_op_counted(void);
u64 cetrafs_record_write_count(void);
/* Foreign-free appends to a peer's pending-free queue (zonegroup.c). Zero
 * on a single-node/loop volume by construction; the only confirmation the
 * append path runs on a real multi-node volume. */
u64 cetrafs_pending_free_append_count(void);
/* Replay-claim outcomes (journal.c): how many of a dead peer's journal
 * areas this node replayed, and how many it found another node already
 * on. The loser of that race returns success silently, so the decline
 * count is the only evidence the race occurred. */
u64 cetrafs_journal_replay_count(void);
u64 cetrafs_journal_replay_decline_count(void);
u64 cetrafs_journal_replay_refused_count(void);
u64 cetrafs_journal_replay_torn_count(void);
extern bool cetrafs_pf_force_foreign;
u64 cetrafs_pf_full_scans_count(void);
u64 cetrafs_pf_drain_blocks_count(void);
u64 cetrafs_bg_recount_count(void);
u64 cetrafs_pf_drop_runs_count(void);
u64 cetrafs_pf_drop_blocks_count(void);
u64 cetrafs_journal_replay_skipped_count(void);
u64 cetrafs_journal_replay_applied_count(void);

/* file.c: FS_IOC_FIEMAP, shared with dir.c's inode_operations table */
int cetrafs_fiemap(struct inode *inode, struct fiemap_extent_info *fi, u64 start, u64 len);

/* ---- ioutil.c: the whole-block tail checksum ---- */
#define CETRAFS_BLK_TAIL_READ_RETRIES 5
void cetrafs_blk_tail_stamp(struct buffer_head *bh, u32 magic);
bool cetrafs_blk_tail_valid(const struct buffer_head *bh, u32 magic);
struct buffer_head *cetrafs_blk_tail_bread(struct super_block *sb, u64 lba, u32 magic, const char *what);
int cetrafs_cas_region(struct super_block *sb, u64 fs_lba, unsigned int region_idx, cetrafs_cas_fn mutate, void *priv);
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
int cetrafs_caw(struct block_device *bdev, u64 lba, unsigned int nblocks, const void *compare, const void *write_data);
const char *cetrafs_caw_class_name(enum cetrafs_caw_class klass);
void cetrafs_caw_probe_at_load(void);
void cetrafs_cas_selftest(struct super_block *sb, u32 my_node_id);
void cetrafs_cas_stress(struct super_block *sb, u32 my_node_id);
extern bool cetrafs_cas_selftest_enabled;

// ioutil.c
struct buffer_head *cetrafs_bread_uncached(struct super_block *sb, sector_t block);
void cetrafs_invalidate_block(struct super_block *sb, sector_t block);
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
void cetrafs_bh_end_update(struct buffer_head *bh);
void cetrafs_bh_copy_stable(struct buffer_head *bh, void *out, size_t len);
void cetrafs_bh_abort_update(struct buffer_head *bh);
/* sb_bread() that tolerates a concurrent invalidation of the same block
 * -- use for anything cetrafs_invalidate_block() can target. */
#define CETRAFS_BREAD_RETRIES 12
struct buffer_head *cetrafs_bread_retry(struct super_block *sb, sector_t block);
struct buffer_head *cetrafs_bread_uncached_retry(struct super_block *sb, sector_t block);
/* inode.c -- read an inode's external extent-leaf block at the right
 * freshness for who currently owns the file. */
struct buffer_head *cetrafs_read_leaf_bh(struct inode *inode, u64 lba);
struct buffer_head *cetrafs_read_dir_leaf_bh(struct inode *inode, u64 lba, bool fresh);
struct buffer_head *cetrafs_read_tree_bh(struct inode *inode, u64 lba, u32 tail_magic, const char *what);
struct buffer_head *cetrafs_read_index_bh(struct inode *inode, u64 lba);
int cetrafs_flush_tree_blocks(struct inode *inode, const cetrafs_inode_t *raw);
void cetrafs_tree_invalidate_cached(struct inode *inode, const cetrafs_inode_t *raw);
int cetrafs_tree_flatten(struct inode *inode, const cetrafs_inode_t *raw, cetrafs_extent_t **out_arr, u32 *out_n);
int cetrafs_tree_build(struct inode *inode, const cetrafs_extent_t *flat, u32 n, cetrafs_inode_t *raw, u64 *out_meta);
void cetrafs_tree_free_meta(struct inode *inode, const cetrafs_inode_t *raw);
u32 cetrafs_tree_extent_count(struct inode *inode, const cetrafs_inode_t *raw);
u64 cetrafs_flat_data_blocks(const cetrafs_extent_t *flat, u32 n);

// inode.c
struct inode *cetrafs_iget(struct super_block *sb, u64 ino);
int cetrafs_write_vfs_inode(struct inode *inode);
int cetrafs_read_raw_inode(struct super_block *sb, u64 ino, cetrafs_inode_t *out);
int cetrafs_write_raw_inode(struct super_block *sb, u64 ino, const cetrafs_inode_t *in, bool sync);
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
 * CAWPATH, NSHOLD, DSHRINK, EUCLEANDUMP, DIRTYREC, and the block-free
 * lifecycle set BLKALLOC, BLKFREE, BLKQUEUE, BLKAPPLY, PFDRAIN,
 * EVICTFREE that located the referenced-but-free double
 * free) with key=value fields, consumed by the analysers under
 * ctest/tools/.
 */
#ifdef CETRAFS_TRACE
#define ctrace(fmt, ...) pr_warn(fmt, ##__VA_ARGS__)
#else
#define ctrace(fmt, ...) \
    do {                 \
    } while (0)
#endif

u64 cetrafs_inode_lba(struct super_block *sb, u64 ino);
u32 cetrafs_inode_crc_ns(const cetrafs_inode_t *in);
u32 cetrafs_inode_crc_fd(const cetrafs_inode_t *in);
bool cetrafs_inode_crcs_ok(const cetrafs_inode_t *in);
void cetrafs_inode_stamp_crc(struct super_block *sb, cetrafs_inode_t *in);    /* whole record: echoes + both sector CRCs */
void cetrafs_inode_stamp_crc_ns(cetrafs_inode_t *in); /* sector 0 only (the CAS mutates) */
void cetrafs_inode_stamp_crc_fd(struct super_block *sb, cetrafs_inode_t *in);
u64 cetrafs_file_seq_new(struct super_block *sb); /* sector 1 only (the file-path publish) */
int cetrafs_apply_raw_to_vfs_inode(struct inode *inode, const cetrafs_inode_t *raw);
int cetrafs_refresh_vfs_inode_if_newer(struct inode *inode);
u64 cetrafs_inode_new_generation(struct super_block *sb);

// dir.c
int cetrafs_dir_add_entry(struct inode *dir, const struct qstr *name, u64 ino, u8 file_type);
int cetrafs_dir_remove_entry(struct inode *dir, const struct qstr *name, u64 *out_ino, u8 *out_file_type);
int cetrafs_dirent_block_init(struct super_block *sb, u64 lba);
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

// nslock.c -- the per-inode namespace lock
int cetrafs_nslock_acquire(struct inode *inode);
void cetrafs_nslock_release(struct inode *inode);
/* The widest set any single operation needs: rename's two parents, the
 * moved inode, and a replaced target. */
#define CETRAFS_NSLOCK_MAX_SET 4
int cetrafs_nslock_acquire_set(struct inode **inodes, int n);
void cetrafs_nslock_release_set(struct inode **inodes, int n);

// file.c
int cetrafs_inode_map_block(struct inode *inode, u32 iblock, bool create, u64 *out_lba);
void cetrafs_free_inline_extents(struct inode *dir, const cetrafs_inode_t *raw);
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
int cetrafs_alloc_inode(struct super_block *sb, u64 *out_ino);
int cetrafs_free_inode(struct super_block *sb, u64 ino);
int cetrafs_alloc_data_block(struct super_block *sb, u32 bg_id, u64 *out_lba);
int cetrafs_alloc_data_block_near(struct super_block *sb, u32 bg_id, u64 preferred_lba, u64 *out_lba);
int cetrafs_alloc_block_anywhere(struct super_block *sb, u32 *out_bg, u64 *out_lba);
int cetrafs_alloc_data_run(struct super_block *sb, u32 bg_id, u64 count, u64 *out_lba);
u32 cetrafs_alloc_run_after(struct super_block *sb, u32 bg_id, u64 start_lba, u32 max);
int cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count);
/* Inline so the BLKFREE/BLKQUEUE traces' from=%pS names the real caller,
 * not this wrapper. */
static inline int cetrafs_free_data_block(struct super_block *sb, u64 lba)
{
    return cetrafs_free_data_extent(sb, lba, 1);
}
int cetrafs_apply_pending_free(struct super_block *sb, u64 lba, u32 count, u32 expect_zg);
int cetrafs_count_free_inodes(struct super_block *sb, u64 *out_free);
int cetrafs_bg_data_block_stats(struct super_block *sb, u32 bg_id, u64 *out_total, u64 *out_free);
/* Recompute a BG's cached free count from its bitmap and correct it
 *. *out_delta is (truth - cached), for the caller to fix
 * the owning ZG's aggregate with. Only meaningful at a moment when this
 * node provably owns the BG. */
/* How many Block Groups cetrafs_get_block() will try before giving a
 * write ENOSPC. Each miss RECOUNTS the BG that lied, so every iteration
 * removes one wrong answer from the pool -- this bounds the work, it is
 * not a hope that retrying helps. */
#define CETRAFS_ALLOC_PICK_RETRIES 8u

int cetrafs_bg_reconcile_free_count(struct super_block *sb, u32 bg_id, s64 *out_delta);
/* Apply one accrued BG free-count delta as an epoch-guarded CAS. 0 means
 * consumed (applied, or loudly dropped as stale); negative only for real
 * I/O trouble, where the caller re-accrues. */
int cetrafs_bg_apply_free_delta(struct super_block *sb, u32 bg_id, s64 delta);
/* Seed this node's in-memory count epoch for every BG of a ZG whose
 * ownership entered the cache WITHOUT a reconcile (the tick re-attach
 * path) -- deltas accrued under an unseeded epoch would all be dropped. */
int cetrafs_bg_seed_count_epochs(struct super_block *sb, u32 first_bg, u32 bg_count);
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
unsigned long cetrafs_sb_bg_sweep_last(struct super_block *sb);
void cetrafs_sb_set_bg_sweep_last(struct super_block *sb, unsigned long when);
void cetrafs_bg_desc_refresh_foreign(struct super_block *sb, u32 bg_id);
u64 cetrafs_bg_desc_kept_count(void);
u64 cetrafs_bg_desc_refreshed_count(void);
u64 cetrafs_bg_pick_cursor_count(void);
u64 cetrafs_bg_pick_scan_count(void);
u64 cetrafs_map_call_count(void);
u64 cetrafs_map_block_count(void);
int cetrafs_bg_owner_zg_for_lba(struct super_block *sb, u64 lba, u32 *out_zg_id);
int cetrafs_bg_invalidate_cache(struct super_block *sb, u32 bg_id);

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
int cetrafs_node_is_stale(struct super_block *sb, u32 node_id, bool *out_stale);
/* The fence lease -- see cetrafs_node_entry_t.fence_epoch. */
void cetrafs_node_fence_peer(struct super_block *sb, u32 node_id, const char *what);
int cetrafs_node_self_fence_check(struct super_block *sb, u32 my_node_id, bool *out_fenced);
int cetrafs_node_get_entry(struct super_block *sb, u32 idx, cetrafs_node_entry_t *out);
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
int cetrafs_zg_scrub_adopt_one_stale(struct super_block *sb, bool *out_adopted);
int cetrafs_zg_queue_foreign_free(struct super_block *sb, u32 zg_id, u64 lba, u32 count);
int cetrafs_zg_drain_pending_frees(struct super_block *sb);
/* Read-only walk of a ZG's pending-free queue: the scrub must not treat
 * a block with a free already queued against it as a leak. */
int cetrafs_zg_pending_free_for_each(struct super_block *sb, u32 zg_id, void (*cb)(void *, u64, u32), void *ctx);
int cetrafs_alloc_pick_bg(struct super_block *sb, u32 *out_bg_id);
int cetrafs_alloc_pick_run(struct super_block *sb, u64 count, u64 *out_lba);
struct cetrafs_zg_info {
    u32 owner_node_id; /* CETRAFS_NODE_ID_NONE if unclaimed */
    u32 first_bg_id;
    u32 bg_count;
    u64 free_data_blocks;
};
int cetrafs_zg_get_info(struct super_block *sb, u32 zg_id, struct cetrafs_zg_info *out);
int cetrafs_zg_adjust_free_blocks(struct super_block *sb, u32 zg_id, s64 delta);
int cetrafs_zg_apply_free_delta(struct super_block *sb, u32 zg_id, s64 delta);
int cetrafs_compute_max_file_size(struct super_block *sb, loff_t *out_max);

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
int cetrafs_lock_foreign_claim_exists(struct super_block *sb, u64 ino, u32 my_node_id, bool *out_exists);
int cetrafs_lock_foreign_reader_exists(struct super_block *sb, u64 ino, u32 my_node_id, bool *out_exists);
/* Both of the above from ONE forced-fresh read, for the three sites
 * that ask both before destroying a file. */
int cetrafs_lock_foreign_user_exists(struct super_block *sb,
                                     u64 ino,
                                     u32 my_node_id,
                                     bool *out_writer,
                                     bool *out_reader);
bool cetrafs_lock_held_for_write_locally(struct inode *inode);
bool cetrafs_lock_identity_cache_trusted(struct inode *inode);
/* lock.c: default-mount lock suspension counters (procfs `info`). */
u64 cetrafs_lock_suspend_count(void);
u64 cetrafs_lock_resume_count(void);
/* file.c: the close-equivalent durability boundary for a file staying open. */
int cetrafs_file_make_durable(struct file *file);
bool cetrafs_inode_foreign_opener_cached(struct inode *inode);
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
/* For the paths that persist stat through a CAS stamp (lock.c's close
 * and lock-clear), where the committed record equals the in-core block. */
void cetrafs_inode_stat_baseline_from_incore(struct inode *inode);
/* inode.c: the three-way merge itself (declared here, after the struct). */
u64 cetrafs_inode_get_generation(struct inode *inode);
u64 cetrafs_inode_dirent_seq_cached(struct inode *inode);
void cetrafs_inode_set_dirent_seq_cached(struct inode *inode, u64 seq);
void cetrafs_inode_note_local_file_seq(struct inode *inode, u64 seq);
u64 cetrafs_file_cache_drop_count(void);
u64 cetrafs_journal_write_count(void);
u64 cetrafs_bg_geom_read_count(void);
u64 cetrafs_pf_drain_count(void);
u64 cetrafs_giveback_block_count(void);
u64 cetrafs_tree_block_count(void);
u64 cetrafs_tree_read_count(void);
u64 cetrafs_file_cache_reconcile_count(void);
u64 cetrafs_foreign_free_leak_count(void);
/* Stage a record update for the namespace lock's release to publish --
 * see lock.c. Only for an inode in the lock set, and only for the
 * operation's last update to that record. */
void cetrafs_inode_stage_record(struct inode *inode, const cetrafs_inode_t *rec, bool fd_too);
u32 cetrafs_inode_staged_nlink_base(struct inode *inode);
bool cetrafs_inode_take_staged_record(struct inode *inode, cetrafs_inode_t *out, bool *out_fd_too);
bool cetrafs_inode_peek_staged_record(struct inode *inode, cetrafs_inode_t *out);
void cetrafs_inode_ns_mutex_lock(struct inode *inode);
void cetrafs_inode_ns_mutex_unlock(struct inode *inode);
void cetrafs_inode_ns_holder_set(struct inode *inode, bool held);
void cetrafs_inode_fd_stage(struct inode *inode, const cetrafs_inode_t *raw);
void cetrafs_inode_fd_overlay(struct inode *inode, cetrafs_inode_t *raw);
bool cetrafs_inode_fd_take(struct inode *inode, cetrafs_inode_t *out);
bool cetrafs_inode_fd_dirty(struct inode *inode);
void cetrafs_inode_fd_fold(struct inode *inode, cetrafs_inode_t *raw);
void cetrafs_inode_fd_discard(struct inode *inode);
int cetrafs_inode_ns_cas(struct super_block *sb, u64 ino, u64 generation, const cetrafs_inode_t *seed,
                         void (*apply)(cetrafs_inode_t *rec, void *arg), void *arg);
int cetrafs_write_raw_inode_fd(struct super_block *sb, u64 ino, const cetrafs_inode_t *src, struct inode *self);
int cetrafs_inode_ns_zero_nlink(struct super_block *sb, u64 ino, const cetrafs_inode_t *seed);
bool cetrafs_inode_ns_held_by_current(struct inode *inode);
/* ->flock: the standard flock(2) interface onto the userspace-driven
 * whole-file exclusive lock, meaningful only under nofilelock. Fd-scoped
 * (released on the fd's close). See lock.c. */
struct file_lock;
int cetrafs_flock(struct file *file, int cmd, struct file_lock *fl);
int cetrafs_lock_defrag_begin(struct inode *inode);
void cetrafs_lock_defrag_end(struct inode *inode);
bool cetrafs_lock_defrag_try_queue(struct inode *inode);
void cetrafs_lock_defrag_unqueue(struct inode *inode);
extern struct kmem_cache *cetrafs_inode_cache;

// heartbeat.c
struct cetrafs_heartbeat {
    struct super_block *sb;
    struct delayed_work work;
};
int cetrafs_heartbeat_start(struct super_block *sb, struct cetrafs_heartbeat **out_hb);
unsigned int cetrafs_heartbeat_interval_secs(struct super_block *sb);
void cetrafs_heartbeat_stop(struct cetrafs_heartbeat *hb);

// scrub.c -- background leaked-block reclaim
struct cetrafs_scrub; /* opaque; owned entirely by scrub.c */
int cetrafs_scrub_start(struct super_block *sb, struct cetrafs_scrub **out_s);
void cetrafs_scrub_stop(struct cetrafs_scrub *s);
u64 cetrafs_scrub_reclaimed_count(void);
u64 cetrafs_scrub_orphans_count(void);
u64 cetrafs_scrub_cycle_count(void);
u64 cetrafs_scrub_last_start_unix(void);
u64 cetrafs_scrub_last_duration_ms(void);
/* raw-record extent walk (file.c) + BG data/bitmap geometry (alloc.c), both
 * consumed by the scrub. */
int cetrafs_raw_inode_for_each_owned_block(struct super_block *sb,
                                      const cetrafs_inode_t *raw,
                                      void (*cb)(void *ctx, u64 phys, u32 len),
                                      void *ctx);
int cetrafs_bg_data_layout(struct super_block *sb,
                           u32 bg_id,
                           u64 *out_data_start,
                           u64 *out_data_count,
                           u64 *out_bmap_lba,
                           u64 *out_bmap_blocks);
int cetrafs_inode_is_allocated(struct super_block *sb, u64 ino, bool *out_set);

// journal.c -- per-NODE journal
struct cetrafs_journal; /* opaque; owned entirely by journal.c */
int cetrafs_journal_init(struct super_block *sb, struct cetrafs_journal **out_j);
void cetrafs_journal_free(struct cetrafs_journal *j);
int cetrafs_journal_attach_node(struct super_block *sb, u32 node_id);
int cetrafs_journal_write_block(struct super_block *sb, struct buffer_head *bh, u32 prev_crc);
int cetrafs_journal_write_new_block(struct super_block *sb, struct buffer_head *bh);
void cetrafs_journal_shutdown(struct super_block *sb);
int cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim);
int cetrafs_journal_node_is_dirty(struct super_block *sb, u32 node_id, bool *out_dirty);

// procfs.c
struct cetrafs_proc_mount; /* opaque; owned entirely by procfs.c */
int cetrafs_proc_module_init(void);
void cetrafs_proc_module_exit(void);
int cetrafs_proc_mount_init(struct super_block *sb, struct cetrafs_proc_mount **out_pm);
void cetrafs_proc_mount_exit(struct cetrafs_proc_mount *pm);
