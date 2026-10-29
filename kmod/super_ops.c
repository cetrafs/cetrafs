// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/seq_file.h>
#include <linux/statfs.h>

#include "kmod.h"

static void cetrafs_put_super(struct super_block *sb)
{
    fs_debug(info, "cetrafs_put_super");
    /* cetrafs_free_sb_info() stops the heartbeat tick synchronously
     * before freeing anything -- deliberately done
     * *before* sync/invalidate below, so no tick can race with tearing
     * down the backing device. */
    cetrafs_free_sb_info(sb);
    /* Flush and invalidate backing device */
    if (sb->s_bdev) {
        sync_blockdev(sb->s_bdev);
        invalidate_bdev(sb->s_bdev);
    }
}

static int cetrafs_write_inode(struct inode *inode, struct writeback_control *wbc)
{
    int ret;

    /*
     * A DIRECTORY's record is never writeback's to publish. Every
     * mutation of it -- mkdir, add/remove entry, growth, rename,
     * setattr -- persists the record synchronously (direct sync write
     * or the namespace lock's CAS), so the only dirt writeback can
     * hold for a directory is a stat echo of changes already on the
     * device, read-merged-written here with NO namespace lock.
     *
     * That blind merge can land AFTER a peer's update and re-publish
     * the old record. Caught frozen on a 3-node nofilelock run
     *: a directory rmdir'd by one node sat on disk with
     * nlink=2 again and its old dirent_seq restored -- which then
     * SELF-SATISFIED the holder's dirent freshness gate, pinning a
     * stale view where the same name resolved to two different inodes
     * on two nodes. Rule 4: a writer reachable with no lock drops its
     * dirt rather than clobbering. (setattr is not this path -- it
     * calls cetrafs_write_vfs_inode() directly, under the namespace
     * cluster.)
     */
    if (S_ISDIR(inode->i_mode))
        return 0;

    fs_debug(info, "cetrafs_write_inode ino=%llu", (unsigned long long) inode->i_ino);

    ret = cetrafs_write_vfs_inode(inode);
    if (ret)
        fs_debug(info, "cetrafs_write_inode ino=%llu failed: %d", (unsigned long long) inode->i_ino, ret);

    return ret;
}

/*
 * sync(2) / syncfs(2) / fsfreeze.
 *
 * This was a stub whose comment -- "nothing persistent yet" -- stopped
 * being true a long time ago. Free-space accounting is ACCRUED in
 * memory (alloc.c's per-BG dirty set, zonegroup.c's per-ZG delta) and
 * applied at four durability boundaries: a file-lock close, a namespace
 * lock release, evict_inode, and unmount. A file that is simply held
 * open and written hits none of them, so its allocations sat in memory
 * with nothing an administrator could do to force them out.
 *
 * Unmount was unaffected (generic_shutdown_super() syncs and then calls
 * ->put_super, which flushes). What was affected is the case this
 * filesystem is actually built for: fsfreeze before a SAN snapshot of a
 * VM-image datastore. freeze_super() reaches durability through
 * sync_filesystem() -> ->sync_fs, so the snapshot captured free-space
 * counters that did not match the bitmaps they summarise.
 */
static int cetrafs_sync_fs(struct super_block *sb, int wait)
{
    fs_debug(info, "cetrafs_sync_fs wait=%d", wait);
    /* Allocation bits before the counters: the counters are a cache and
     * a stale one is a lying df, while an un-durable allocation bit is
     * a block two files can end up sharing. */
    {
        int bret = cetrafs_alloc_flush_bitmaps(sb);
        int cret = cetrafs_flush_dirty_free_counts(sb);

        return bret ? bret : cret;
    }
}

/*
 * Real statfs: reports actual totals/free counts instead of the previous
 * all-zero stub. free_blocks comes from each BG descriptor's cached
 * free_data_blocks (one block read per BG, not a bitmap scan);
 * free_inodes from the in-memory cache in cetrafs_sb_info -- both kept in
 * sync by alloc.c on every alloc/free.
 *
 * Found via real two-node testing: a BG's cached descriptor
 * is only ever kept in sync by the *owning* node's own writes
 * (cetrafs_bg_adjust_free_blocks()) -- a node reading another node's BG
 * here has no such guarantee, so its statfs() kept reporting the exact
 * same free-block count forever, never reflecting a peer's writes at
 * all. Forcing each BG descriptor block fresh before reading it fixes
 * cross-node visibility; the per-BG cost here is acceptable (statfs is
 * nowhere near as hot as zonegroup.c's per-block cetrafs_alloc_pick_bg(),
 * which deliberately keeps trusting its own cached ownership instead --
 * see that function's own comment for why forcing freshness there was
 * the actual "extremely slow" bug).
 */
static int cetrafs_statfs(struct dentry *dentry, struct kstatfs *stat)
{
    struct super_block *sb = dentry->d_sb;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 total_blocks = 0, free_blocks = 0, free_inodes;
    u32 zg_count, zg_id;
    int ret;

    fs_debug(info, "cetrafs_statfs");

    if (!raw_sb)
        return -EINVAL;

    /*
     * Free space comes from the ZONE GROUP aggregates, not a sweep of
     * every Block Group descriptor.
     *
     * Sweeping reads all block_group_count descriptors and forces every
     * one this node does not own back from the device, since a peer's
     * writes are invisible in our cache. On a volume with 2047 BGs of
     * which this node owns 127, that is ~1920 synchronous 4 KiB reads
     * per statfs -- and pvestatd polls statfs every ~10 s, harder during
     * a clone.
     *
     * The ZG record's free_data_blocks is the sum over its member BGs,
     * not a second drifting number: alloc.c rolls the SAME delta into
     * both, both are applied by CAS at the same durability boundaries,
     * both are reconciled from the bitmaps on ownership transfer, and
     * fsck cross-checks ZG == sum of its BGs. Same answer, 16 ZG records
     * instead of 2047 descriptors.
     *
     * Our own accrued-but-unapplied delta is folded in, or the owner's
     * writes would not move its own df until the next boundary.
     */
    zg_count = le32_to_cpu(raw_sb->zone_group_count);
    for (zg_id = 0; zg_id < zg_count; zg_id++) {
        struct cetrafs_zg_info zi;
        s64 zfree;

        ret = cetrafs_zg_get_info(sb, zg_id, &zi);
        if (ret)
            return ret;

        zfree = (s64) zi.free_data_blocks + cetrafs_sb_zg_pending_delta(sb, zg_id);
        free_blocks += zfree > 0 ? (u64) zfree : 0;
        /* Capacity of unowned Block Groups sharded to this record: a
         * handed-back BG belongs to no ZG, so without this bucket df
         * would shrink by the group's full size at every surplus
         * release (the cross-node suite caught exactly that). */
        free_blocks += zi.pool_free_blocks;
    }

    /* Capacity is fixed at mkfs time, so it is computed once at mount
     * rather than re-derived from every descriptor on every call. */
    total_blocks = cetrafs_sb_total_data_blocks(sb);

    ret = cetrafs_sb_get_free_inodes(sb, &free_inodes);
    if (ret)
        return ret;

    stat->f_type = CETRAFS_MAGIC;
    stat->f_bsize = sb->s_blocksize;
    stat->f_blocks = total_blocks;
    stat->f_bfree = free_blocks;
    stat->f_bavail = free_blocks;
    stat->f_files = le32_to_cpu(raw_sb->inodes_count);
    stat->f_ffree = free_inodes;
    stat->f_namelen = CETRAFS_FILENAME_MAX;
    return 0;
}

/*
 * Freeing a deleted inode's blocks and bitmap bit the moment nlink hits
 * 0 is wrong whenever anything still holds the in-core VFS inode -- an
 * open fd on this node being the common case, and POSIX unlink-while-
 * open is meant to keep working until the last close. It also lets
 * cetrafs_alloc_inode() hand the same number to a new, differently
 * typed file while the old object is still in icache: cetrafs_iget()'s
 * cache-hit path refreshes stat fields but never i_op/i_fop/a_ops, so
 * the reused object keeps the old type's operations. Hold an fd on a
 * directory, rmdir it, then create a symlink landing on that number and
 * page_symlink() calls a NULL write_begin().
 *
 * So the free is deferred to eviction, as ext2 and friends do it. The
 * nlink-hits-0 sites in dir.c persist nlink=0 and let the VFS's default
 * drop_inode call this once the last reference goes -- immediately in
 * the common case, deferred when something still has it open. A number
 * can no longer be reused while a VFS object for it is alive, and the
 * same-node half of unlink-while-open works: a local reader keeps its
 * data until it closes.
 *
 * This also frees a lazily-allocated xattr block, which nothing freed on
 * final deletion before -- only xattr.c's "last xattr removed" path did
 * -- so deleting a file with user.* xattrs leaked its block.
 *
 * NOT a full fix for unlink-while-open in a CLUSTER: it defers only
 * until this node's last local reference. A read-only open takes no
 * cross-node lock, so a peer can unlink a file this node has open for
 * read and free the blocks under it. Solving that needs silly-rename or
 * cross-node open counting; neither exists here, and it is documented
 * as a limitation rather than left looking more fixed than it is.
 */
static void cetrafs_evict_inode(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;

    truncate_inode_pages_final(&inode->i_data);

    /* Last stop for a speculative allocation run. ->release() normally
     * returns it, but an inode can reach eviction without one (an
     * aborted open, a file unlinked while held) and the reserved blocks
     * are set in the bitmap yet referenced by no extent -- skipping this
     * leaks every one of them. Idempotent, so the common double call is
     * free. */
    cetrafs_inode_drop_reservation(inode);

    if (!inode->i_nlink) {
        cetrafs_inode_t raw;
        u32 my_node_id = CETRAFS_NODE_ID_NONE;
        int ret;

        /* The read that decides which blocks to hand back must not come
         * from this node's cache. */
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
        /* v0x0005: the device's file sector can lag this node's own
         * hot-path shadow -- blocks allocated into shadow-only extents
         * would be missed by the frees below and leaked. Fold (claim)
         * the shadow; eviction is this record's end of the line. */
        if (!ret)
            cetrafs_inode_fd_fold(inode, &raw);

        /*
         * ...and neither must the read that decides WHETHER to hand
         * anything back. The test above is inode->i_nlink: this node's
         * cached count, which says only that WE dropped our last name.
         * A peer that linked or renamed a name onto this file since
         * raised nlink on the DEVICE, and nothing refreshes our copy.
         *
         * Staleness has a direction here (CLAUDE.md rule 6): an older
         * nlink reads as FEWER names, so the stale answer is always the
         * destructive one. Freeing then returns a number a peer still
         * names to the allocator, the next create takes it, and two
         * live objects share one inode -- a directory and a file at the
         * same number, which is how a name comes to resolve to
         * something that was never there.
         *
         * The fresh record is already in hand one line up; it simply
         * was not consulted for this. Generation is the companion
         * check: a mismatch means this number was recycled while we
         * held a dead in-core object, and freeing would hand away a
         * stranger's file.
         */
        if (!ret) {
            if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
                pr_warn("evict_inode: ino=%llu is a DIFFERENT file now (generation disk=%llu core=%llu) -- freeing nothing\n",
                        (unsigned long long) inode->i_ino,
                        (unsigned long long) cetrafs_le64(raw.generation),
                        (unsigned long long) cetrafs_inode_get_generation(inode));
                ret = -ESTALE;
            } else if (cetrafs_le32(raw.nlink) != 0) {
                pr_warn("evict_inode: ino=%llu still has %u name(s) on disk -- a peer named it since we dropped ours; freeing nothing\n",
                        (unsigned long long) inode->i_ino, (unsigned int) cetrafs_le32(raw.nlink));
                ret = -EBUSY;
            }
        }

        /*
         * Eviction is where a file is actually DESTROYED -- where its
         * blocks go back to the allocator and can be handed to someone
         * else -- so this is where "is anybody else still using it?"
         * has to be asked. It was asked only in cetrafs_unlink_locked()
         * and cetrafs_rename_locked(), which is both earlier and not
         * atomic with it: a peer's open takes the file lock and takes NO
         * namespace lock, so it can land between that check and this
         * destruction. P7's lesson in a new place -- two locks over one
         * record exclude nothing from each other, so the bridge has to
         * be at the moment that matters.
         *
         * Refusing leaves the inode number and its blocks allocated:
         * a bounded leak that fsck names, which is deliberately the same
         * trade the read-failure path below already makes. The
         * alternative is freeing blocks out from under a peer that is
         * still reading or writing them through an open fd.
         */
        if (!ret && cetrafs_sb_get_node_id(sb, &my_node_id) == 0) {
            bool blocked = false;

            bool reader = false;

            /* One forced-fresh read for both questions:
             * this used to be two, each invalidating and re-reading the
             * same record. */
            if (cetrafs_lock_foreign_user_exists(sb, inode->i_ino, my_node_id, &blocked, &reader) == 0 &&
                (blocked || reader)) {
                pr_err(
                    "evict_inode: ino=%llu is still open on another node -- leaving its inode number and data "
                    "blocks allocated rather than freeing them underneath it\n",
                    (unsigned long long) inode->i_ino);
                ret = -ETXTBSY;
            }
        }

        /*
         * If the raw read failed, free NEITHER. Freeing the inode number
         * while this file's data blocks were never freed is a permanent,
         * untraceable leak: cetrafs_free_inode() clears only the bitmap
         * bit and leaves the stale table record naming those extents, so
         * the only evidence of which blocks leaked disappears the moment
         * some later file reuses the number. That showed up on live
         * hardware as an empty root directory beside a 128 MiB run of
         * in-use blocks that no record anywhere referenced.
         *
         * So a lost read is never absorbed by freeing the number anyway:
         * the leak stays bounded to one diagnosable inode (nlink=0,
         * never evicted) instead of becoming a hole in the data bitmap.
         */
        if (!ret) {
            /*
             * The NUMBER first, and only its winner frees the BLOCKS.
             *
             * Two nodes can evict the same dead inode concurrently --
             * both cached it, both saw nlink reach 0, both pass every
             * fresh-read guard above -- and block frees are not
             * idempotent: each appends its own pending-free entry for
             * the same foreign-ZG block, the owner's first drain clears
             * the bit and may reallocate it, and the second entry then
             * frees a LIVE file's block.
             *
             * cetrafs_free_inode()'s bitmap CAS is the arbiter: exactly
             * one caller sees "freed by me" (0) and everyone else
             * "already free" (1). That includes the scrub's orphan
             * reclaim, which frees only numbers.
             *
             * "Exactly one" depends on the CAS layer NOT flattening a
             * mutate's "already clear" into plain success -- do that and
             * every evict is told it won (see
             * cetrafs_bmap_cas_ctx.cleared).
             *
             * A crash between the number-free and the block frees leaves
             * blocks set and referenced by no allocated record: the leak
             * the scrub reclaims, which is the safe direction (rule 8).
             */
            int fret = cetrafs_free_inode(sb, inode->i_ino);

            ctrace("EVICTFREE ino=%llu fret=%d gen=%llu\n", (unsigned long long) inode->i_ino, fret,
                   (unsigned long long) cetrafs_inode_get_generation(inode));
            if (fret == 0) {
                cetrafs_free_inline_extents(inode, &raw);
                if (raw.xattr_block)
                    cetrafs_free_data_block(sb, cetrafs_le64(raw.xattr_block));
            }
            /* fret == 1: a peer's evict or the scrub won -- the blocks
             * are theirs (or the block scrub's). fret < 0: the CAS
             * failed; leave everything allocated and diagnosable. */
        } else if (ret != -ETXTBSY && ret != -ESTALE && ret != -EBUSY) {
            /* -ETXTBSY/-ESTALE/-EBUSY are the "somebody else still has
             * a claim on this" refusals above; each logs its own
             * reason. Only a genuine read failure belongs here. */
            pr_err(
                "evict_inode: ino=%llu raw-inode read failed (%d), leaving its inode number and data blocks "
                "allocated rather than leaking them untraceably\n",
                (unsigned long long) inode->i_ino, ret);
        }

        /* cetrafs_free_inline_extents()/cetrafs_free_data_block() above
         * only mark the freed block(s)' BG (and, via alloc.c's
         * owner_zg rollup, ZG) free_data_blocks dirty in memory
         * (batching, to avoid a sync per block) -- the other three
         * places that can dirty these this way (dir.c's
         * nslock.c's cetrafs_nslock_release(), lock.c's close-time flush, fs.c's
         * unmount catch-all) each flush them themselves right after.
         * Eviction needs the same treatment: it runs *after*
         * the namespace lock's own release flush already returned (VFS
         * eviction happens outside dir.c's lock-wrapped unlink/rmdir
         * critical section, once the dentry's last reference drops),
         * so without this a peer's cross-node statfs would see stale
         * free-space counts until something unrelated happened to
         * flush it later -- caught via a real two-node space-
         * accounting test regression right after deferring the free
         * here. */
        cetrafs_flush_dirty_free_counts(sb);
    }

    clear_inode(inode);
}

/*
 * alloc_inode/free_inode (lock.c) back a private cetrafs_inode_info per
 * in-core inode -- needed starting an earlier phase to track this node's
 * own local open-for-write refcount on a cluster-locked file.
 */
/*
 * ->show_options: the filesystem's own half of the /proc/mounts line.
 *
 * Without this callback the VFS prints only its generic flags (rw,
 * relatime, ...) and NO cetrafs option ever appears -- so an operator
 * reading /proc/mounts could not tell whether a node was running with
 * the whole-file lock off, which on a cluster is the difference between
 * "a peer cannot open this image" and "it can". On a multipath cluster
 * that is the first thing worth knowing and the last place it was
 * visible.
 *
 * Only genuine mount options are printed, so the line stays
 * round-trippable: anything that rebuilds a mount command from
 * /proc/mounts must not be handed a word mount(8) would reject. The
 * per-mount timing controls (procfs 'controls') are therefore NOT shown
 * here -- they are tunables, not mount options.
 *
 * The EFFECTIVE mode is reported, not the one this node asked for. The
 * file-lock mode is cluster-wide: the first mounter establishes it and
 * later mounters inherit it, so a node that passed no option at all may
 * legitimately be running nofilelock. Printing the request would
 * describe the command line; printing the effect describes the
 * filesystem, which is what someone reading this during an incident
 * needs. The two cannot disagree the other way round -- an explicit
 * nofilelock against a lock-on cluster is refused at mount -- so what is
 * printed is always also a valid way to reproduce this state.
 */
static int cetrafs_show_options(struct seq_file *m, struct dentry *root)
{
    if (!cetrafs_sb_file_lock_enabled(root->d_sb))
        seq_puts(m, ",nofilelock");
    return 0;
}

const struct super_operations cetrafs_super_ops = {
    .alloc_inode = cetrafs_alloc_vfs_inode,
    .free_inode = cetrafs_free_vfs_inode,
    .put_super = cetrafs_put_super,
    .write_inode = cetrafs_write_inode,
    .evict_inode = cetrafs_evict_inode,
    .sync_fs = cetrafs_sync_fs,
    .statfs = cetrafs_statfs,
    .show_options = cetrafs_show_options,
};
