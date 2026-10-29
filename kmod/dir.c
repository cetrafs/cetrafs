// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/mnt_idmapping.h>
#include <linux/namei.h>
#include <linux/pagemap.h>
#include <linux/stat.h>
#include <linux/string.h>
#include <linux/timekeeping.h>
#include <linux/uidgid.h>

#include "kmod.h"

static int cetrafs_readdir(struct file *file, struct dir_context *dctx);

/*
 * fsync(2) on a DIRECTORY.
 *
 * This was simple_fsync(), which is not usable here: it is declared and
 * exported only on very recent kernels (present on 7.1, absent on 7.0
 * and on 6.12), so the module failed to build on the deployment kernel.
 * Writing it out is better than a version shim anyway -- it is four
 * lines, and it lets the guarantee be stated rather than inherited.
 *
 * What a directory fsync has to make durable here is less than it looks.
 * The dirent blocks themselves are ALREADY durable by the time any
 * namespace operation returns: cetrafs_journal_write_block() syncs the
 * target block under the namespace lock, because a peer must never be
 * able to see a directory this node has published but not written. What
 * is left is the directory's own inode record -- size, mtime and the
 * dirent_seq every peer's cache coherency depends on -- which ordinary
 * paths leave to write-back, plus a device cache flush so the whole lot
 * is on stable storage rather than merely handed to the device.
 *
 * sync_inode_metadata() rather than cetrafs_write_vfs_inode(): only the
 * VFS path clears the inode's dirty state, and a dirty inode is one
 * cetrafs_apply_raw_to_vfs_inode() refuses to refresh, so writing
 * the record directly here would quietly stop this directory accepting
 * cross-node refreshes. This avoids repeating a previous mistake.
 */
static int cetrafs_dir_fsync(struct file *file, loff_t start, loff_t end, int datasync)
{
    struct inode *inode = file->f_mapping->host;
    int ret, ret2;

    ret = file_write_and_wait_range(file, start, end);
    if (ret)
        return ret;

    /* No inode_lock: the VFS does not hold it across ->fsync and
     * sync_inode_metadata() does not want it, so taking it here would
     * be a lock this path does not need. */
    ret = sync_inode_metadata(inode, 1);

    ret2 = blkdev_issue_flush(inode->i_sb->s_bdev);
    return ret ? ret : ret2;
}

/* Directory file operations */
const struct file_operations cetrafs_dir_ops = {
    .owner = THIS_MODULE,
    .llseek = generic_file_llseek,
    .iterate_shared = cetrafs_readdir,
    .fsync = cetrafs_dir_fsync,
};

/*
 * Every namespace-mutating operation below (create/mkdir/unlink/rmdir/
 * rename/link/symlink) reads a directory's dirent block(s), decides what
 * to change, and writes the result back. Without cross-node mutual
 * exclusion, two nodes doing that to the same directory at once would
 * each clobber the other's write -- a lost directory entry or a corrupted
 * nlink. Each one is therefore split into a *_locked() worker plus a thin
 * wrapper that brackets it in nslock.c's per-inode namespace lock, held
 * on exactly the inodes that operation mutates.
 *
 * The per-inode namespace lock replaced the device-wide PR mutex this used
 * to use (cetrafs_ns_lock(), deleted) with that scoped lock: two nodes working
 * in two different directories no longer serialize against each other at
 * all, and an acquire is one atomic CAW instead of a SCSI
 * reserve/release pair.
 */

/* --- Dirent-block tail checksum (v0x0007) -----------------
 *
 * Lookups/readdir deliberately take no cluster mutex, so a reader can
 * observe a peer's in-flight dirent-block write torn -- and a torn
 * dirent block used to mis-parse silently (dirents had no integrity
 * check at all). Every dirent block now carries a {magic, crc} tail in
 * its natural slack (see include/cetrafs.h): writers stamp it right
 * before the journal+write+sync sequence, and readers verify it,
 * retrying the (uncached) read a few times on a mismatch -- a torn
 * observation is transient by construction, since the writer completes
 * its sync under the ns mutex. A block that NEVER converges is genuine
 * on-disk corruption and fails loudly with NULL (callers already treat
 * that as -EIO).
 */
#define CETRAFS_DIRENT_READ_RETRIES 20

static void cetrafs_dirent_block_stamp(struct buffer_head *bh)
{
    cetrafs_dirent_tail_t *tail = (cetrafs_dirent_tail_t *) (bh->b_data + CETRAFS_DIRENT_TAIL_OFF);

    tail->magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
    tail->crc = cetrafs_cpu_to_le32(~crc32c(~0U, bh->b_data, CETRAFS_DIRENT_TAIL_OFF));
}

static bool cetrafs_dirent_block_valid(const struct buffer_head *bh)
{
    const cetrafs_dirent_tail_t *tail = (const cetrafs_dirent_tail_t *) (bh->b_data + CETRAFS_DIRENT_TAIL_OFF);

    return cetrafs_le32(tail->magic) == CETRAFS_DIRENT_TAIL_MAGIC && cetrafs_le32(tail->crc) == ~crc32c(~0U, bh->b_data, CETRAFS_DIRENT_TAIL_OFF);
}

static struct buffer_head *cetrafs_dirent_bread(struct super_block *sb, u64 lba)
{
    int attempt;

    for (attempt = 0; attempt < CETRAFS_DIRENT_READ_RETRIES; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, lba);

        if (bh) {
            if (cetrafs_dirent_block_valid(bh))
                return bh;
            brelse(bh);
        }

        /* Back off between attempts rather than spinning. A mismatch
         * here means a writer on ANOTHER node has a partially-written
         * image of this block on the device; it converges once that
         * node's write completes. (A writer on THIS node cannot be seen
         * mid-update at all: cetrafs_bh_begin_update() holds the buffer
         * lock across modify-and-restamp, which the forced-fresh read
         * below blocks on.) Back off rather than spin, so the budget
         * spans a peer's write rather than a few microseconds.
         * (A NULL read is retried on the same footing -- it means a
         * concurrent forced-fresh read of the same block cleared the
         * uptodate bit under us, which is equally transient.) */
        usleep_range(100, 400);
    }

    pr_err("dirent block %llu failed its tail checksum %d times -- corrupted, not just a torn concurrent read\n",
           (unsigned long long) lba, CETRAFS_DIRENT_READ_RETRIES);
    return NULL;
}

/*
 * Make a freshly allocated block a valid, empty, durable dirent block.
 *
 * Called from file.c's cetrafs_get_block() the moment a block is
 * allocated for a DIRECTORY, before the extent referencing it is
 * committed. Ordering matters enormously here: a directory's data block
 * becomes reachable to every node the instant its extent lands (for a
 * depth-1 directory the leaf is journaled synchronously, so that is
 * immediate), and whatever the allocator just handed us still holds
 * whatever the block's previous owner left there. A peer walking the
 * directory in that window reads garbage, fails the tail checksum, and
 * -- since re-reading cannot fix it -- exhausts its retries and returns
 * -EIO. Observed on real two-node hardware as "dirent block 42242 failed
 * its tail checksum 20 times" with a create failing, while the very same
 * block was perfectly usable moments later.
 *
 * Synchronous on purpose: this has to be on the device before the extent
 * that points at it is.
 */
int cetrafs_dirent_block_init(struct super_block *sb, u64 lba)
{
    struct buffer_head *bh = cetrafs_getblk_overwrite(sb, lba);

    if (!bh)
        return -EIO;

    {
        /* Is this block really free? It is about to be zeroed as a
         * brand-new directory block. If it already carries a valid
         * dirent tail AND live entries, it still belongs to somebody:
         * the allocator handed out a block that is in use, and zeroing
         * it destroys every name in it -- files that are then gone on
         * every node, with their inodes left allocated and unnamed. */
        const cetrafs_dirent_t *_d = (const cetrafs_dirent_t *) bh->b_data;
        unsigned int _e, _n = 0;

        if (cetrafs_dirent_block_valid(bh)) {
            for (_e = 0; _e < CETRAFS_DIRENTS_PER_BLOCK; _e++)
                if (_d[_e].inode)
                    _n++;
            /* Dirent bytes alone prove nothing: freeing a block does
             * not zero it, so a recycled block still carries its old
             * directory's entries. In use means the '.' entry names a
             * LIVE directory that still lists this block. */
            if (_n) {
                u64 _self = cetrafs_le64(_d[0].inode);
                cetrafs_inode_t _r;

                cetrafs_invalidate_raw_inode(sb, _self);
                if (_self && cetrafs_read_raw_inode(sb, _self, &_r) == 0 && cetrafs_le32(_r.nlink) != 0 &&
                    S_ISDIR(cetrafs_le32(_r.mode))) {
                    u16 _i;
                    bool _listed = false;

                    for (_i = 0; _i < cetrafs_le16(_r.eh.eh_entries) && _i < ARRAY_SIZE(_r.et.leaf); _i++) {
                        u64 _p = cetrafs_extent_phys_from_hilo(_r.et.leaf[_i].ee_start_hi,
                                                               _r.et.leaf[_i].ee_start_lo);
                        u32 _l = cetrafs_extent_len(_r.et.leaf[_i].ee_len);

                        if (lba >= _p && lba < _p + _l)
                            _listed = true;
                    }
                    if (_listed)
                        pr_err("dirent_block_init: block %llu is being zeroed as new, but LIVE directory "
                               "ino=%llu (nlink=%u) still lists it and it holds %u name(s) -- the allocator "
                               "handed out a block that is STILL IN USE\n",
                               (unsigned long long) lba, (unsigned long long) _self,
                               (unsigned int) cetrafs_le32(_r.nlink), _n);
                }
            }
        }
    }
    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    cetrafs_dirent_block_stamp(bh);
    cetrafs_bh_end_update(bh);
    sync_dirty_buffer(bh);
    brelse(bh);
    return 0;
}

/*
 * Read a dirent block at the freshness this walk actually needs.
 *
 * 'fresh' comes from comparing the directory's on-disk dirent_seq (just
 * read forced-fresh with its record) against the seq at which this node
 * last read its blocks fresh. Equal means no node has mutated this
 * directory since, so the cached copies are current and cost nothing;
 * otherwise every block is pulled from the device as before.
 *
 * A cached block that fails its tail checksum falls back to a fresh
 * read rather than being trusted or rejected -- costing at most what
 * the old always-fresh path cost.
 */
static struct buffer_head *cetrafs_dirent_read(struct super_block *sb, u64 lba, bool fresh)
{
    struct buffer_head *bh;

    if (fresh)
        return cetrafs_dirent_bread(sb, lba);

    bh = sb_bread(sb, lba);
    if (bh) {
        if (cetrafs_dirent_block_valid(bh))
            return bh;
        brelse(bh);
    }
    return cetrafs_dirent_bread(sb, lba);
}

/*
 * A directory's content VERSION STAMP.
 *
 * This was a counter (seq + 1), and a counter cannot do this job. Every
 * node increments it from its own forced-fresh read, so two nodes that
 * both read 5 both write 6 -- for DIFFERENT content. A peer writing the
 * record from an older base rolls it backward just as easily (see
 * cetrafs_get_block()'s comment in file.c on blind full-record writes
 * reverting dirent_seq). Either way a reader whose cached stamp equals
 * the on-disk one concludes "nothing has changed since I read this" when
 * plenty has, and cetrafs_dir_needs_fresh() hands it stale blocks.
 *
 * Both directions were caught in one 3-node run: a walk of
 * an on-disk-EMPTY directory (size 532 = '.' + '..') that returned
 * found=1 out of cache, so rmdir refused a directory that was gone --
 * and the mirror case, found=0 for a POPULATED directory, so rmdir
 * removed one holding a peer's open files. Same equal-but-different
 * stamp, opposite sign.
 *
 * Only EQUALITY is ever asked of this value, never ordering, so it does
 * not need to count -- it needs to be unique per write. The generation
 * stamp already has that property (a nanosecond clock xor'd with the
 * node id), so any two writes by any two nodes differ, and a stale
 * revert differs from the reader's stamp too, which forces a fresh read:
 * the safe direction.
 */
static u64 cetrafs_dirent_seq_new(struct super_block *sb)
{
    return cetrafs_inode_new_generation(sb);
}

/*
 * Does this walk have to go to the device for every dirent block?
 *
 * The danger this guards against is not a stale ANSWER but a stale
 * DIRECTORY: a mutating path that writes back a cached block resurrects
 * entries removed since and erases entries added since, durably. A real
 * two-node run ended with four files still listed after unlinks that all
 * reported success, their blocks leaked -- the signature of exactly one
 * stale dirent block written back. So for a long time no mutating path
 * consulted this at all.
 *
 * cetrafs_dir_add_entry() now does, and the distinction is what makes
 * that safe: it uses the cache only to DECIDE (is this name taken, which
 * slot is free), and re-reads the single block it is about to modify
 * forced-fresh, re-verifying the decision against that image before
 * writing a byte. No cached image is ever written back, so the failure
 * above is unreachable by construction -- while the scan stops costing
 * one device round trip per block of the directory. The blocks it did
 * NOT re-read are consulted only for the duplicate check, which is the
 * same trust every lookup already places in this cache.
 *
 * cetrafs_dir_remove_entry() still reads fresh throughout: it modifies
 * the block it stops on, and it stops as soon as it finds the name, so
 * it has no complete pass to rest a claim on either way.
 */
static bool cetrafs_dir_needs_fresh(struct inode *dir, const cetrafs_inode_t *raw)
{
    return cetrafs_inode_dirent_seq_cached(dir) != cetrafs_le64(raw->dirent_seq);
}

/*
 * Visit every populated dirent (inode != 0) in 'dir', in logical order,
 * calling visit(priv, dirent, byte_pos) for each. visit() returns 0 to keep
 * going, a positive value to stop (not an error -- e.g. "found it"), or a
 * negative errno to abort with that error.
 *
 * Only depth-0 (fully inline) extent trees are supported -- that is all
 * mkfs can currently produce.
 */

/* --- Directory block mapping ------------------------------------------
 *
 * A directory's data blocks are addressed through the very same extent
 * tree a regular file uses, so these helpers resolve BOTH depth-0 (up to
 * 4 extents inline in the record) and depth-1 (spilled into one external
 * leaf block) rather than reaching into raw.et.leaf directly.
 *
 * Previously every walker here hand-iterated raw.et.leaf and
 * rejected eh_depth != 0, and the growth path appended one new extent
 * per new block with no contiguity merge -- so a directory could own at
 * most 4 blocks, i.e. 4 * CETRAFS_DIRENTS_PER_BLOCK = 60 dirents, two of
 * which are '.' and '..'. Creating the 59th file in ANY directory failed
 * with ENOSPC on an otherwise empty volume. Growth now goes
 * through file.c's cetrafs_inode_map_block(), which merges contiguous
 * blocks into the previous extent and spills past 4 extents into an
 * external leaf exactly as a regular file does.
 */
struct cetrafs_dir_extents {
    struct buffer_head *leaf_bh; /* held for depth 1, NULL for depth 0 */
    const cetrafs_extent_t *arr;
    u16 entries;
};

static int cetrafs_dir_extents_get(struct inode *dir, const cetrafs_inode_t *raw, struct cetrafs_dir_extents *de)
{
    de->leaf_bh = NULL;
    de->arr = NULL;
    de->entries = 0;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw->eh.eh_depth) > 1) {
        pr_warn_ratelimited("dir ino=%llu: bad extent header (magic=0x%x depth=%u entries=%u)\n",
                            (unsigned long long) dir->i_ino, raw->eh.eh_magic, raw->eh.eh_depth, raw->eh.eh_entries);
        return -EIO;
    }

    if (raw->eh.eh_depth == 0) {
        de->arr = raw->et.leaf;
        de->entries = min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf));
        return 0;
    }

    /* The leaf lists which data blocks this directory owns, so a stale
     * one makes a scan walk the wrong set of blocks and miss a peer's
     * growth block (duplicate names, INVISIBLE entries). Read it fresh
     * exactly when the dirent_seq gate says the directory changed
     * cross-node -- the same signal the dirent-block reads use -- so a
     * peer's growth forces a fresh leaf while a single writer's own
     * directory stays cached and O(1). See cetrafs_read_dir_leaf_bh(). */
    de->leaf_bh = cetrafs_read_dir_leaf_bh(
        dir, cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo),
        cetrafs_dir_needs_fresh(dir, raw));
    if (!de->leaf_bh) {
        pr_warn_ratelimited(
            "dir ino=%llu: extent-leaf block %llu unreadable\n", (unsigned long long) dir->i_ino,
            (unsigned long long) cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo));
        return -EIO;
    }

    de->arr = (const cetrafs_extent_t *) (de->leaf_bh->b_data + sizeof(cetrafs_extent_hdr_t));
    de->entries =
        min_t(u16, cetrafs_le16(((const cetrafs_extent_hdr_t *) de->leaf_bh->b_data)->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
    return 0;
}

static void cetrafs_dir_extents_put(struct cetrafs_dir_extents *de)
{
    if (de->leaf_bh)
        brelse(de->leaf_bh);
    de->leaf_bh = NULL;
}

/* Total data blocks this directory currently owns. */
static u64 cetrafs_dir_extents_nblocks(const struct cetrafs_dir_extents *de)
{
    u64 n = 0;
    u16 i;

    for (i = 0; i < de->entries; i++)
        n += cetrafs_extent_len(de->arr[i].ee_len);
    return n;
}

typedef int (*cetrafs_dirent_visit_fn)(void *priv, const cetrafs_dirent_t *de, loff_t pos);

static int cetrafs_walk_dirents(struct inode *dir, cetrafs_dirent_visit_fn visit, void *priv)
{
    unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    bool fresh;
    int ret, i;

    /* Any node can add/remove entries in any directory at any time (no
     * whole-file lock covers a directory the way lock.c covers a regular
     * file), so -- like every dirent data-block read in this file --
     * this directory's own inode record (its extent list/size, which
     * change when cetrafs_dir_add_entry() grows it) must never be
     * trusted from this node's local cache. See
     * cetrafs_invalidate_raw_inode()'s comment. */
    cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);

    if (ret)
        return ret;

    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret)
        return ret;

    fresh = cetrafs_dir_needs_fresh(dir, &raw);

    for (i = 0; i < dx.entries; i++) {
        const cetrafs_extent_t *ext = &dx.arr[i];
        u64 phys = cetrafs_extent_phys_from_hilo(ext->ee_start_hi, ext->ee_start_lo);
        u32 len = cetrafs_extent_len(ext->ee_len);
        u32 b;

        for (b = 0; b < len; b++) {
            loff_t base_pos = ((loff_t) cetrafs_le32(ext->ee_block) + b) * CETRAFS_BLOCK_SIZE;
            struct buffer_head *bh = cetrafs_dirent_read(dir->i_sb, phys + b, fresh);
            const cetrafs_dirent_t *de;
            unsigned int e;

            if (!bh) {
                ret = -EIO;
                goto out;
            }

            de = (const cetrafs_dirent_t *) bh->b_data;
            for (e = 0; e < dirents_per_block; e++) {
                if (de[e].inode == 0)
                    continue;

                ret = visit(priv, &de[e], base_pos + e * sizeof(cetrafs_dirent_t));
                if (ret > 0) {
                    brelse(bh);
                    ret = 0;
                    goto out;
                }
                if (ret < 0) {
                    brelse(bh);
                    goto out;
                }
            }
            brelse(bh);
        }
    }

    /* A pass that read every block fresh and ran to completion has put
     * the whole directory in cache at exactly this sequence; note that,
     * so the next walk can stay cached until someone mutates it. A pass
     * that stopped early (found what it wanted, or errored) has NOT
     * refreshed every block, so it must not claim this. */
    if (fresh)
        cetrafs_inode_set_dirent_seq_cached(dir, cetrafs_le64(raw.dirent_seq));
    ret = 0;
out:
    cetrafs_dir_extents_put(&dx);
    return ret;
}

/*
 * Find a free dirent slot in 'dir' (scanning its existing inline, depth-0
 * extents' data blocks), or grow the directory by one new data block if
 * every existing block is full and there's still room for another inline
 * extent (eh_entries < 4). Writes the new dirent there, then updates dir's
 * on-disk and in-core size/mtime/ctime (and nlink, if the new entry is
 * itself a directory). Returns 0, or a negative errno (-ENOSPC if the
 * directory has no free slot and no room left to grow).
 */
/* Is the slot this scan picked still empty in 'bh'? */
static bool cetrafs_dirent_slot_free(const struct buffer_head *bh, unsigned int idx)
{
    const cetrafs_dirent_t *de = (const cetrafs_dirent_t *) bh->b_data;

    return de[idx].inode == 0;
}

/* Does 'name' appear anywhere in this one dirent block? */
static bool cetrafs_dirent_block_has_name(const struct buffer_head *bh, const struct qstr *name)
{
    const cetrafs_dirent_t *de = (const cetrafs_dirent_t *) bh->b_data;
    unsigned int e;

    for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++) {
        if (de[e].inode == 0)
            continue;
        if (cetrafs_le16(de[e].name_len) == name->len && !memcmp(de[e].name, name->name, name->len))
            return true;
    }
    return false;
}

/*
 * One pass over a directory's dirent blocks that does two jobs at once:
 * refuse on a name collision, and report the first free slot.
 *
 * These used to be two separate full scans. The duplicate check has to
 * visit every block regardless, so the free slot is simply noted on the
 * way past.
 *
 * The free slot is reported as an (lba, index) PAIR rather than a
 * buffer, which is the point: the caller re-reads that one block
 * forced-fresh and re-verifies before writing into it, so handing back a
 * buffer this pass may have taken from the cache would defeat the whole
 * arrangement. See cetrafs_dir_needs_fresh().
 *
 * The collision check is not redundant with the caller's own VFS-level
 * negative-dentry lookup (the usual reason create/mkdir/link/symlink
 * believe this name is free to take): that is only ever a check against
 * THIS node's local dentry cache, and says nothing about what another
 * node's in-flight create of the identical name has already committed by
 * the time this call reaches the front of the namespace lock. Without
 * it, two nodes creating the same new name each found their own free
 * slot and wrote their own dirent -- both succeeding, leaving two
 * same-named dirents (different inodes) permanently coexisting, one
 * silently unreachable and its space leaked. Caught via a real two-node
 * repro. Safe for the rename-replace caller too: that path removes the
 * existing target's dirent before ever calling this, so by the time this
 * scan runs the name is genuinely gone.
 */
static int cetrafs_dir_scan_for_slot(struct inode *dir,
                                     const struct cetrafs_dir_extents *dx,
                                     const struct qstr *name,
                                     bool fresh,
                                     u64 *out_lba,
                                     unsigned int *out_idx,
                                     bool *out_found)
{
    int i;

    *out_found = false;

    for (i = 0; i < dx->entries; i++) {
        const cetrafs_extent_t *ext = &dx->arr[i];
        u64 phys = cetrafs_extent_phys_from_hilo(ext->ee_start_hi, ext->ee_start_lo);
        u32 len = cetrafs_extent_len(ext->ee_len);
        u32 b;

        for (b = 0; b < len; b++) {
            struct buffer_head *sbh = cetrafs_dirent_read(dir->i_sb, phys + b, fresh);
            const cetrafs_dirent_t *de;
            unsigned int e;

            if (!sbh) {
                pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during add\n",
                                    (unsigned long long) dir->i_ino, (unsigned long long) (phys + b));
                return -EIO;
            }

            de = (const cetrafs_dirent_t *) sbh->b_data;
            for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++) {
                if (de[e].inode == 0) {
                    /* Remember the first free slot, but keep scanning:
                     * the duplicate check is only meaningful if it
                     * covers EVERY block. */
                    if (!*out_found) {
                        *out_found = true;
                        *out_lba = phys + b;
                        *out_idx = e;
                    }
                    continue;
                }
                if (cetrafs_le16(de[e].name_len) == name->len && !memcmp(de[e].name, name->name, name->len)) {
                    fs_debug(info, "dir_add_entry: '%.*s' already exists as ino=%llu (block lba=%llu slot=%u)",
                             (int) name->len, name->name, (unsigned long long) cetrafs_le64(de[e].inode),
                             (unsigned long long) (phys + b), e);
                    brelse(sbh);
                    return -EEXIST;
                }
            }
            brelse(sbh);
        }
    }
    return 0;
}

int cetrafs_dir_add_entry(struct inode *dir, const struct qstr *name, u64 ino, u8 file_type)
{
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    struct buffer_head *bh = NULL;
    cetrafs_dirent_t *slot = NULL;
    time64_t now;
    u64 new_lba = 0;
    u64 slot_lba = 0;
    unsigned int slot_idx = 0;
    bool have_slot = false;
    bool new_block = false;
    bool fresh;
    int ret;

    /* An earlier step of this same operation may already have updated
     * this record and staged it for the lock release (a rename whose
     * source and destination are the same directory). The staged image
     * is the current one; the device still holds the pre-operation
     * record, by design. */
    if (!cetrafs_inode_peek_staged_record(dir, &raw)) {
        cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
        ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);
        if (ret)
            return ret;
    }

    fs_debug(info, "dir_add_entry: dir ino=%llu name='%.*s' new_ino=%llu eh_entries=%u",
             (unsigned long long) dir->i_ino, (int) name->len, name->name, (unsigned long long) ino, raw.eh.eh_entries);
    ctrace("ADDREC dir=%llu eh=%u depth=%u seq=%llu size=%llu staged=%d\n",
            (unsigned long long) dir->i_ino, (unsigned int) cetrafs_le16(raw.eh.eh_entries),
            (unsigned int) cetrafs_le16(raw.eh.eh_depth), (unsigned long long) cetrafs_le64(raw.dirent_seq),
            (unsigned long long) cetrafs_le64(raw.size), 0);

    /* Is this directory still THERE? A peer may have rmdir'd it since
     * this node resolved the path, and nothing local would know: the
     * VFS marks a locally-removed directory dead (IS_DEADDIR) and
     * refuses to create in it, but a removal performed on another node
     * leaves this node's in-core inode looking perfectly healthy.
     *
     * Publishing a name into it is not a stale read -- the record above
     * was read forced-fresh and is accurate. It is a write into a
     * directory that no longer exists: the new entry is reachable from
     * nothing, and fsck reports the whole subtree as detached. A
     * two-node run renamed a file into a directory a peer removed
     * concurrently and the file ended up at neither path (ctest
     * hypervisor-storm, hostile case 3).
     *
     * nlink is the marker: rmdir zeroes it, and a live directory always
     * has >= 2 ('.' and its parent's entry). mkdir writes nlink=2 into
     * the new record BEFORE the parent is ever named, so a directory
     * being born never reads as dead here. The generation check is the
     * companion for the other direction -- the number recycled into a
     * DIFFERENT object since we resolved it. */
    if (cetrafs_le32(raw.nlink) == 0 || cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(dir)) {
        pr_warn_ratelimited("refusing to add '%.*s' to dir ino=%llu: it is gone (nlink=%u, generation disk=%llu core=%llu) -- a peer removed or replaced it\n",
                            (int) name->len, name->name, (unsigned long long) dir->i_ino,
                            (unsigned int) cetrafs_le32(raw.nlink),
                            (unsigned long long) cetrafs_le64(raw.generation),
                            (unsigned long long) cetrafs_inode_get_generation(dir));
        return -ENOENT; /* before cetrafs_dir_extents_get(): nothing to release yet */
    }

    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret)
        return ret;

    /* The cache may decide; it may not be written back. See
     * cetrafs_dir_needs_fresh(). */
    fresh = cetrafs_dir_needs_fresh(dir, &raw);

    for (;;) {
        ret = cetrafs_dir_scan_for_slot(dir, &dx, name, fresh, &slot_lba, &slot_idx, &have_slot);
        if (ret) {
            cetrafs_dir_extents_put(&dx);
            return ret;
        }
        if (!have_slot)
            break; /* directory full -- grow it below */

        /* The one block about to be modified, read forced-fresh
         * regardless of how the decision was reached. Everything written
         * below goes into THIS image, so no cached copy can be published
         * even if the decision above came from one. */
        bh = cetrafs_dirent_read(dir->i_sb, slot_lba, /*fresh=*/true);
        if (!bh) {
            pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during add\n",
                                (unsigned long long) dir->i_ino, (unsigned long long) slot_lba);
            cetrafs_dir_extents_put(&dx);
            return -EIO;
        }
        if (cetrafs_dirent_slot_free(bh, slot_idx) && !cetrafs_dirent_block_has_name(bh, name))
            break; /* the decision still holds against the fresh image */

        brelse(bh);
        bh = NULL;
        if (fresh) {
            /* The scan read this very block from the device moments ago,
             * under this directory's namespace lock, which excludes every
             * peer and every local thread. Disagreeing with itself means
             * something is writing this directory without that lock. */
            pr_warn_ratelimited("dir ino=%llu: dirent block %llu changed under the namespace lock\n",
                                (unsigned long long) dir->i_ino, (unsigned long long) slot_lba);
            cetrafs_dir_extents_put(&dx);
            return -EIO;
        }
        fresh = true; /* cached decision was stale -- redo it honestly */
    }

    /*
     * No free slot anywhere: grow the directory by one block, through
     * the same extent machinery a regular file grows by. That merges
     * the new block into the preceding extent when it lands contiguously
     * and spills past 4 extents into an external leaf block, instead of
     * the old "one new inline extent per block, hard stop at 4" that
     * capped every directory at 60 dirents.
     */
    if (!have_slot) {
        u32 next_logical = (u32) cetrafs_dir_extents_nblocks(&dx);

        cetrafs_dir_extents_put(&dx);

        ret = cetrafs_inode_map_block(dir, next_logical, /*create=*/true, &new_lba);
        if (ret)
            return ret;
        new_block = true;

        /*
         * cetrafs_inode_map_block() rewrote this directory's record, so
         * the copy read at the top of this function is now stale -- the
         * metadata update at the bottom would write the extent list back
         * without the block just added. Re-read it.
         */
        cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
        ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);
        if (ret)
            return ret;

        /*
         * cetrafs_get_block() already zeroed and stamped this block,
         * synchronously, BEFORE committing the extent that makes it
         * reachable (see cetrafs_dirent_block_init()). So it is a valid
         * empty dirent block already and simply needs the new entry
         * written into it. If that write then fails, the directory is
         * still perfectly readable -- one unused block -- and freeing
         * the block is not an option any more, since the extent
         * referencing it is committed.
         */
        bh = sb_bread(dir->i_sb, new_lba);
        if (!bh) {
            pr_warn_ratelimited("dir ino=%llu: new dirent block %llu unreadable\n", (unsigned long long) dir->i_ino,
                                (unsigned long long) new_lba);
            return -EIO;
        }
        slot = (cetrafs_dirent_t *) bh->b_data;
    } else {
        cetrafs_dir_extents_put(&dx);
        slot = &((cetrafs_dirent_t *) bh->b_data)[slot_idx];
    }

    /* write the new dirent */
    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
    slot->inode = cetrafs_cpu_to_le64(ino);
    slot->name_len = cetrafs_cpu_to_le16((u16) name->len);
    slot->file_type = file_type;
    memset(slot->name, 0, CETRAFS_FILENAME_MAX);
    memcpy(slot->name, name->name, name->len);

    fs_debug(info, "dir_add_entry: writing '%.*s' -> ino=%llu at block lba=%llu%s", (int) name->len, name->name,
             (unsigned long long) ino, (unsigned long long) bh->b_blocknr, new_block ? " (new block)" : "");
    ctrace("ADDNAME dir=%llu name='%.*s' ino=%llu lba=%llu%s\n",
            (unsigned long long) dir->i_ino, (int) name->len, name->name, (unsigned long long) ino,
            (unsigned long long) bh->b_blocknr, new_block ? " NEWBLOCK" : "");

    /* Journal + write + sync + consume, in write-ahead order --
     * journal.c's cetrafs_journal_write_block() owns the whole sequence
     * so no call site can reorder it. */
    cetrafs_dirent_block_stamp(bh);
    ret = cetrafs_journal_write_block(dir->i_sb, bh, prev_crc);
    brelse(bh);
    if (ret)
        return ret; /* a grown block stays as a valid empty one -- see above */

    /* update dir's own metadata */
    now = ktime_get_real_seconds();
    raw.size = cetrafs_cpu_to_le64(cetrafs_le64(raw.size) + (sizeof(cetrafs_dirent_t)));
    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb)); /* this directory's blocks just changed -- see cetrafs_dirent_read() */
    raw.mtime = cetrafs_cpu_to_le64((u64) now);
    raw.ctime = cetrafs_cpu_to_le64((u64) now);
    if (file_type == CETRAFS_FT_DIR)
        raw.nlink = cetrafs_cpu_to_le32(cetrafs_le32(raw.nlink) + 1);

    /* Staged rather than written: the namespace lock's release is a
     * compare-and-swap of this very record, so it can publish these
     * fields in the swap it was going to make anyway -- one device
     * round trip instead of two. See cetrafs_inode_stage_record(). */
    cetrafs_inode_stage_record(dir, &raw, /*fd_too=*/true);

    /* Our own mutation, and this pass IS entitled to claim the cache --
     * for the reason the claim rule actually requires, which is that
     * every block's cached image is current, not that every block was
     * re-read. It has to visit them all (a duplicate name could be
     * anywhere), and either the seq matched, in which case the cached
     * copies were already current, or it read them all fresh. The one
     * block it modified it re-read fresh and wrote through that same
     * cache. A pass that stops EARLY cannot say any of this about what
     * lies past its stopping point; see cetrafs_dir_remove_entry(). */
    cetrafs_inode_set_dirent_seq_cached(dir, cetrafs_le64(raw.dirent_seq));

    i_size_write(dir, cetrafs_le64(raw.size));
    inode_set_mtime(dir, now, 0);
    inode_set_ctime(dir, now, 0);
    if (file_type == CETRAFS_FT_DIR)
        set_nlink(dir, dir->i_nlink + 1);

    return 0;
}

/*
 * Find the dirent matching 'name' in 'dir' (scanning its existing inline,
 * depth-0 extents' data blocks), zero it out, and update dir's on-disk and
 * in-core size/mtime/ctime (and nlink, if the removed entry was itself a
 * directory -- the counterpart to cetrafs_dir_add_entry()'s bump). On
 * success, stores the removed entry's inode number and file type in
 * out_ino/out_file_type. Returns 0, or a negative errno (-ENOENT if no
 * dirent matches).
 */
int cetrafs_dir_remove_entry(struct inode *dir, const struct qstr *name, u64 *out_ino, u8 *out_file_type)
{
    unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    struct buffer_head *bh = NULL;
    cetrafs_dirent_t *slot = NULL;
    time64_t now;
    bool fresh;
    int ret, i;

    /* The staged image if this operation already updated this record --
     * see cetrafs_dir_add_entry(). */
    if (!cetrafs_inode_peek_staged_record(dir, &raw)) {
        cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
        ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);
        if (ret)
            return ret;
    }

    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret)
        return ret;

    fresh = true; /* see cetrafs_dir_needs_fresh(): writers never use the cache */

    for (i = 0; i < dx.entries && !slot; i++) {
        const cetrafs_extent_t *ext = &dx.arr[i];
        u64 phys = cetrafs_extent_phys_from_hilo(ext->ee_start_hi, ext->ee_start_lo);
        u32 len = cetrafs_extent_len(ext->ee_len);
        u32 b;

        for (b = 0; b < len && !slot; b++) {
            cetrafs_dirent_t *de;
            unsigned int e;

            bh = cetrafs_dirent_read(dir->i_sb, phys + b, fresh);
            if (!bh) {
                pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during remove\n",
                                    (unsigned long long) dir->i_ino, (unsigned long long) (phys + b));
                cetrafs_dir_extents_put(&dx);
                return -EIO;
            }

            de = (cetrafs_dirent_t *) bh->b_data;
            for (e = 0; e < dirents_per_block; e++) {
                if (cetrafs_le64(de[e].inode) != 0 && cetrafs_le16(de[e].name_len) == name->len &&
                    !memcmp(de[e].name, name->name, cetrafs_le16(de[e].name_len))) {
                    slot = &de[e];
                    break;
                }
            }
            if (!slot)
                brelse(bh);
        }
    }

    cetrafs_dir_extents_put(&dx);

    if (!slot)
        return -ENOENT;

    *out_ino = cetrafs_le64(slot->inode);
    *out_file_type = slot->file_type;
    ctrace("REMNAME dir=%llu name='%.*s' ino=%llu\n",
            (unsigned long long) dir->i_ino, (int) name->len, name->name, (unsigned long long) *out_ino);
    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
    memset(slot, 0, sizeof(*slot));

    cetrafs_dirent_block_stamp(bh);
    ret = cetrafs_journal_write_block(dir->i_sb, bh, prev_crc);
    brelse(bh);
    if (ret)
        return ret;

    now = ktime_get_real_seconds();
    raw.size = cetrafs_cpu_to_le64(cetrafs_le64(raw.size) - (sizeof(cetrafs_dirent_t)));
    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb)); /* this directory's blocks just changed -- see cetrafs_dirent_read() */
    raw.mtime = cetrafs_cpu_to_le64((u64) now);
    raw.ctime = cetrafs_cpu_to_le64((u64) now);
    if (*out_file_type == CETRAFS_FT_DIR)
        raw.nlink = cetrafs_cpu_to_le32(cetrafs_le32(raw.nlink) - 1);

    /* Staged for the namespace lock's release -- see
     * cetrafs_dir_add_entry(). */
    cetrafs_inode_stage_record(dir, &raw, /*fd_too=*/true);

    /*
     * Deliberately NOT claiming the dirent cache here.
     *
     * The scan above stops at the entry it came to remove, so every block
     * past that one is whatever this node last had -- which may predate a
     * peer's mutation. Claiming would assert the whole directory is
     * cached and current at the new sequence, and every subsequent
     * read-only walk would then trust those unrefreshed blocks: entries a
     * peer deleted keep being listed, entries it added stay invisible,
     * and nothing corrects it until something bumps the sequence again.
     *
     * Leaving the cached sequence at its old value is exactly right -- it
     * no longer matches the record's new dirent_seq, so the next walk
     * reads fresh. One extra pass over a directory that was just
     * modified, in exchange for not asserting something this function
     * never checked.
     */

    i_size_write(dir, cetrafs_le64(raw.size));
    inode_set_mtime(dir, now, 0);
    inode_set_ctime(dir, now, 0);
    if (*out_file_type == CETRAFS_FT_DIR)
        set_nlink(dir, dir->i_nlink - 1);

    return 0;
}

/*
 * Rewrite a directory's '..' dirent to point at a new parent inode number
 * -- used by rename() when a directory moves to a different parent.
 */
int cetrafs_dir_update_dotdot(struct inode *dir, u64 new_parent_ino)
{
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    int ret, i;

    cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);
    if (ret)
        return ret;

    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret)
        return ret;

    for (i = 0; i < dx.entries; i++) {
        const cetrafs_extent_t *ext = &dx.arr[i];
        u64 phys = cetrafs_extent_phys_from_hilo(ext->ee_start_hi, ext->ee_start_lo);
        u32 len = cetrafs_extent_len(ext->ee_len);
        unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
        u32 b;

        for (b = 0; b < len; b++) {
            struct buffer_head *bh = cetrafs_dirent_bread(dir->i_sb, phys + b);
            cetrafs_dirent_t *de;
            unsigned int e;

            if (!bh) {
                cetrafs_dir_extents_put(&dx);
                return -EIO;
            }

            de = (cetrafs_dirent_t *) bh->b_data;
            for (e = 0; e < dirents_per_block; e++) {
                if (cetrafs_le64(de[e].inode) != 0 && cetrafs_le16(de[e].name_len) == 2 && de[e].name[0] == '.' && de[e].name[1] == '.') {
                    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
                    de[e].inode = cetrafs_cpu_to_le64(new_parent_ino);
                    cetrafs_dirent_block_stamp(bh);
                    ret = cetrafs_journal_write_block(dir->i_sb, bh, prev_crc);
                    brelse(bh);
                    cetrafs_dir_extents_put(&dx);
                    if (ret)
                        return ret;

                    /* This rewrote a dirent block, so the sequence has
                     * to move even though no entry was added or removed
                     * -- otherwise a peer whose cached seq still matches
                     * would go on serving the old '..' from its cache. */
                    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb));
                    ret = cetrafs_write_raw_inode(dir->i_sb, dir->i_ino, &raw, /*sync=*/true);
                    if (ret)
                        return ret;
                    /* No cache claim: this walk stopped at '..' in the
                     * first block and never looked at the rest, so it
                     * cannot vouch for them. See
                     * cetrafs_dir_remove_entry(). */
                    return 0;
                }
            }
            brelse(bh);
        }
    }

    cetrafs_dir_extents_put(&dx);
    return -EIO; /* a real directory always has '..' */
}

struct cetrafs_lookup_ctx {
    const struct qstr *name;
    u64 ino;
};

/*
 * Point an existing entry at a different inode, in place.
 *
 * This is what makes a REPLACING rename atomic for everyone else. POSIX
 * requires that "the link named by new shall remain visible to other
 * processes throughout the renaming operation", and the replace path
 * used to remove the target's entry and then add the source's under the
 * same name -- two synchronous dirent writes with a real window between
 * them where the name does not exist at all. On one node the VFS hides
 * that behind the directory's inode lock; on a shared LUN a peer
 * looking the name up in that window gets ENOENT, which breaks the
 * write-a-temp-then-rename-over idiom that rename exists to support.
 * It also left a failure between the two able to destroy the target
 * while leaving the source in place.
 *
 * One dirent write instead of two, and the parent's nlink is
 * deliberately untouched: a replace swaps one entry for another of the
 * same type (the VFS has already refused a directory/non-directory
 * mismatch), so the directory's subdirectory count cannot change.
 */
static int cetrafs_dir_retarget_entry(struct inode *dir,
                                      const struct qstr *name,
                                      u64 new_ino,
                                      u8 new_file_type,
                                      u64 *out_old_ino,
                                      u8 *out_old_file_type)
{
    unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    struct buffer_head *bh = NULL;
    cetrafs_dirent_t *slot = NULL;
    time64_t now;
    int ret, i;

    cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);
    if (!ret)
        ctrace("RETREAD ino=%llu size_read=%llu\n", (unsigned long long) dir->i_ino,
                (unsigned long long) cetrafs_le64(raw.size));
    if (ret)
        return ret;

    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret)
        return ret;

    for (i = 0; i < dx.entries && !slot; i++) {
        const cetrafs_extent_t *ext = &dx.arr[i];
        u64 phys = cetrafs_extent_phys_from_hilo(ext->ee_start_hi, ext->ee_start_lo);
        u32 len = cetrafs_extent_len(ext->ee_len);
        u32 b;

        for (b = 0; b < len && !slot; b++) {
            cetrafs_dirent_t *de;
            unsigned int e;

            /* A writer never uses the dirent cache -- see
             * cetrafs_dir_needs_fresh(). */
            bh = cetrafs_dirent_read(dir->i_sb, phys + b, true);
            if (!bh) {
                pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during retarget\n",
                                    (unsigned long long) dir->i_ino, (unsigned long long) (phys + b));
                cetrafs_dir_extents_put(&dx);
                return -EIO;
            }

            de = (cetrafs_dirent_t *) bh->b_data;
            for (e = 0; e < dirents_per_block; e++) {
                if (cetrafs_le64(de[e].inode) != 0 && cetrafs_le16(de[e].name_len) == name->len &&
                    !memcmp(de[e].name, name->name, cetrafs_le16(de[e].name_len))) {
                    slot = &de[e];
                    break;
                }
            }
            if (!slot)
                brelse(bh);
        }
    }

    cetrafs_dir_extents_put(&dx);

    if (!slot)
        return -ENOENT;

    *out_old_ino = cetrafs_le64(slot->inode);
    *out_old_file_type = slot->file_type;

    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
    slot->inode = cetrafs_cpu_to_le64(new_ino);
    slot->file_type = new_file_type;
    cetrafs_dirent_block_stamp(bh);
    ret = cetrafs_journal_write_block(dir->i_sb, bh, prev_crc);
    brelse(bh);
    if (ret)
        return ret;

    now = ktime_get_real_seconds();
    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb)); /* this directory's blocks just changed */
    raw.mtime = cetrafs_cpu_to_le64((u64) now);
    raw.ctime = cetrafs_cpu_to_le64((u64) now);
    /* size and nlink unchanged: one entry became a different entry. */

    ctrace("RETGT dir=%llu name='%.*s' new_ino=%llu removed_ino=%llu\n",
            (unsigned long long) dir->i_ino, (int) name->len, name->name,
            (unsigned long long) new_ino, (unsigned long long) *out_old_ino);
    ret = cetrafs_write_raw_inode(dir->i_sb, dir->i_ino, &raw, /*sync=*/true);
    if (ret)
        return ret;

    /* Not claiming the dirent cache, for the same reason
     * cetrafs_dir_remove_entry() does not: the scan stopped at the
     * entry it came for, so the blocks past it were never refreshed. */
    inode_set_mtime(dir, now, 0);
    inode_set_ctime(dir, now, 0);
    return 0;
}

/*
 * The dirent file_type for an inode, derived from its mode.
 *
 * readdir hands this to userspace as d_type, and a great deal of
 * tooling trusts d_type instead of calling stat: `find -type l`, fts,
 * rsync and tar among them. Two sites used to hardcode it --
 * cetrafs_link_locked() always wrote CETRAFS_FT_REG, and
 * cetrafs_rename_locked() derived only DIR-or-REG -- so **hardlinking
 * or renaming a SYMLINK silently retyped its directory entry to a
 * regular file**. Measured against tmpfs: `find -type l` found the
 * original symlink and missed both its hardlink and its renamed self.
 *
 * Every type the format defines is covered, not just the three this
 * module can create, so that adding mknod later cannot reintroduce the
 * same class of bug one case at a time.
 */
static u8 cetrafs_dirent_type(const struct inode *inode)
{
    if (S_ISDIR(inode->i_mode))
        return CETRAFS_FT_DIR;
    if (S_ISLNK(inode->i_mode))
        return CETRAFS_FT_LNK;
    if (S_ISCHR(inode->i_mode))
        return CETRAFS_FT_CHR;
    if (S_ISBLK(inode->i_mode))
        return CETRAFS_FT_BLK;
    if (S_ISFIFO(inode->i_mode))
        return CETRAFS_FT_FIFO;
    if (S_ISSOCK(inode->i_mode))
        return CETRAFS_FT_SOCK;
    return CETRAFS_FT_REG;
}

static int cetrafs_lookup_visit(void *priv, const cetrafs_dirent_t *de, loff_t pos)
{
    struct cetrafs_lookup_ctx *ctx = priv;

    (void) pos;

    if (cetrafs_le16(de->name_len) == ctx->name->len && !memcmp(de->name, ctx->name->name, cetrafs_le16(de->name_len))) {
        ctx->ino = cetrafs_le64(de->inode);
        return 1; /* stop: found */
    }
    return 0;
}

/*
 * Real lookup: scans the directory's on-disk dirents for a matching name.
 */
static struct dentry *cetrafs_lookup(struct inode *dir, struct dentry *dentry, unsigned int flags)
{
    struct cetrafs_lookup_ctx ctx = {.name = &dentry->d_name, .ino = 0};
    struct inode *inode = NULL;
    int ret;

    fs_debug(info, "lookup '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    if (dentry->d_name.len > CETRAFS_FILENAME_MAX)
        return ERR_PTR(-ENAMETOOLONG);

    ret = cetrafs_walk_dirents(dir, cetrafs_lookup_visit, &ctx);
    if (ret)
        return ERR_PTR(ret);

    if (ctx.ino) {
        inode = cetrafs_iget(dir->i_sb, ctx.ino);
        if (IS_ERR(inode))
            return ERR_CAST(inode);
    }

    return d_splice_alias(inode, dentry);
}

/*
 * The dcache is local and in-memory, so only a fresh disk read can ever
 * notice what another node did. The two halves need opposite treatment.
 *
 * NEGATIVE dentries are revalidated unconditionally. There is no inode
 * and no page cache at risk, so a forced cetrafs_lookup() (already an
 * uncached dirent read, see ioutil.c) costs one round trip. Without it a
 * node that lost a create() race cached the ENOENT from its own earlier
 * lookup and served it forever, long after the peer's create succeeded:
 * readdir() listed the name while stat() on it kept failing, because the
 * path walk never reached cetrafs_lookup() again.
 *
 * POSITIVE dentries must NOT simply be invalidated. Doing so makes the
 * VFS evict the in-core inode far more often, including while this
 * node's own dirty pages for that file are still unwritten -- silently
 * losing them. They need two independent checks instead:
 *
 *  1. Does 'name' still resolve to this same inode in 'dir' on the
 *     device? A peer's unlink/rmdir/rename-away removes the dirent but
 *     says nothing about the inode's fields, so a stat refresh alone
 *     never notices it. Re-running cetrafs_walk_dirents() answers it: if
 *     the name is gone or now maps to a different inode, return 0 and
 *     let the VFS redo the lookup.
 *
 *  2. If it still maps here, refresh the cached stat fields via
 *     cetrafs_refresh_vfs_inode_if_newer() (inode.c). That is gated on
 *     this node not holding the write lock, NOT on an mtime comparison
 *     -- chmod, truncate and hardlink do not reliably bump mtime here.
 */
static int cetrafs_d_revalidate(struct inode *dir, const struct qstr *name, struct dentry *dentry, unsigned int flags)
{
    if (flags & LOOKUP_RCU)
        return -ECHILD; /* can't block in RCU-walk mode; make the VFS retry in ref-walk mode instead */

    if (d_really_is_positive(dentry)) {
        struct cetrafs_lookup_ctx ctx = {.name = name, .ino = 0};
        struct inode *inode = d_inode(dentry);
        int ret;

        ret = cetrafs_walk_dirents(dir, cetrafs_lookup_visit, &ctx);
        if (ret || ctx.ino != inode->i_ino)
            return 0; /* removed, renamed away, or replaced -- force a fresh lookup */

        /* ANY failure to refresh invalidates the dentry. It used to be
         * only -ESTALE (same inode NUMBER, different FILE: a peer
         * deleted this one and reused its number, or -- since N2 --
         * deleted it outright). The others were treated as "still
         * valid", which is the wrong way round: -EUCLEAN is the refusal
         * to apply a record whose type changed, and -EIO is a device
         * error, and in both cases the right answer is to make the VFS
         * look the name up again rather than to assert that a stale
         * in-core object is current. The retry re-reads and either
         * succeeds or reports the error properly.
         *
         * Note the refresh returns 0, not an error, when it declines
         * for an ordinary reason (this node holds the write lock, or
         * the inode has unwritten local changes) -- so this does not
         * churn dentries for dirty inodes. */
        if (cetrafs_refresh_vfs_inode_if_newer(inode) != 0)
            return 0;
        return 1;
    }

    return 0; /* negative dentry: never trust it -- always force a fresh lookup */
}

const struct dentry_operations cetrafs_dentry_ops = {
    .d_revalidate = cetrafs_d_revalidate,
};

struct cetrafs_readdir_ctx {
    struct dir_context *dctx;
};

static int cetrafs_readdir_visit(void *priv, const cetrafs_dirent_t *de, loff_t pos)
{
    struct cetrafs_readdir_ctx *ctx = priv;
    unsigned int type;

    if (pos < ctx->dctx->pos)
        return 0; /* already emitted in an earlier call */

    switch (de->file_type) {
    case CETRAFS_FT_DIR:
        type = DT_DIR;
        break;
    case CETRAFS_FT_LNK:
        type = DT_LNK;
        break;
    case CETRAFS_FT_CHR:
        type = DT_CHR;
        break;
    case CETRAFS_FT_BLK:
        type = DT_BLK;
        break;
    case CETRAFS_FT_FIFO:
        type = DT_FIFO;
        break;
    case CETRAFS_FT_SOCK:
        type = DT_SOCK;
        break;
    default:
        type = DT_REG;
        break;
    }

    /* dir_emit() reads ctx->pos itself to hand to the actor, so it must be
     * set to this entry's own position before calling it. */
    ctx->dctx->pos = pos;
    if (!dir_emit(ctx->dctx, de->name, cetrafs_le16(de->name_len), cetrafs_le64(de->inode), type))
        return 1; /* stop: caller's buffer is full, resume here next time */

    ctx->dctx->pos = pos + sizeof(cetrafs_dirent_t);
    return 0;
}

/*
 * Real readdir: emits the on-disk dirents directly (our directory blocks
 * already contain real '.' and '..' entries, so no synthetic dir_emit_dots()
 * is needed).
 */
static int cetrafs_readdir(struct file *file, struct dir_context *dctx)
{
    struct cetrafs_readdir_ctx ctx = {.dctx = dctx};

    return cetrafs_walk_dirents(file_inode(file), cetrafs_readdir_visit, &ctx);
}

/*
 * Create a regular file: allocate an inode, write its initial (empty)
 * record, add a dirent for it in 'dir'. rmdir lands in a later, dedicated
 * change.
 */
/*
 * Owner and mode for a newly created inode, computed the way the VFS's
 * own inode_init_owner() computes them.
 *
 * The three creation paths used to take from_kuid(&init_user_ns,
 * current_fsuid()) and the matching fsgid directly, which gets two
 * things wrong.
 *
 * A setgid DIRECTORY must pass its group on to everything created
 * inside it, and a new SUBDIRECTORY must inherit the setgid bit itself
 * or the inheritance stops one level down. That is the standard way a
 * shared, group-writable tree is set up -- which is exactly how a
 * datastore of VM images gets shared between a host's service accounts.
 * Measured against tmpfs: a file created in a `chmod g+s` directory came
 * out with the creator's gid instead of the directory's, and a
 * subdirectory came out 755 instead of 2755.
 *
 * And the mnt_idmap argument was accepted and ignored, so on an
 * idmapped mount -- a container's view of the filesystem, the normal
 * case under Proxmox -- new files were stamped with the raw caller's
 * ids rather than the mapped ones.
 *
 * On-disk ids are init_user_ns values, matching what
 * cetrafs_write_vfs_inode() writes and what i_uid_write() reads back.
 */
static void cetrafs_init_owner(struct mnt_idmap *idmap, const struct inode *dir, umode_t *mode, u32 *uid, u32 *gid)
{
    kuid_t kuid = mapped_fsuid(idmap, i_user_ns(dir));
    kgid_t kgid;

    if (dir->i_mode & S_ISGID) {
        kgid = dir->i_gid;
        if (S_ISDIR(*mode))
            *mode |= S_ISGID;
    } else {
        kgid = mapped_fsgid(idmap, i_user_ns(dir));
    }

    *uid = from_kuid(&init_user_ns, kuid);
    *gid = from_kgid(&init_user_ns, kgid);
}

/*
 * Throw away a half-built, still-unnamed inode (create/mkdir/symlink
 * unwind paths, once cetrafs_iget() has produced the in-core object).
 *
 * These paths used to call cetrafs_free_inode() and then iput(). That
 * is wrong twice over: the inode may by then own DATA BLOCKS (mkdir's
 * '.'/'..' block, a symlink's target text, an xattr block a partially-
 * failed cetrafs_init_security() allocated), which nothing freed, and
 * eviction only frees an inode's blocks when its link count has reached
 * zero -- which it had not, because the record was stamped nlink >= 1.
 * So the blocks leaked AND the inode number went back to the allocator
 * while a record describing a live file still named them, which is
 * precisely how the eviction fix describes a leak becoming
 * untraceable: the next file to reuse the number overwrites the only
 * evidence.
 *
 * Dropping the link count and letting eviction do the work frees the
 * blocks (the xattr block included -- see super_ops.c) and the number
 * together, through the one path that knows how.
 */
static void cetrafs_new_inode_discard(struct inode *inode)
{
    ctrace("DISCARD ino=%llu\n", (unsigned long long) inode->i_ino);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;

    /*
     * The on-disk record still says nlink=1 -- creation wrote it before
     * the name was published, and publishing is what failed. Clearing
     * only the in-core count leaves the DEVICE claiming a name that
     * does not exist, which is the exact shape fsck reports as
     * "allocated but NO directory entry names it". (It also leaves that
     * orphan behind if this node dies here.)
     *
     * Make the record say what is true before eviction looks at it:
     * no names. cetrafs_evict_inode() now refuses to free an inode a
     * peer still names, and reads the DEVICE to decide -- so a record
     * left lying here would make the discard leak the inode and its
     * blocks rather than free them.
     */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    if (cetrafs_read_raw_inode(sb, inode->i_ino, &raw) == 0 &&
        cetrafs_le64(raw.generation) == cetrafs_inode_get_generation(inode) &&
        cetrafs_le32(raw.nlink) != 0) {
        raw.nlink = 0;
        (void) cetrafs_write_raw_inode(sb, inode->i_ino, &raw, /*sync=*/true);
    }

    clear_nlink(inode);
    iput(inode);
}

/*
 * Shared tail of create/mkdir/symlink: everything between "the child's
 * record is on disk" and "the name exists". The order is the point.
 *
 * The LSM stamps the child (security.*) and only THEN is the name added
 * to the parent. Until that dirent lands the child is unreachable -- its
 * inode number was claimed by an atomic CAS and no name points at it --
 * so cetrafs_initxattrs()'s lock-free writes of the child's record race
 * nobody (xattr.c's comment rests on exactly this). These steps used to
 * run the other way around, name first: from that instant a peer could
 * resolve the name and take the child's NAMESPACE LOCK for a
 * setxattr/chmod while init_security mutated the same record under no
 * lock at all -- a lost update (a clobbered xattr_block pointer, a
 * vanished chmod) -- and there was a window where the file was visible
 * with no security label, which an enforcing LSM answers wrongly in
 * whichever direction its policy defaults.
 *
 * On failure the name does not yet exist: the caller unwinds the child
 * alone (cetrafs_new_inode_discard() above), the parent is untouched,
 * and there is no dirent to remove.
 */
static int cetrafs_create_publish(struct inode *dir, struct dentry *dentry, struct inode *inode)
{
    int ret = cetrafs_init_security(inode, dir, &dentry->d_name);

    if (ret)
        return ret;

    ret = cetrafs_dir_add_entry(dir, &dentry->d_name, inode->i_ino, cetrafs_dirent_type(inode));
    if (ret)
        return ret;

    /* Unlike .lookup, the dentry here was already hashed negative by the
     * preceding lookup call, so d_splice_alias() (which asserts unhashed)
     * would BUG_ON -- d_instantiate() is the correct call for
     * .create/.mkdir/.symlink. */
    d_instantiate(dentry, inode);
    /* Named: the record is written and a dirent proves the ownership,
     * so the number is scrub-judgeable again. */
    cetrafs_sb_birth_end(dir->i_sb, inode->i_ino);
    return 0;
}

static int cetrafs_create_locked(struct mnt_idmap *idmap,
                                 struct inode *dir,
                                 struct dentry *dentry,
                                 umode_t mode,
                                 bool excl)
{
    struct super_block *sb = dir->i_sb;
    struct inode *inode;
    cetrafs_inode_t raw;
    u64 ino;
    time64_t now;
    int ret;

    fs_debug(info, "create '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    ret = cetrafs_alloc_inode(sb, &ino);
    if (ret)
        return ret;

    now = ktime_get_real_seconds();
    memset(&raw, 0, sizeof(raw));
    raw.ino = cetrafs_cpu_to_le64(ino);
    {
        umode_t m = S_IFREG | (mode & 07777);

        {
        u32 _u, _g;
        cetrafs_init_owner(idmap, dir, &m, &_u, &_g);
        raw.uid = cetrafs_cpu_to_le32(_u);
        raw.gid = cetrafs_cpu_to_le32(_g);
    }
        raw.mode = cetrafs_cpu_to_le32(m);
    }
    raw.nlink = cetrafs_cpu_to_le32(1);
    raw.ctime = raw.mtime = raw.atime = cetrafs_cpu_to_le64((u64) now);
    raw.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    raw.generation = cetrafs_cpu_to_le64(cetrafs_inode_new_generation(sb)); /* v0x0008 reuse detector */
    raw.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);          /* v0x000A: 0 is a real node id, so be explicit */
    raw.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    raw.eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw.et.leaf));
    /* eh_entries = 0, eh_depth = 0: a fresh file has no data blocks yet */

    /* See inode.c's cetrafs_write_raw_inode() comment: a freshly
     * allocated inode's first write must force a fresh read of its home
     * block itself, since a peer could have allocated an adjacent inode
     * number landing in the same shared block moments ago. */
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_write_raw_inode(sb, ino, &raw, /*sync=*/true);
    if (ret) {
        cetrafs_free_inode(sb, ino);
        return ret;
    }
    {
        bool still = false;

        /* Mid-birth theft check -- see cetrafs_alloc_inode_still_owned().
         * On theft nothing here owns the number any more: do NOT free it
         * (that would clobber the thief's arbitration); fail loudly. */
        if (cetrafs_alloc_inode_still_owned(sb, ino, &still) != 0 || !still) {
            pr_err("create: ino=%llu was freed out from under its own birth (a peer scrub's stale verdict?) -- refusing\n",
                   (unsigned long long) ino);
            cetrafs_sb_birth_end(sb, ino);
            return -EIO;
        }
    }

    /* Instantiate, label, and only then name it -- see
     * cetrafs_create_publish(). Nothing on these failure paths removes a
     * dirent, because none exists yet. */
    inode = cetrafs_iget(sb, ino);
    if (IS_ERR(inode)) {
        cetrafs_free_inode(sb, ino);
        return PTR_ERR(inode);
    }

    ret = cetrafs_create_publish(dir, dentry, inode);
    if (ret) {
        cetrafs_new_inode_discard(inode);
        return ret;
    }
    return 0;
}

/*
 * Report a failed namespace mutation. These used to fail completely
 * silently: a real two-node run saw ~0.7% of creates return EIO with
 * nothing whatsoever in dmesg to say which step failed, which cost a
 * full instrument-rebuild-rerun cycle to localise. Error path only, so
 * it costs nothing when things work, and rate-limited so a storm of
 * them can't flood the log.
 */
static void cetrafs_ns_report(const char *op, struct inode *dir, const struct qstr *name, int ret)
{
    if (!ret || ret == -ENOENT || ret == -EEXIST || ret == -ENOTEMPTY || ret == -ENOTDIR || ret == -EISDIR)
        return; /* ordinary, expected answers -- not failures */
    pr_warn_ratelimited("%s '%.*s' in dir ino=%llu failed: %d\n", op, name ? (int) name->len : 0,
                        name ? (const char *) name->name : "", (unsigned long long) dir->i_ino, ret);
}

static int cetrafs_create(struct mnt_idmap *idmap, struct inode *dir, struct dentry *dentry, umode_t mode, bool excl)
{
    /* Only the parent: the child's record is freshly allocated, and its
     * inode-bitmap bit was claimed by an atomic CAS, so no other node
     * can be looking at it yet. */
    struct inode *set[] = {dir};
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret) {
        cetrafs_ns_report("create (lock)", dir, &dentry->d_name, ret);
        return ret;
    }

    ret = cetrafs_create_locked(idmap, dir, dentry, mode, excl);
    cetrafs_ns_report("create", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/*
 * Create a subdirectory: allocate an inode and a single data block holding
 * '.'/'..', write the inode record with one inline extent pointing at that
 * block, then add a dirent for it in 'dir' (which also bumps dir's nlink,
 * via cetrafs_dir_add_entry()). rmdir lands in a later, dedicated change.
 */
static struct dentry *cetrafs_mkdir_locked(struct mnt_idmap *idmap,
                                           struct inode *dir,
                                           struct dentry *dentry,
                                           umode_t mode)
{
    struct super_block *sb = dir->i_sb;
    struct inode *inode;
    cetrafs_inode_t raw;
    cetrafs_dirent_t *dirblk;
    struct buffer_head *bh;
    u64 ino, lba;
    u32 bg_id;
    time64_t now;
    int ret;

    fs_debug(info, "mkdir '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    ret = cetrafs_alloc_inode(sb, &ino);
    if (ret)
        return ERR_PTR(ret);
    fs_debug(info, "mkdir '%.*s': allocated ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) ino);

    ret = cetrafs_alloc_block_anywhere(sb, &bg_id, &lba);
    if (ret) {
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(ret);
    }
    fs_debug(info, "mkdir '%.*s': allocated data block lba=%llu in bg=%u", (int) dentry->d_name.len,
             dentry->d_name.name, (unsigned long long) lba, bg_id);

    /* Claimed without reading: every byte is overwritten below. */
    bh = cetrafs_getblk_overwrite(sb, lba);
    if (!bh) {
        cetrafs_free_data_block(sb, lba);
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(-EIO);
    }
    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    dirblk = (cetrafs_dirent_t *) bh->b_data;

    dirblk[0].inode = cetrafs_cpu_to_le64(ino);
    dirblk[0].file_type = CETRAFS_FT_DIR;
    dirblk[0].name_len = cetrafs_cpu_to_le16(1);
    dirblk[0].name[0] = '.';

    dirblk[1].inode = cetrafs_cpu_to_le64(dir->i_ino);
    dirblk[1].file_type = CETRAFS_FT_DIR;
    dirblk[1].name_len = cetrafs_cpu_to_le16(2);
    dirblk[1].name[0] = '.';
    dirblk[1].name[1] = '.';

    /* Deliberately NOT journaled, unlike every other dirent block write.
     *
     * The journal exists so a block that a peer can already reach is
     * repairable if we die midway through rewriting it. This block is
     * reachable by nobody: the child's inode record is not written yet,
     * and the entry naming the child is added to the parent last of all.
     * A crash anywhere before that leaves an allocated inode and an
     * allocated block that nothing names -- the bounded leak fsck
     * already reports, and the same residue the create and symlink
     * unwind paths leave. Journaling it would buy a repair for a block
     * no reader can find.
     *
     * Synchronous, though, and that part is load-bearing: the block has
     * to be a VALID dirent block on the device before the parent entry
     * makes it reachable (a torn image a peer walks is an -EIO its
     * retries cannot resolve). Worth 3 of mkdir's 11 device writes --
     * the journal costs four per block (payload, header, target,
     * consume) and on the real LUN a write is ~38 ms. */
    cetrafs_dirent_block_stamp(bh);
    cetrafs_bh_end_update(bh);
    ret = sync_dirty_buffer(bh);
    brelse(bh);
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(ret);
    }

    now = ktime_get_real_seconds();
    memset(&raw, 0, sizeof(raw));
    raw.ino = cetrafs_cpu_to_le64(ino);
    {
        umode_t m = S_IFDIR | (mode & 07777);

        /* S_ISDIR is set here, so cetrafs_init_owner() also propagates
         * the parent's setgid bit -- without that the inheritance
         * applies to files but stops at the first subdirectory. */
        {
        u32 _u, _g;
        cetrafs_init_owner(idmap, dir, &m, &_u, &_g);
        raw.uid = cetrafs_cpu_to_le32(_u);
        raw.gid = cetrafs_cpu_to_le32(_g);
    }
        raw.mode = cetrafs_cpu_to_le32(m);
    }
    raw.nlink = cetrafs_cpu_to_le32(2);
    raw.generation = cetrafs_cpu_to_le64(cetrafs_inode_new_generation(sb)); /* v0x0008 reuse detector */
    raw.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);          /* v0x000A: 0 is a real node id, so be explicit */
    raw.size = cetrafs_cpu_to_le64(sizeof(cetrafs_dirent_t) * 2);
    raw.blocks = cetrafs_cpu_to_le64(CETRAFS_BLOCK_SIZE / 512);
    raw.ctime = raw.mtime = raw.atime = cetrafs_cpu_to_le64((u64) now);
    raw.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    raw.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    raw.eh.eh_entries = cetrafs_cpu_to_le16(1);
    raw.eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw.et.leaf));
    raw.et.leaf[0].ee_block = 0;
    raw.et.leaf[0].ee_len = cetrafs_extent_pack_len(1, 0);
    cetrafs_extent_phys_to_hilo(lba, &raw.et.leaf[0].ee_start_hi, &raw.et.leaf[0].ee_start_lo);

    /* See inode.c's cetrafs_write_raw_inode() comment and cetrafs_
     * create_locked() above -- same freshly-allocated-inode race. */
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_write_raw_inode(sb, ino, &raw, /*sync=*/true);
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(ret);
    }
    {
        bool still = false;

        /* Mid-birth theft check -- see cetrafs_alloc_inode_still_owned().
         * On theft nothing here owns the number any more: do NOT free it
         * (that would clobber the thief's arbitration); fail loudly. The
         * '.'/'..' block is ours alone and never became reachable. */
        if (cetrafs_alloc_inode_still_owned(sb, ino, &still) != 0 || !still) {
            pr_err("mkdir: ino=%llu was freed out from under its own birth (a peer scrub's stale verdict?) -- refusing\n",
                   (unsigned long long) ino);
            cetrafs_sb_birth_end(sb, ino);
            cetrafs_free_data_block(sb, lba);
            return ERR_PTR(-EIO);
        }
    }

    /* Instantiate, label, and only then name it -- see
     * cetrafs_create_publish(). Nothing on these failure paths removes a
     * dirent or touches the parent's nlink, because the entry does not
     * exist yet; and once the in-core inode exists, the discard frees the
     * '.'/'..' block and the inode number through eviction (the record's
     * extent already names that block, so freeing it by hand here would
     * be a double free). */
    inode = cetrafs_iget(sb, ino);
    if (IS_ERR(inode)) {
        cetrafs_free_data_block(sb, lba);
        cetrafs_free_inode(sb, ino);
        return ERR_CAST(inode);
    }

    ret = cetrafs_create_publish(dir, dentry, inode);
    if (ret) {
        cetrafs_new_inode_discard(inode);
        return ERR_PTR(ret);
    }
    return NULL;
}

static struct dentry *cetrafs_mkdir(struct mnt_idmap *idmap, struct inode *dir, struct dentry *dentry, umode_t mode)
{
    struct inode *set[] = {dir}; /* child freshly allocated -- see cetrafs_create() */
    struct dentry *dret;
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ERR_PTR(ret);

    dret = cetrafs_mkdir_locked(idmap, dir, dentry, mode);
    cetrafs_ns_report("mkdir", dir, &dentry->d_name, IS_ERR(dret) ? (int) PTR_ERR(dret) : 0);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return dret;
}

/*
 * Unlink a regular file: remove its dirent from 'dir', drop its link count,
 * and -- since there is no hardlink support yet, nlink
 * always hits 0 here -- free its data blocks and inode bit immediately.
 * rmdir lands in a later, dedicated change.
 */
/*
 * before this unlink can actually destroy data (nlink
 * dropping to 0 frees the inode's blocks and bitmap bit), check whether a
 * *live* other node currently holds this file's cross-node exclusive
 * write lock -- if so, refuse with -ETXTBSY rather than freeing blocks a
 * different node might still be actively writing into through its own
 * open fd. Checked up front, before cetrafs_dir_remove_entry() touches
 * anything, so a blocked unlink leaves the dirent (and everything else)
 * untouched. Removing one of several hardlinked names (nlink staying
 * above 0) never destroys data, so it's never blocked by this check --
 * see cetrafs_lock_foreign_claim_exists()'s own comment for why a lock
 * held by a now-stale node doesn't block either.
 */
/*
 * Under the namespace lock, confirm 'name' in 'dir' still resolves to
 * the inode the caller locked.
 *
 * cetrafs_d_revalidate() asks the same question on every path lookup,
 * which covers the ordinary case -- but it asks it BEFORE the namespace
 * lock, and cetrafs_nslock_acquire() sleeps while a live peer holds the
 * lock (up to CETRAFS_NSLOCK_RETRIES * CETRAFS_NSLOCK_SLEEP_MS). A peer
 * renaming something onto this name during that wait leaves every
 * decision made from d_inode(dentry) aimed at the wrong file: the
 * "is a live peer still using it?" checks would be
 * asked about an inode nobody is unlinking, while the record that
 * really loses its last name is mutated holding no lock on it at all.
 * The window is widest exactly when contention is, which
 * is when it matters.
 *
 * -ESTALE, not an internal retry: unlike rename -- whose destination
 * the wrapper re-discovers for itself -- the victim here is the VFS's
 * dentry, which this code cannot re-resolve. ESTALE is the standard
 * "your cached name is stale, look it up again" answer and is legal for
 * both unlink(2) and rmdir(2); d_revalidate then re-resolves the name,
 * so a retried call operates on the right inode.
 */
static int cetrafs_verify_name_resolves(struct inode *dir, const struct qstr *name, struct inode *inode)
{
    struct cetrafs_lookup_ctx ctx = {.name = name, .ino = 0};
    int ret;

    ret = cetrafs_walk_dirents(dir, cetrafs_lookup_visit, &ctx);
    if (ret)
        return ret;
    if (ctx.ino != inode->i_ino) {
        fs_debug(info, "'%.*s' in dir ino=%llu now names ino=%llu, not the locked ino=%llu -- stale dentry",
                 (int) name->len, name->name, (unsigned long long) dir->i_ino, (unsigned long long) ctx.ino,
                 (unsigned long long) inode->i_ino);
        return -ESTALE;
    }

    /*
     * The NUMBER matching is not enough: inode numbers are reused, so a
     * dentry remembering a dead file passes this check the moment the
     * name comes to point at a NEW file that was handed the same number.
     * The operation then runs its decision against one incarnation and
     * its mutation against the other.
     *
     * Caught on the cluster by ctest's hypervisor-storm: node
     * c judged a directory empty and removed the name, while the inode
     * the name actually referred to held four files another node had
     * created. The log showed one inode number carrying three different
     * generations inside a single run -- the churn this scenario
     * produces reuses numbers fast. The result was an orphaned subtree
     * and the "unreachable inode" faults fsck then reports.
     *
     * So compare the GENERATION too, which is the field that exists to
     * tell incarnations apart (CLAUDE.md rule 2). Forced-fresh: this
     * node's cached copy of the record is exactly what cannot be trusted
     * here.
     */
    {
        cetrafs_inode_t raw;

        cetrafs_invalidate_raw_inode(dir->i_sb, ctx.ino);
        ret = cetrafs_read_raw_inode(dir->i_sb, ctx.ino, &raw);
        if (ret)
            return ret;
        if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
            pr_warn_ratelimited(
                "'%.*s' in dir ino=%llu still names ino=%llu, but that is a DIFFERENT file now "
                "(generation %llu on disk, %llu in core) -- refusing to act on a reused inode number\n",
                (int) name->len, name->name, (unsigned long long) dir->i_ino, (unsigned long long) ctx.ino,
                (unsigned long long) cetrafs_le64(raw.generation),
                (unsigned long long) cetrafs_inode_get_generation(inode));
            return -ESTALE;
        }
    }
    return 0;
}

/* ---- v0x0005 namespace-sector appliers (cetrafs_inode_ns_cas) -------
 * Each runs on the LIVE sector-0 image inside the CAS (and re-runs on
 * internal retries), so each is written as a function of that image. */

struct cetrafs_ns_delta {
    s32 nlink_delta;    /* applied to the live value, floored at 0 */
    bool set_nlink_zero;/* rmdir/rename-over-dir: unconditional 0 */
    u64 ctime;          /* stamped when nonzero */
    u32 out_nlink;      /* the value the winning swap landed */
};

static void cetrafs_ns_apply_delta(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_ns_delta *d = arg;
    long live = (long) cetrafs_le32(rec->nlink) + d->nlink_delta;

    if (live < 0)
        live = 0;
    if (d->set_nlink_zero)
        live = 0;
    rec->nlink = cetrafs_cpu_to_le32((u32) live);
    if (d->ctime)
        rec->ctime = cetrafs_cpu_to_le64(d->ctime);
    d->out_nlink = (u32) live;
}

static int cetrafs_unlink_locked(struct inode *dir, struct dentry *dentry)
{
    struct inode *inode = d_inode(dentry);
    cetrafs_inode_t raw;
    u64 ino;
    u8 file_type;
    int ret;

    fs_debug(info, "unlink '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    ret = cetrafs_verify_name_resolves(dir, &dentry->d_name, inode);
    if (ret)
        return ret;

    /* nlink is a namespace-level property -- any node's link()/unlink()
     * on any name of this inode can change it, not just operations on
     * this file's own open fd, so it needs the same freshness as a
     * directory's own inode record. */
    cetrafs_invalidate_raw_inode(dir->i_sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, inode->i_ino, &raw);
    if (ret)
        return ret;

    {
        u32 my_node_id;
        bool blocked = false;

        ret = cetrafs_sb_get_node_id(dir->i_sb, &my_node_id);
        if (ret)
            return ret;

        /* Both questions from one forced-fresh read: a
         * live peer WRITING it, and -- the read side -- a
         * live peer READING it, which takes no lock at all (that is
         * the whole design) and leaves only its bit in
         * read_open_nodes. Freeing the blocks under either would hand
         * them to the allocator while that peer still has the file
         * open through an fd that never re-looks-up.
         *
         * EVERY unlink, not just the last name's (nlink<=1, the
         * will-free case this check was born for): removing one name of
         * a HARDLINKED file decrements its nlink, and an opener's
         * deferred hot-path record dirt reverts that decrement when it
         * flushes -- the ns-fuzz lost-decrement class. A
         * record with a live foreign user is that user's; same -ETXTBSY
         * link() and truncate now give. */
        bool reader = false;

        ret = cetrafs_lock_foreign_user_exists(dir->i_sb, inode->i_ino, my_node_id, &blocked, &reader);
        if (ret)
            return ret;
        if (blocked || reader)
            return -ETXTBSY;
    }

    ret = cetrafs_dir_remove_entry(dir, &dentry->d_name, &ino, &file_type);
    if (ret)
        return ret;

    /*
     * Re-read only if the name resolved to something other than the
     * inode we verified and locked.
     *
     * For the ordinary case -- and after cetrafs_verify_name_resolves()
     * above, it is the only case -- `raw` is already this inode's
     * record, read fresh a few lines up, and nothing can have changed
     * it since: this node holds that inode's OWN namespace lock, so no
     * peer may touch it, and cetrafs_dir_remove_entry() writes the
     * parent's dirent block and the parent's record, never the
     * victim's. A forced-fresh re-read there is a device round trip
     * (tens of milliseconds on a real LUN) spent confirming what the
     * lock already guarantees.
     *
     * The mismatch branch is kept rather than asserted away: it is
     * cheap, and "the lock guarantees it" is exactly the kind of
     * reasoning that should still have a fallback.
     */
    if (ino != inode->i_ino) {
        cetrafs_invalidate_raw_inode(dir->i_sb, ino);
        ret = cetrafs_read_raw_inode(dir->i_sb, ino, &raw);
        if (ret)
            return ret;
    }

    if (cetrafs_le32(raw.nlink) > 0)
        raw.nlink = cetrafs_cpu_to_le32(cetrafs_le32(raw.nlink) - 1);
    /* POSIX: removing a link updates the inode's ctime. This was set on
     * the in-core object a few lines below and never on the record, so
     * a surviving hardlink's ctime was whatever it had been before. */
    raw.ctime = cetrafs_cpu_to_le64((u64) ktime_get_real_seconds());

    /* Persist nlink (possibly now 0) but never free blocks/the inode
     * number here -- see super_ops.c's cetrafs_evict_inode() for why
     * that's deferred to actual VFS eviction, not this nlink-drops-to-0
     * moment.
     *
     * Staged for the namespace lock's release when this really is the
     * inode the lock set was built from. It may not be: the entry we
     * removed can name a different inode than the dentry cached (see
     * the re-read above), and staging on 'inode' would then publish
     * this record over the wrong one. */
    if (ino == inode->i_ino) {
        cetrafs_inode_stage_record(inode, &raw, /*fd_too=*/false);
    } else {
        /* Mismatch branch: a record we hold NO lock on -- the decrement
         * must be a namespace-sector CAS applied to the live value, never
         * a whole-record write (which would also revert that record's
         * presence bits and any concurrent accumulator change). */
        struct cetrafs_ns_delta d = {.nlink_delta = -1, .ctime = cetrafs_le64(raw.ctime)};

        ret = cetrafs_inode_ns_cas(dir->i_sb, ino, cetrafs_le64(raw.generation), &raw, cetrafs_ns_apply_delta, &d);
        if (ret)
            return ret;
    }

    /* Sync the in-core link count to the ABSOLUTE value just computed
     * from the forced-fresh on-disk read -- not a relative drop_nlink()
     * from this node's cached count. nlink is a cross-node accumulator:
     * a peer that added or removed another name of this inode since we
     * cached it left our i_nlink stale, and decrementing a stale count
     * gives a stale result. That matters because evict_inode() gates the
     * actual free on inode->i_nlink: a last unlink that computes disk
     * nlink=0 but drops a stale-high cached count to 1 leaves the file
     * with no names yet UNFREED -- "allocated but no directory entry --
     * unreachable" on a 3-node run ([create,link,unlink]).
     * Only when the entry named the inode we locked; the mismatch branch
     * above already wrote a different 'ino', and 'inode' is stale there. */
    if (ino == inode->i_ino)
        set_nlink(inode, cetrafs_le32(raw.nlink));
    else
        drop_nlink(inode);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);

    return 0;
}

static int cetrafs_unlink(struct inode *dir, struct dentry *dentry)
{
    /* Parent and victim both: the victim's nlink is mutated too, and another node can reach
     * that same inode through a different hardlink's parent. */
    struct inode *set[] = {dir, d_inode(dentry)};
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_unlink_locked(dir, dentry);
    cetrafs_ns_report("unlink", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

struct cetrafs_dir_nondot_ctx {
    int found;
};

static int cetrafs_dir_nondot_visit(void *priv, const cetrafs_dirent_t *de, loff_t pos)
{
    struct cetrafs_dir_nondot_ctx *ctx = priv;

    (void) pos;

    if ((cetrafs_le16(de->name_len) == 1 && de->name[0] == '.') || (cetrafs_le16(de->name_len) == 2 && de->name[0] == '.' && de->name[1] == '.'))
        return 0;

    ctx->found = 1;
    return 1; /* stop: non-empty, no need to keep scanning */
}

/*
 * Remove an empty subdirectory: verify it holds nothing but '.'/'..', remove
 * its dirent from 'dir' (which also drops dir's nlink, via
 * cetrafs_dir_remove_entry()), then free its data block(s) and inode bit --
 * directories can't be hardlinked, so this is always a free, unlike unlink().
 */
static int cetrafs_rmdir_locked(struct inode *dir, struct dentry *dentry)
{
    struct inode *inode = d_inode(dentry);
    struct cetrafs_dir_nondot_ctx ctx = {.found = 0};
    cetrafs_inode_t raw;
    u64 ino;
    u8 file_type;
    int ret;

    fs_debug(info, "rmdir '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    /* Before the emptiness check, which is asked of d_inode(dentry):
     * a name repointed at a POPULATED directory would otherwise pass a
     * check run against the empty one this dentry remembers. */
    ret = cetrafs_verify_name_resolves(dir, &dentry->d_name, inode);
    if (ret)
        return ret;

    ret = cetrafs_walk_dirents(inode, cetrafs_dir_nondot_visit, &ctx);
    if (ret)
        return ret;
    if (ctx.found)
        return -ENOTEMPTY;


    ret = cetrafs_dir_remove_entry(dir, &dentry->d_name, &ino, &file_type);
    if (ret)
        return ret;

    cetrafs_invalidate_raw_inode(dir->i_sb, ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, ino, &raw);
    if (ret)
        return ret;

    /* Persist nlink=0 but never free blocks/the inode number here -- see
     * super_ops.c's cetrafs_evict_inode() for why that's deferred to
     * actual VFS eviction, not this point. Staged for the namespace
     * lock's release, but only when this is the inode the lock set was
     * built from -- see cetrafs_unlink_locked(). */
    raw.nlink = 0;
    if (ino == inode->i_ino) {
        cetrafs_inode_stage_record(inode, &raw, /*fd_too=*/false);
    } else {
        /* Unlocked record: sector-0 CAS, same reasoning as unlink's
         * mismatch branch. */
        struct cetrafs_ns_delta d = {.set_nlink_zero = true, .ctime = (u64) ktime_get_real_seconds()};

        ret = cetrafs_inode_ns_cas(dir->i_sb, ino, cetrafs_le64(raw.generation), &raw, cetrafs_ns_apply_delta, &d);
        if (ret)
            return ret;
    }

    clear_nlink(inode);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);

    return 0;
}

static int cetrafs_rmdir(struct inode *dir, struct dentry *dentry)
{
    /* Parent and victim both: the victim directory is itself a lockable parent, so a peer
     * could otherwise be mid-create inside the directory we free. */
    struct inode *set[] = {dir, d_inode(dentry)};
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_rmdir_locked(dir, dentry);
    cetrafs_ns_report("rmdir", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/*
 * Rename/move a dirent, optionally replacing an existing target (POSIX
 * semantics: replacing a directory requires the target be an empty
 * directory and the source also be a directory; replacing a non-directory
 * requires the source also be a non-directory). RENAME_EXCHANGE and
 * RENAME_WHITEOUT aren't supported (-EINVAL); RENAME_NOREPLACE is.
 *
 * Adds the new dirent before removing the old one, so a failure here (only
 * -ENOSPC, if new_dir's own extents are full) leaves the source intact
 * under its original name rather than losing it. If an existing target is
 * being replaced, its dirent is removed (and resources freed, mirroring
 * unlink/rmdir) up front -- a failure between then and the add below would
 * leave the target gone without the move completing; accepted as a known,
 * narrow edge case rather than engineering a full two-phase commit for it.
 *
 * when replacing an existing target, this also checks -- before
 * touching anything -- whether a *live* other node holds the target's
 * cross-node exclusive write lock, exactly like cetrafs_unlink_locked()
 * does, and for the same reason: replacing a target whose nlink is about
 * to drop to 0 frees its blocks, which must not happen while a different
 * node might still be actively writing to them. The side being renamed
 * *from* never needs this check -- a rename never frees that inode's data,
 * it just moves/renames the dirent pointing at it.
 *
 * new_inode (d_inode(new_dentry)) reflects the
 * VFS's *own* lookup of the target name, which happened before this call
 * ever reached the namespace lock -- a peer node can create that
 * exact name in the window between that lookup and this call reaching
 * the front of the mutex. If the VFS believed the name was negative
 * (new_inode == NULL) but a peer's create/mkdir/rename has since landed
 * there, this used to find out the hard way, much further down: plain
 * cetrafs_dir_add_entry() on that (now-taken) name failing with -EEXIST,
 * a hard failure surfaced to userspace instead of the ordinary replace
 * this rename should perform (exactly as if the VFS's own lookup had
 * seen it to begin with). Found via a real two-node repro: two nodes
 * renaming different sources onto the same brand-new target name "at
 * the same instant" had the loser fail with EEXIST rather than its
 * rename succeeding as a replace. Fixed by re-checking fresh (uncached)
 * whenever new_inode is NULL, and iget()-ing the current target if one
 * now exists, before any of the logic below -- from here on this
 * function can't tell the difference between "the VFS already knew"
 * and "a peer just won this race," which is exactly the point.
 */
/*
 * Test only: make the next N rename destination re-verifications report
 * a lost race, so the retry loop in cetrafs_rename() has a caller on a
 * single kernel. The real trigger is a peer renaming onto the same name
 * at the same instant, which one kernel cannot produce -- the VFS holds
 * both parents' inode locks across rename and resolves the destination
 * itself -- so without this knob the loop is exercised by nothing.
 */
static unsigned int cetrafs_rename_force_retry;
module_param_named(rename_force_retry, cetrafs_rename_force_retry, uint, 0644);
MODULE_PARM_DESC(rename_force_retry, "test only: report a lost destination race on the next N renames");

static int cetrafs_rename_locked(struct mnt_idmap *idmap,
                                 struct inode *old_dir,
                                 struct dentry *old_dentry,
                                 struct inode *new_dir,
                                 struct dentry *new_dentry,
                                 unsigned int flags,
                                 struct inode *target,
                                 bool *out_target_changed)
{
    struct inode *old_inode = d_inode(old_dentry);
    struct inode *new_inode = target;
    u64 old_ino, discard_ino;
    u8 discard_file_type;
    u8 old_file_type;
    time64_t now;
    int ret;

    if (flags & ~RENAME_NOREPLACE)
        return -EINVAL;

    /* The destination is whatever the WRAPPER found and locked -- the
     * VFS's own idea of it when that was still true, otherwise a fresh
     * walk. It has to be decided before the namespace locks are taken,
     * because its nlink is mutated and its blocks may be freed, so it
     * must be IN the lock set: deciding it here instead meant mutating
     * an inode while holding no lock on it at all, the shape P7 found
     * in link().
     *
     * Re-verify it under the locks. That discovery was lock-free, so a
     * peer may since have created, removed or replaced the destination
     * name -- and proceeding on the stale answer is not a near miss, it
     * is corruption: cetrafs_dir_retarget_entry() would remove whatever
     * the name NOW points at while the nlink decrement below lands on
     * the inode we thought was there. One lost decrement on a live
     * file, one spurious one on a file nobody named.
     *
     * A mismatch is reported to the caller as a lost race rather than
     * returned to userspace. It is transient by construction -- the
     * peer's rename has landed, and re-reading finds a stable answer --
     * and rename(2) has no business failing because another node got
     * there first. */
    {
        struct cetrafs_lookup_ctx ctx = {.name = &new_dentry->d_name, .ino = 0};
        u64 locked_ino = new_inode ? new_inode->i_ino : 0;

        ret = cetrafs_walk_dirents(new_dir, cetrafs_lookup_visit, &ctx);
        if (ret)
            return ret;

        /* Test-only: pretend a peer changed the name under us. A single
         * kernel cannot reach this branch on its own -- the VFS holds
         * both parents' inode locks across the whole rename and resolves
         * the destination itself -- so without this the retry below is
         * exercised by nothing. */
        if (cetrafs_rename_force_retry) {
            cetrafs_rename_force_retry--;
            ctx.ino = locked_ino + 1;
        }

        /*
         * Same reused-number trap as cetrafs_verify_name_resolves(): the
         * target can have been deleted and its inode NUMBER handed to a
         * new file between locking it and getting here, in which case
         * the comparison below matches while the two are different
         * files -- and the rename then unlinks whatever took the
         * number. Treat a generation mismatch exactly like a changed
         * number: retry the whole operation against what is there now.
         */
        if (ctx.ino != 0 && ctx.ino == locked_ino && new_inode) {
            cetrafs_inode_t *tr = kmalloc(sizeof(*tr), GFP_NOFS); /* off the stack: records are 1 KiB (v0x0005) */

            cetrafs_invalidate_raw_inode(new_dir->i_sb, ctx.ino);
            if (tr && cetrafs_read_raw_inode(new_dir->i_sb, ctx.ino, tr) == 0 &&
                cetrafs_le64(tr->generation) != cetrafs_inode_get_generation(new_inode)) {
                pr_warn_ratelimited(
                    "rename: '%.*s' in dir ino=%llu still names ino=%llu, but that is a DIFFERENT file now "
                    "(generation %llu on disk, %llu in core) -- retrying rather than renaming over it\n",
                    (int) new_dentry->d_name.len, new_dentry->d_name.name, (unsigned long long) new_dir->i_ino,
                    (unsigned long long) ctx.ino, (unsigned long long) cetrafs_le64(tr->generation),
                    (unsigned long long) cetrafs_inode_get_generation(new_inode));
                ctx.ino = locked_ino + 1; /* force the retry path below */
            }
            kfree(tr);
        }

        if (ctx.ino != locked_ino) {
            fs_debug(info,
                     "rename: '%.*s' in dir ino=%llu changed under us (now ino=%llu, locked ino=%llu) -- retrying",
                     (int) new_dentry->d_name.len, new_dentry->d_name.name, (unsigned long long) new_dir->i_ino,
                     (unsigned long long) ctx.ino, (unsigned long long) locked_ino);
            *out_target_changed = true;
            return -EBUSY;
        }
    }

    if (old_inode == new_inode)
        return 0; /* same file under both names: POSIX says no-op */

    /*
     * Re-verify the SOURCE under the lock, exactly as the destination is
     * re-verified above and as cetrafs_unlink_locked() does. old_inode
     * comes from d_inode(old_dentry) -- the VFS's own lookup, done
     * before this call reached the namespace lock -- and on a shared LUN
     * a peer can rename or remove that source name in the window since.
     * Trusting it is not a near miss but corruption: the add-new /
     * remove-old below would add a SECOND name for old_inode (the new
     * one) while the old name no longer names it, leaving one inode with
     * two dirents and nlink=1 -- caught as "nlink=1 but 2 directory
     * entries name it", and, once one of those names is later replaced,
     * as a dirent pointing at a FREE inode (* [create,rename]). A generation mismatch (the number was reused for
     * a different file) is the same hazard, which verify_name_resolves()
     * folds in.
     *
     * Returned directly, exactly as cetrafs_unlink_locked() returns it,
     * NOT via the destination's retry path: the source comes from the
     * VFS's fixed old_dentry, which this node cannot re-resolve, so a
     * retry would re-check the same stale dentry and spin to EBUSY. The
     * source name as the caller knew it no longer names this inode --
     * ESTALE is the honest answer, and this node mutates nothing. */
    ret = cetrafs_verify_name_resolves(old_dir, &old_dentry->d_name, old_inode);
    if (ret) {
        fs_debug(info, "rename: source '%.*s' in dir ino=%llu no longer names ino=%llu (%d)",
                 (int) old_dentry->d_name.len, old_dentry->d_name.name, (unsigned long long) old_dir->i_ino,
                 (unsigned long long) old_inode->i_ino, ret);
        return ret;
    }

    if (new_inode) {
        if (flags & RENAME_NOREPLACE) {
            ret = -EEXIST;
            goto out;
        }

        if (S_ISDIR(old_inode->i_mode) != S_ISDIR(new_inode->i_mode)) {
            ret = S_ISDIR(old_inode->i_mode) ? -ENOTDIR : -EISDIR;
            goto out;
        }

        if (S_ISDIR(new_inode->i_mode)) {
            struct cetrafs_dir_nondot_ctx ctx = {.found = 0};

            ret = cetrafs_walk_dirents(new_inode, cetrafs_dir_nondot_visit, &ctx);
            if (ret)
                goto out;
            if (ctx.found) {
                ret = -ENOTEMPTY;
                goto out;
            }
        }
    }

    /* Replacing an existing non-directory target only frees its blocks if
     * this was its last name (nlink dropping to 0 below); a directory
     * target is always a lone name (directories can't be hardlinked), so
     * replacing one always frees it. Check up front, before anything is
     * mutated, same posture as cetrafs_unlink_locked(). */
    if (new_inode) {
        {
            u32 my_node_id;
            bool blocked = false;

            ret = cetrafs_sb_get_node_id(new_dir->i_sb, &my_node_id);
            if (ret)
                goto out;

            /* A peer writing it, or a peer READING it -- see
             * cetrafs_unlink_locked() -- from one forced-fresh read.
             * EVERY replace, not just the will-free (last-name) case:
             * replacing one name of a hardlinked target decrements its
             * nlink, and a foreign opener's deferred record dirt reverts
             * that on flush -- the same lost-decrement class unlink and
             * link are gated against (ns-fuzz). */
            bool reader = false;

            ret = cetrafs_lock_foreign_user_exists(new_dir->i_sb, new_inode->i_ino, my_node_id, &blocked, &reader);
            if (ret)
                goto out;
            if (blocked || reader) {
                ret = -ETXTBSY;
                goto out;
            }
        }
    }

    fs_debug(info, "rename '%.*s' (dir ino=%llu) -> '%.*s' (dir ino=%llu)", (int) old_dentry->d_name.len,
             old_dentry->d_name.name, (unsigned long long) old_dir->i_ino, (int) new_dentry->d_name.len,
             new_dentry->d_name.name, (unsigned long long) new_dir->i_ino);

    old_ino = old_inode->i_ino;
    old_file_type = cetrafs_dirent_type(old_inode);
    now = ktime_get_real_seconds();

    if (new_inode) {
        u64 removed_ino;
        u8 removed_file_type;
        cetrafs_inode_t raw;

        /* One dirent write, so the destination name never stops
         * resolving -- see cetrafs_dir_retarget_entry(). This both
         * satisfies POSIX ("the link named by new shall remain visible
         * to other processes throughout the renaming operation") and
         * removes the window in which a failure here could destroy the
         * target while leaving the source in place. */
        ret = cetrafs_dir_retarget_entry(new_dir, &new_dentry->d_name, old_ino, old_file_type, &removed_ino,
                                         &removed_file_type);
        if (ret)
            goto out;

        /* Neither branch frees blocks/the inode number here -- just
         * persists the correct nlink (0 for a replaced directory, which
         * can't be hardlinked; decremented otherwise) and lets the VFS's
         * own eviction trigger super_ops.c's cetrafs_evict_inode() once
         * the last reference actually goes away. Same reasoning as
         * cetrafs_unlink_locked()/cetrafs_rmdir_locked() above. */
        if (removed_file_type == CETRAFS_FT_DIR) {
            cetrafs_invalidate_raw_inode(new_dir->i_sb, removed_ino);
            if (!cetrafs_read_raw_inode(new_dir->i_sb, removed_ino, &raw)) {
                struct cetrafs_ns_delta d = {.set_nlink_zero = true, .ctime = (u64) now};

                cetrafs_inode_ns_cas(new_dir->i_sb, removed_ino, cetrafs_le64(raw.generation), &raw,
                                     cetrafs_ns_apply_delta, &d);
            }
            clear_nlink(new_inode);
        } else {
            struct cetrafs_ns_delta d = {.nlink_delta = -1, .ctime = (u64) now};

            cetrafs_invalidate_raw_inode(new_dir->i_sb, removed_ino);
            ret = cetrafs_read_raw_inode(new_dir->i_sb, removed_ino, &raw);
            if (!ret)
                ret = cetrafs_inode_ns_cas(new_dir->i_sb, removed_ino, cetrafs_le64(raw.generation), &raw,
                                           cetrafs_ns_apply_delta, &d);
            /* In-core absolute from the value the swap landed, not a
             * relative drop off a possibly stale cached count --
             * evict_inode() gates the free on the replaced target's
             * in-core i_nlink. */
            if (!ret && removed_ino == new_inode->i_ino)
                set_nlink(new_inode, d.out_nlink);
            else
                drop_nlink(new_inode);
        }
        inode_set_ctime(new_inode, now, 0);
    }

    if (!new_inode) {
        /* No target to replace: add the new name before removing the
         * old one, so a failure leaves the source intact. */
        ret = cetrafs_dir_add_entry(new_dir, &new_dentry->d_name, old_ino, old_file_type);
        if (ret)
            goto out;
    }

    ret = cetrafs_dir_remove_entry(old_dir, &old_dentry->d_name, &discard_ino, &discard_file_type);
    if (ret)
        goto out;

    if (old_file_type == CETRAFS_FT_DIR && old_dir != new_dir) {
        ret = cetrafs_dir_update_dotdot(old_inode, new_dir->i_ino);
        if (ret)
            goto out;
    }

    /* POSIX: a successful rename updates the moved inode's ctime. This
     * used to touch only the in-core object, which nothing then wrote
     * out (inode_set_ctime() does not dirty the inode), so the on-disk
     * value never moved. Same omission N6 found in unlink. */
    {
        cetrafs_inode_t oraw;

        /* The moved inode's on-disk ctime, by namespace-sector CAS: it
         * cannot touch the file sector, so renaming a file a peer is
         * actively WRITING is safe again (v0x0005) -- the old blind
         * whole-record rewrite here had to be skipped under a foreign
         * opener to avoid racing its deferred record state. */
        cetrafs_invalidate_raw_inode(old_dir->i_sb, old_ino);
        if (!cetrafs_read_raw_inode(old_dir->i_sb, old_ino, &oraw)) {
            struct cetrafs_ns_delta d = {.ctime = (u64) now};

            cetrafs_inode_ns_cas(old_dir->i_sb, old_ino, cetrafs_le64(oraw.generation), &oraw,
                                 cetrafs_ns_apply_delta, &d);
        }
    }
    inode_set_ctime(old_inode, now, 0);
    ret = 0;

out:
    return ret;
}

/*
 * How many times a rename re-discovers its destination before giving up.
 *
 * The destination has to be locked, and cannot be known without looking,
 * and looking is lock-free -- the standard lock-ordering problem, whose
 * standard answer is to retry. Each attempt is bounded work and the
 * losing node converges as soon as the peer's rename lands, so a small
 * count suffices; exhausting it means two nodes are renaming onto the
 * same name in a tight loop, which is a pathological workload and gets
 * the loud failure this project's correctness bar asks for.
 */
#define CETRAFS_RENAME_MAX_ATTEMPTS 4

static int cetrafs_rename(struct mnt_idmap *idmap,
                          struct inode *old_dir,
                          struct dentry *old_dentry,
                          struct inode *new_dir,
                          struct dentry *new_dentry,
                          unsigned int flags)
{
    unsigned int attempt;
    int ret = -EBUSY;

    /*
     * The destination name may already exist without the VFS knowing:
     * on a shared LUN a peer can create it -- or replace it -- after
     * this node's lookup returned. Its nlink is mutated and its blocks
     * may be freed, so it has to be IN the lock set, which means
     * deciding it BEFORE the locks are taken, not after.
     *
     * That decision is therefore lock-free and can be wrong, so
     * cetrafs_rename_locked() re-checks it once the locks are held and
     * reports a mismatch back here instead of to userspace. Found by
     * ctest's concurrent-rename against real two-node hardware: two
     * nodes renaming different sources onto the same brand-new name had
     * the loser fail with EBUSY, which is not an outcome rename(2) is
     * allowed to have -- POSIX requires a rename over an existing name
     * to succeed, and no application handles EBUSY from one. The
     * refusal was the safe half of "detect a lost race and fail loudly
     * (retry, return an error)"; a retry is available here, so it is
     * the correct half.
     */
    for (attempt = 0; attempt < CETRAFS_RENAME_MAX_ATTEMPTS; attempt++) {
        struct inode *discovered = NULL;
        struct inode *target;
        struct inode *set[4];
        bool target_changed = false;

        /* The first attempt trusts the VFS's own lookup and only walks
         * when it came back negative. A retry cannot: what failed IS
         * the destination's identity, so a stale positive dentry is
         * exactly as wrong as a stale negative one, and the directory
         * is re-read either way. (The walk's dirent_seq check reads the
         * directory's record forced-fresh, so a peer's bump is always
         * seen and the cached scan cannot serve a stale answer here.) */
        target = (attempt == 0) ? d_inode(new_dentry) : NULL;
        if (!target) {
            struct cetrafs_lookup_ctx ctx = {.name = &new_dentry->d_name, .ino = 0};

            if (cetrafs_walk_dirents(new_dir, cetrafs_lookup_visit, &ctx) == 0 && ctx.ino) {
                discovered = cetrafs_iget(new_dir->i_sb, ctx.ino);
                if (IS_ERR(discovered)) {
                    ret = PTR_ERR(discovered);
                    /* The name we just read has since been unlinked by a
                     * peer. That is the same lost race (-ESTALE),
                     * one step earlier: re-read rather than fail. */
                    if (ret == -ESTALE)
                        continue;
                    return ret;
                }
                target = discovered;
            }
        }

        /* The widest set: both parents' dirents, the moved inode (its
         * '..' is rewritten when it changes parent), and the replaced
         * target (NULL for a plain rename -- acquire_set() skips
         * NULLs), whose nlink drops and whose blocks may be freed. */
        set[0] = old_dir;
        set[1] = new_dir;
        set[2] = d_inode(old_dentry);
        set[3] = target;

        ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));
        if (ret) {
            if (discovered)
                iput(discovered);
            return ret;
        }

        ret = cetrafs_rename_locked(idmap, old_dir, old_dentry, new_dir, new_dentry, flags, target, &target_changed);
        cetrafs_ns_report("rename", old_dir, &old_dentry->d_name, ret);

        cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
        if (discovered)
            iput(discovered);

        if (!target_changed)
            return ret;
    }

    pr_warn_ratelimited("rename: '%.*s' in dir ino=%llu changed under us %u times running -- giving up\n",
                        (int) new_dentry->d_name.len, new_dentry->d_name.name, (unsigned long long) new_dir->i_ino,
                        CETRAFS_RENAME_MAX_ATTEMPTS);
    return ret;
}

/*
 * Hardlink: add a dirent in 'dir' pointing at the existing inode behind
 * 'old_dentry', before touching its nlink (so a failure there leaves
 * everything as it was). Directories can't be hardlinked (-EPERM),
 * matching POSIX and how this filesystem has no way to represent a
 * directory with multiple parents.
 */
static int cetrafs_link_locked(struct dentry *old_dentry, struct inode *dir, struct dentry *dentry)
{
    struct inode *inode = d_inode(old_dentry);
    cetrafs_inode_t raw;
    time64_t now;
    int ret;

    if (S_ISDIR(inode->i_mode))
        return -EPERM;

    /*
     * Refuse while a LIVE peer holds this file's exclusive lock, the
     * same way unlink, rename-replace, setattr and setxattr already do.
     *
     * The namespace lock and the file lock are different locks over the
     * same record: holding one excludes nothing holding the other. The
     * peer that owns the file lock rewrites this record through ordinary
     * writeback (size, mtime), reading it fresh and writing it whole --
     * so an nlink increment made here between that read and that write
     * is simply gone. A hardlink whose target believes nlink=1 is not a
     * cosmetic loss: unlinking either name then frees the blocks while
     * the other name still points at them.
     *
     * A lock held by a now-STALE node does not block, matching every
     * other site's reclaim posture.
     */
    {
        u32 my_node_id;
        bool blocked = false;
        bool reader = false;

        if (cetrafs_sb_get_node_id(dir->i_sb, &my_node_id) == 0) {
            /* PRESENCE, not just the exclusive claim: a peer with this
             * file merely OPEN (nofilelock write, or any read) holds
             * deferred hot-path record dirt whose eventual flush reverts
             * whatever this +1 writes -- the ns-fuzz lost-increment class
             *. While any foreign user exists, the record is
             * that opener's; refuse exactly as unlink does. */
            ret = cetrafs_lock_foreign_user_exists(dir->i_sb, inode->i_ino, my_node_id, &blocked, &reader);
            if (ret)
                return ret;
            if (blocked || reader)
                return -ETXTBSY;
        }
    }

    /* Is the record we are about to touch still the FILE this node
     * resolved? unlink, rmdir and rename ask (cetrafs_verify_name_
     * resolves()); this did not. The nslock makes the nlink
     * read-modify-write below safe and the read feeding it is forced
     * fresh -- neither says anything about IDENTITY. A peer that
     * unlinked this name frees the number, the next create takes it,
     * and a stale dentry here then names an unrelated file: the dirent
     * is published with the DEAD inode's type (a symlink's type over a
     * regular file's record) and that live file's nlink is incremented
     * for a name it does not own. The second half never heals -- its
     * real names go away, nlink never reaches 0, and the inode and its
     * blocks leak for the life of the filesystem.
     *
     * nlink==0 is the other direction: every name is already gone, so
     * there is nothing to link a second name to. */
    cetrafs_invalidate_raw_inode(dir->i_sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, inode->i_ino, &raw);
    if (ret)
        return ret;
    if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
        pr_warn_ratelimited("refusing to link '%.*s' -> ino=%llu: that number is a DIFFERENT file now (generation disk=%llu core=%llu)\n",
                            (int) dentry->d_name.len, dentry->d_name.name, (unsigned long long) inode->i_ino,
                            (unsigned long long) cetrafs_le64(raw.generation),
                            (unsigned long long) cetrafs_inode_get_generation(inode));
        return -ESTALE;
    }
    if (cetrafs_le32(raw.nlink) == 0) {
        pr_warn_ratelimited("refusing to link '%.*s' -> ino=%llu: it has no names left (nlink=0)\n",
                            (int) dentry->d_name.len, dentry->d_name.name, (unsigned long long) inode->i_ino);
        return -ENOENT;
    }

    fs_debug(info, "link '%.*s' -> ino=%llu in dir ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) inode->i_ino, (unsigned long long) dir->i_ino);

    ret = cetrafs_dir_add_entry(dir, &dentry->d_name, inode->i_ino, cetrafs_dirent_type(inode));
    if (ret)
        return ret;

    cetrafs_invalidate_raw_inode(dir->i_sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, inode->i_ino, &raw);
    if (ret) {
        u64 discard_ino;
        u8 discard_file_type;

        cetrafs_dir_remove_entry(dir, &dentry->d_name, &discard_ino, &discard_file_type);
        return ret;
    }

    /*
     * The +1 by namespace-sector CAS (v0x0005): applied to the LIVE
     * value, so it composes with every other sector-0 mutation --
     * lock.c's presence bits above all, which run without this lock and
     * which the old whole-record write here could silently revert. */
    now = ktime_get_real_seconds();
    {
        struct cetrafs_ns_delta d = {.nlink_delta = 1, .ctime = (u64) now};

        ret = cetrafs_inode_ns_cas(dir->i_sb, inode->i_ino, cetrafs_le64(raw.generation), &raw,
                                   cetrafs_ns_apply_delta, &d);
        if (ret) {
            u64 discard_ino;
            u8 discard_file_type;

            cetrafs_dir_remove_entry(dir, &dentry->d_name, &discard_ino, &discard_file_type);
            return ret;
        }

        /* In-core set to the absolute value the swap landed, not
         * inc_nlink() off a possibly stale cached count -- evict_inode()
         * reads inode->i_nlink and a stale count misleads it. */
        set_nlink(inode, d.out_nlink);
    }
    inode_set_ctime(inode, now, 0);
    ihold(inode);
    d_instantiate(dentry, inode);

    return 0;
}

static int cetrafs_link(struct dentry *old_dentry, struct inode *dir, struct dentry *dentry)
{
    /* Parent and target both: the target's nlink is mutated, and a peer
     * can be reaching it through one of its other names. */
    struct inode *set[] = {dir, d_inode(old_dentry)};
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_link_locked(old_dentry, dir, dentry);
    cetrafs_ns_report("link", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/*
 * Create a symlink: a regular-file-shaped inode (mode S_IFLNK, one data
 * block's worth of target text, through the exact same extent/get_block
 * machinery as a tiny regular file) plus a dirent of file_type FT_LNK.
 * page_symlink() writes the target via cetrafs_aops's write_begin/write_end
 * -- the same page-cache path a real write() would use -- so no bespoke
 * on-disk symlink format is needed.
 */
/* (The half-built-symlink discard grew into cetrafs_new_inode_discard()
 * above cetrafs_create_locked(), shared by every creation unwind.) */

/*
 * TEST ONLY: fail cetrafs_symlink_locked() after the target text has
 * been written, so the unwind from that point can be exercised. By then
 * an inode and a DATA BLOCK exist (the name does not yet -- it is added
 * last of all), which is what makes this the interesting error path --
 * and the only one no input a test can supply will ever reach.
 */
static bool cetrafs_symlink_fail_after_write;
module_param_named(symlink_fail_after_write, cetrafs_symlink_fail_after_write, bool, 0644);
MODULE_PARM_DESC(symlink_fail_after_write, "TEST ONLY: fail symlink() once its target block is written");

static int cetrafs_symlink_locked(struct mnt_idmap *idmap,
                                  struct inode *dir,
                                  struct dentry *dentry,
                                  const char *symname)
{
    struct super_block *sb = dir->i_sb;
    struct inode *inode;
    cetrafs_inode_t raw;
    u64 ino;
    time64_t now;
    int len = strlen(symname) + 1; /* page_symlink() wants the NUL included */
    int ret;

    if (len > CETRAFS_BLOCK_SIZE)
        return -ENAMETOOLONG; /* target must fit in the one block a symlink gets */

    fs_debug(info, "symlink '%.*s' -> '%s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name, symname,
             (unsigned long long) dir->i_ino);

    ret = cetrafs_alloc_inode(sb, &ino);
    if (ret)
        return ret;

    now = ktime_get_real_seconds();
    memset(&raw, 0, sizeof(raw));
    raw.ino = cetrafs_cpu_to_le64(ino);
    {
        umode_t m = S_IFLNK | 0777;

        {
        u32 _u, _g;
        cetrafs_init_owner(idmap, dir, &m, &_u, &_g);
        raw.uid = cetrafs_cpu_to_le32(_u);
        raw.gid = cetrafs_cpu_to_le32(_g);
    }
        raw.mode = cetrafs_cpu_to_le32(m); /* a symlink's own mode bits are not used, but its
                       * group still inherits from a setgid parent */
    }
    raw.nlink = cetrafs_cpu_to_le32(1);
    raw.ctime = raw.mtime = raw.atime = cetrafs_cpu_to_le64((u64) now);
    raw.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    raw.generation = cetrafs_cpu_to_le64(cetrafs_inode_new_generation(sb)); /* v0x0008 reuse detector */
    raw.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);          /* v0x000A: 0 is a real node id, so be explicit */
    raw.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    raw.eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw.et.leaf));

    /* See inode.c's cetrafs_write_raw_inode() comment and cetrafs_
     * create_locked() above -- same freshly-allocated-inode race. */
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_write_raw_inode(sb, ino, &raw, /*sync=*/true);
    if (ret) {
        cetrafs_free_inode(sb, ino);
        return ret;
    }
    {
        bool still = false;

        /* Mid-birth theft check -- see cetrafs_alloc_inode_still_owned().
         * On theft nothing here owns the number any more: do NOT free it
         * (that would clobber the thief's arbitration); fail loudly. */
        if (cetrafs_alloc_inode_still_owned(sb, ino, &still) != 0 || !still) {
            pr_err("create: ino=%llu was freed out from under its own birth (a peer scrub's stale verdict?) -- refusing\n",
                   (unsigned long long) ino);
            cetrafs_sb_birth_end(sb, ino);
            return -EIO;
        }
    }

    /* Instantiate, write the target text, label, and only then name it --
     * see cetrafs_create_publish(). The text goes in while the symlink is
     * still unreachable, so no peer (or local lookup) can ever resolve
     * the name to a size-0, target-less link mid-build. Nothing on these
     * failure paths removes a dirent, because none exists yet. */
    inode = cetrafs_iget(sb, ino);
    if (IS_ERR(inode)) {
        cetrafs_free_inode(sb, ino);
        return PTR_ERR(inode);
    }

    ret = page_symlink(inode, symname, len);
    if (ret) {
        cetrafs_new_inode_discard(inode);
        return ret;
    }

    /*
     * page_symlink() only writes the target text through the ordinary,
     * asynchronous write_begin/write_end page-cache path -- same as a
     * regular file's write(), which normally only becomes durable via
     * lock.c's cetrafs_lock_release() flushing it at the last writer's
     * close(). A symlink has no open/close lifecycle to hook that into,
     * so without an explicit flush here, the target block can still be
     * sitting only in this node's dirty page cache when a peer reads it
     * "cold": its real-device read then returns whatever physically
     * occupied that LBA before (a reused block from some other, already
     * -freed file), not the actual target text. Found via a real
     * two-node repro returning a completely unrelated previous file's
     * leftover bytes as the symlink target.
     *
     * Also explicitly persists the inode record (page_symlink() only
     * ever updates the in-core i_size; the on-disk record still has the
     * size=0 this function stamped it with above, and nothing else
     * would persist the real size until super_ops.c's .write_inode
     * eventually runs on the VFS's own writeback schedule) -- readlink()
     * on this same node could otherwise trigger dir.c's
     * cetrafs_d_revalidate() before that eventual writeback ever runs,
     * refresh from the still-size-0 on-disk record, and clobber the
     * correct in-core size right back to 0 (a real regression, caught
     * by tests/mount_test.sh's own symlink checks).
     */
    ret = filemap_write_and_wait(inode->i_mapping);
    if (!ret)
        ret = cetrafs_write_vfs_inode(inode);
    if (!ret && unlikely(cetrafs_symlink_fail_after_write))
        ret = -EIO;
    if (!ret)
        ret = cetrafs_create_publish(dir, dentry, inode);
    if (ret) {
        cetrafs_new_inode_discard(inode);
        return ret;
    }
    return 0;
}

static int cetrafs_symlink(struct mnt_idmap *idmap, struct inode *dir, struct dentry *dentry, const char *symname)
{
    struct inode *set[] = {dir}; /* child freshly allocated -- see cetrafs_create() */
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_symlink_locked(idmap, dir, dentry, symname);
    cetrafs_ns_report("symlink", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/* .lookup/.create/.mkdir/.unlink/.rmdir/.setattr/.rename/.link/.symlink
 * are all real today -- a later change is complete. .listxattr plus the
 * cetrafs_xattr_handlers array (in xattr.c, registered as sb->s_xattr in
 * fs.c) add the user.* xattr support. */
const struct inode_operations cetrafs_inode_ops = {
    .fiemap = cetrafs_fiemap,
    .lookup = cetrafs_lookup,
    .mkdir = cetrafs_mkdir,
    .create = cetrafs_create,
    .unlink = cetrafs_unlink,
    .rmdir = cetrafs_rmdir,
    .setattr = cetrafs_setattr,
    .rename = cetrafs_rename,
    .link = cetrafs_link,
    .symlink = cetrafs_symlink,
    .listxattr = cetrafs_listxattr,
};
