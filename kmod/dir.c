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
#include <linux/sort.h>
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

/* FS_IOC_SHUTDOWN works on a directory too -- the mount point is what
 * an operator or `xfs_io -x -c shutdown` opens. */
static long cetrafs_dir_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    if (cmd == FS_IOC_SHUTDOWN)
        return cetrafs_shutdown_ioctl(file_inode(file)->i_sb, (u32 __user *) arg);
    if (cmd == CETRAFS_IOC_GROW)
        return cetrafs_grow_ioctl(file, (const cetrafs_grow_arg_t __user *) arg);
    if (cmd == FITRIM) /* fstrim(8) opens the mount point */
        return cetrafs_fitrim_ioctl(file, (struct fstrim_range __user *) arg);
    return -ENOTTY;
}

/* Directory file operations */
const struct file_operations cetrafs_dir_ops = {
    .owner = THIS_MODULE,
    /* read(2) on a directory is EISDIR, and that is what this returns.
     * With no .read at all the VFS answers EINVAL instead -- a
     * different errno for a case POSIX names exactly, which userspace
     * does distinguish. */
    .read = generic_read_dir,
    .llseek = generic_file_llseek,
    .iterate_shared = cetrafs_readdir,
    .fsync = cetrafs_dir_fsync,
    .unlocked_ioctl = cetrafs_dir_ioctl,
    .compat_ioctl = compat_ptr_ioctl,
    .lock = cetrafs_posix_lock_refuse, /* as for files: never node-local (lock.c) */
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
 * that as -EIO). The same budget as every tail-checksummed read --
 * about a quarter of a second of backoff (cetrafs_tear_backoff()) --
 * not 20 tries, which with milliseconds between them would hold every
 * lookup of a genuinely damaged block for seconds.
 */
#define CETRAFS_DIRENT_READ_RETRIES CETRAFS_BLK_TAIL_READ_RETRIES

static void cetrafs_dirent_block_stamp(struct buffer_head *bh)
{
    cetrafs_dirent_tail_t *tail = (cetrafs_dirent_tail_t *) (bh->b_data + CETRAFS_DIRENT_TAIL_OFF);

    tail->magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
    tail->crc = cetrafs_cpu_to_le32(~crc32c(~0U, bh->b_data, CETRAFS_DIRENT_TAIL_OFF));
}

static bool cetrafs_dirent_block_valid(const struct buffer_head *bh)
{
    const cetrafs_dirent_tail_t *tail = (const cetrafs_dirent_tail_t *) (bh->b_data + CETRAFS_DIRENT_TAIL_OFF);

    if (cetrafs_le32(tail->magic) != CETRAFS_DIRENT_TAIL_MAGIC ||
        cetrafs_le32(tail->crc) != ~crc32c(~0U, bh->b_data, CETRAFS_DIRENT_TAIL_OFF))
        return false;
    /*
     * And the entries have to make sense, which the checksum does not
     * say. readdir hands name_len straight to dir_emit(), and the VFS
     * bounds it at PATH_MAX rather than NAME_MAX -- deliberately, see
     * verify_dirent_name() -- so a length of a few thousand is accepted
     * there and read out of a 255-byte field.
     *
     * This file reads dirent blocks through its OWN helper rather than
     * ioutil.c's, so the shared check had to be wired in here too: the
     * first version of this fix validated every other block kind and
     * silently skipped the one the bug was reported against.
     */
    return cetrafs_blk_struct_ok_magic(bh, CETRAFS_DIRENT_TAIL_MAGIC);
}

/* As cetrafs_dirent_bread(), saying why a NULL came back: -EUCLEAN when
 * every attempt read the block and found it damaged, -EIO when the
 * device failed a read. */
/* TEST ONLY: a dirent block that stays torn under a peer's namespace
 * lock counts as damage, as before audit 2026-11-15 M-16
 * (tests/kernel/dirent_tear_under_peer_lock.sh). */
static bool cetrafs_dirent_tear_lock_ignored;
cetrafs_test_param(dirent_tear_lock_ignored, cetrafs_dirent_tear_lock_ignored, bool, 0644);
MODULE_PARM_DESC(dirent_tear_lock_ignored, "TEST ONLY: a torn dirent block under a peer's namespace lock is damage");

/*
 * Every dirent write runs under its directory's namespace lock, and is
 * journaled. A block that stays torn while ANOTHER node holds that lock
 * is that node's write: in flight on a slow path, or stopped by its
 * death -- and then the reclaim that breaks the lock replays its
 * journal first (cetrafs_inode_ns_lock()), which rewrites the block.
 * Counted as damage, one node's crash raised needs-fsck on every node
 * that listed the directory within the stale window, and stopped each
 * of them under corruption=stop (audit 2026-11-15 M-16/BM-26). Read
 * fresh: an older copy can only say "held" of a lock since released,
 * which defers the verdict to the next read, never skips it for good.
 */
static bool cetrafs_dirent_tear_explained(struct super_block *sb, u64 ino, u64 lba)
{
    cetrafs_inode_t raw;
    u32 owner, me;

    if (!ino || READ_ONCE(cetrafs_dirent_tear_lock_ignored) || cetrafs_sb_get_node_id(sb, &me))
        return false;
    cetrafs_invalidate_raw_inode(sb, ino);
    if (cetrafs_read_raw_inode(sb, ino, &raw))
        return false;
    owner = cetrafs_le32(raw.ns_lock_owner);
    if (owner == CETRAFS_NODE_ID_NONE || owner == me)
        return false;
    pr_warn_ratelimited("dirent block %llu of directory ino=%llu reads torn while node %u holds its namespace lock -- "
                        "that node's write, in flight or awaiting replay: not counted as damage\n",
                        (unsigned long long) lba, (unsigned long long) ino, owner);
    return true;
}

/*
 * Dirent block content installed in this node's cache, bracketed: every
 * device load (a walk's forced or missed read and each of its retries,
 * the whole-directory refresh, the recount's batches and their
 * per-block fallback), every block this node fills itself (a new block,
 * mkdir's) and the journal replay's redos. begin() before the install
 * can start, end() once it is done -- a read's content lands when the
 * I/O completes, not when it is asked for. A lockless walk reads its
 * directory's record, then its blocks, and a peer's rmdir can free a
 * block in between and its next mkdir make it another directory's: a
 * valid dirent block with the wrong names (audit 2026-11-15 BL-51).
 * With this a walk knows whether anything it visits may have been
 * installed after its record read: an install that ended since its
 * snapshot, or one still in flight (cetrafs_dirent_loads_moved()).
 */
static atomic64_t cetrafs_dirent_loads = ATOMIC64_INIT(0);
static atomic_t cetrafs_dirent_loads_inflight = ATOMIC_INIT(0);

void cetrafs_dirent_load_begin(void)
{
    atomic_inc(&cetrafs_dirent_loads_inflight);
    smp_mb__after_atomic(); /* counted in flight before the install starts */
}

void cetrafs_dirent_load_end(void)
{
    smp_mb__before_atomic(); /* the install is done before it is counted */
    atomic64_inc(&cetrafs_dirent_loads);
    smp_mb__after_atomic(); /* counted ended before it stops being in flight */
    atomic_dec(&cetrafs_dirent_loads_inflight);
}

/* Before a walk's record read: the installs it may rely on. */
static s64 cetrafs_dirent_loads_snap(void)
{
    smp_mb();
    return atomic64_read(&cetrafs_dirent_loads);
}

/* After a block's copy: may anything have been installed since 'snap'?
 * *now: the count to snap again from, once the record is re-read. */
static bool cetrafs_dirent_loads_moved(s64 snap, s64 *now)
{
    smp_mb(); /* the copy, before the counts */
    *now = atomic64_read(&cetrafs_dirent_loads);
    return *now != snap || atomic_read(&cetrafs_dirent_loads_inflight);
}

static struct buffer_head *__cetrafs_dirent_bread_why(struct super_block *sb, u64 ino, u64 generation, u64 lba,
                                                      int *why)
{
    int attempt, nbad = 0;

    *why = -EIO;

    for (attempt = 0; attempt < CETRAFS_DIRENT_READ_RETRIES; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, lba);

        if (bh) {
            if (!cetrafs_tear_injected() && cetrafs_dirent_block_valid(bh))
                return bh;
            brelse(bh);
            nbad++;
        }

        /* Back off between attempts rather than spinning. A mismatch
         * here means a writer on ANOTHER node has a partially-written
         * image of this block on the device; it converges once that
         * node's write completes. (A writer on THIS node cannot be seen
         * mid-update at all: cetrafs_bh_begin_update() holds the buffer
         * lock across modify-and-restamp, which the forced-fresh read
         * below blocks on.) Back off rather than spin, so the budget
         * spans a peer's write rather than a few microseconds -- which
         * the 100-400 us this slept did not: five of them are about
         * 2 ms against a write that takes milliseconds (audit 2026-11-11
         * X1). cetrafs_tear_backoff() is milliseconds, doubling.
         * (A NULL read is retried on the same footing -- it means a
         * concurrent forced-fresh read of the same block cleared the
         * uptodate bit under us, which is equally transient.) */
        if (attempt + 1 < CETRAFS_DIRENT_READ_RETRIES)
            cetrafs_tear_backoff(attempt);
    }

    /* Corrupt only if every attempt read the block and failed: a read
     * that failed is the device's error (cetrafs_blk_tail_bread()). */
    if (nbad < CETRAFS_DIRENT_READ_RETRIES) {
        pr_err_ratelimited("dirent block %llu could not be read (%d of %d attempts failed) -- I/O error\n",
                           (unsigned long long) lba, CETRAFS_DIRENT_READ_RETRIES - nbad,
                           CETRAFS_DIRENT_READ_RETRIES);
        return NULL;
    }
    if (cetrafs_dirent_tear_explained(sb, ino, lba)) {
        *why = -EAGAIN;
        return NULL;
    }
    pr_err("dirent block %llu failed its tail checksum %d times -- corrupted, not just a torn concurrent read\n",
           (unsigned long long) lba, CETRAFS_DIRENT_READ_RETRIES);
    /* The directory's own damage, as for its tree blocks
     * (cetrafs_blk_tail_bread(), audit 2026-11-15 M-13). */
    if (cetrafs_tree_damage_unowned())
        ino = generation = 0;
    cetrafs_sb_corrupt_owner(sb, ino, generation);
    *why = -EUCLEAN;
    return NULL;
}

/* Every attempt of the read above installs: bracketed whole (BL-51). */
static struct buffer_head *cetrafs_dirent_bread_why(struct super_block *sb, u64 ino, u64 generation, u64 lba,
                                                    int *why)
{
    struct buffer_head *bh;

    cetrafs_dirent_load_begin();
    bh = __cetrafs_dirent_bread_why(sb, ino, generation, lba, why);
    cetrafs_dirent_load_end();
    return bh;
}

static struct buffer_head *cetrafs_dirent_bread(struct inode *dir, u64 lba)
{
    int why;

    return cetrafs_dirent_bread_why(dir->i_sb, dir->i_ino, cetrafs_inode_get_generation(dir), lba, &why);
}

/*
 * Make a freshly allocated block a valid, empty, durable dirent block.
 *
 * Called from file.c's cetrafs_get_block() the moment a block is
 * allocated for a DIRECTORY, before the extent referencing it is
 * committed. Ordering matters enormously here: a directory's data block
 * becomes reachable to every node the instant its extent lands (a
 * directory's tree blocks are journaled synchronously, so that is
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
/*
 * Does 'lba', which the allocator has just handed out as FREE, still
 * belong to a live directory? 0 if nothing proves it does, -EUCLEAN if
 * it does, -EIO if the question could not be answered.
 *
 * The answer drives a DESTRUCTIVE act -- the caller zeroes the block --
 * so every input is read forced-fresh, in the direction that matters:
 * a stale or merely cached read can only make a live block look free
 * (rule 6). The block itself comes off the DEVICE: this used to inspect
 * cetrafs_getblk_overwrite()'s buffer, which is never read, so on a
 * cold cache it saw nothing at all.
 *
 * Dirent bytes alone prove nothing: freeing a block does not zero it,
 * so a recycled block still carries its old directory's entries. In use
 * means the block's '.' entry names a LIVE directory whose extent tree
 * still lists this block. Only a directory's first block carries '.',
 * and nothing in a later block names its owner (there is no back
 * pointer in the format), so a later block is not covered: this is a
 * check behind the allocator, which stays the authority.
 */
/* Is inode slot 'ino' all zeros on the device -- a number never written,
 * as opposed to a record that failed its checksum? */
static bool cetrafs_dirent_owner_slot_zero(struct super_block *sb, u64 ino)
{
    u64 rec = cetrafs_inode_lba(sb, ino);
    struct buffer_head *bh;
    bool zero;

    if (!rec)
        return false;
    bh = cetrafs_bread_uncached(sb, rec);
    if (!bh)
        return false;
    zero = !memchr_inv(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    brelse(bh);
    return zero;
}

/*
 * 'mine' is an inode number the caller has just allocated and is about
 * to build in this block (mkdir), or 0. A '.' naming it is that number's
 * PREVIOUS life: the bit is ours, so whatever its slot still says -- a
 * record left by an earlier mkfs, or by a free that never cleared it --
 * is not a live owner. Refusing on it failed mkdir with EUCLEAN on a
 * re-made volume whose new directory got the old one's number and block.
 */
static int cetrafs_dirent_block_live_owner(struct super_block *sb, u64 lba, u64 mine)
{
    struct buffer_head *bh = (cetrafs_dirent_load_begin(), cetrafs_bread_uncached(sb, lba)); /* BL-51 */
    struct cetrafs_tw w = {.sb = sb, .read = CETRAFS_TW_SCRUB_FRESH};
    const cetrafs_dirent_t *d;
    cetrafs_extent_t *arr = NULL;
    cetrafs_inode_t r;
    u64 self;
    u32 n = 0, i;
    int ret = 0;

    cetrafs_dirent_load_end();
    if (!bh)
        return -EIO;
    d = (const cetrafs_dirent_t *) bh->b_data;
    if (!cetrafs_dirent_block_valid(bh) || cetrafs_le16(d[0].name_len) != 1 || d[0].name[0] != '.') {
        brelse(bh);
        return 0;
    }
    self = cetrafs_le64(d[0].inode);
    brelse(bh);

    if (!self || self == mine)
        return 0; /* names no inode at all, or the number we hold */
    cetrafs_invalidate_raw_inode(sb, self);
    /* A record that cannot be read decides nothing: answering "not
     * owned" here zeroed a live directory's block whenever its owner's
     * record had a read error or a tear (audit 2026-11-06 L1). Only a
     * never-written (all-zero) record is "no owner". */
    ret = cetrafs_read_raw_inode(sb, self, &r);
    if (ret == -EINVAL)
        return 0; /* past the inode table: names no inode at all */
    if (ret) {
        if (cetrafs_dirent_owner_slot_zero(sb, self))
            return 0;
        pr_err("dirent_block_init: block %llu names directory ino=%llu, whose record cannot be read (%d) -- "
               "not zeroing it, the block stays allocated\n",
               (unsigned long long) lba, (unsigned long long) self, ret);
        return -EIO;
    }
    if (!cetrafs_le32(r.nlink) || !S_ISDIR(cetrafs_le32(r.mode)))
        return 0;
    /* A live directory whose record checks but whose tree header does
     * not: what it lists cannot be read, so the block may be listed --
     * refused, never zeroed (class 36). */
    if (cetrafs_le16(r.eh.eh_magic) != CETRAFS_EXT_MAGIC) {
        pr_err("dirent_block_init: block %llu names LIVE directory ino=%llu, whose extent header is damaged -- "
               "not zeroing it, the block stays allocated (fsck)\n",
               (unsigned long long) lba, (unsigned long long) self);
        return -EUCLEAN;
    }

    /* Its tree at any depth, read fresh. A block of it that cannot be
     * read, or lies past a layout this node has not caught up with, is
     * not "names nothing": the block may be listed there, so it is not
     * zeroed (the answer leaks, never shares). */
    ret = cetrafs_tree_extents(&w, &r, &arr, &n);
    if (ret)
        return ret == -ENOMEM ? ret : -EIO;
    for (i = 0; i < n; i++) {
        u64 p = cetrafs_ee_pblk(&arr[i]);

        if (lba >= p && lba - p < cetrafs_ee_len(&arr[i])) {
            pr_err(
                "dirent_block_init: block %llu was allocated as free, but LIVE directory ino=%llu "
                "(nlink=%u) still lists it -- refusing to zero it, the block stays allocated (fsck)\n",
                (unsigned long long) lba, (unsigned long long) self, (unsigned int) cetrafs_le32(r.nlink));
            ret = -EUCLEAN;
            break;
        }
    }
    kvfree(arr);
    return ret;
}

/*
 * Returns -EUCLEAN when the block still belongs to a live directory, and
 * -EIO when that could not be decided: either way the block is left
 * untouched AND must stay allocated (*keep) -- the caller must not free
 * it. *keep false: the failure was the zeroing write's own, the block
 * is the caller's to give back. The bitmap read FREE for a block an extent references, and
 * keeping the bit set is the repair, in the safe direction: at worst a
 * block the scrub reclaims later, never one shared by two directories.
 */
int cetrafs_dirent_block_init(struct super_block *sb, u64 lba, bool *keep)
{
    struct buffer_head *bh;
    int ret;

    *keep = false;
    ret = cetrafs_dirent_block_live_owner(sb, lba, 0);
    if (ret) {
        *keep = true;
        return ret;
    }

    cetrafs_dirent_load_begin(); /* an install, as a load (BL-51) */
    bh = cetrafs_getblk_overwrite(sb, lba);
    if (!bh) {
        cetrafs_dirent_load_end();
        return -EIO;
    }
    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    cetrafs_dirent_block_stamp(bh);
    cetrafs_bh_end_update(sb, bh);
    cetrafs_dirent_load_end();
    ret = cetrafs_sync_new_buffer(sb, bh); /* on the device before its extent: a failure is the caller's */
    brelse(bh);
    return ret;
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
static struct buffer_head *cetrafs_dirent_read(struct inode *dir, u64 lba, bool fresh)
{
    struct buffer_head *bh;

    if (fresh)
        return cetrafs_dirent_bread(dir, lba);

    /* Cached only: a miss is a load from the device, and every load
     * goes through cetrafs_dirent_bread(), which counts it (BL-51). */
    bh = sb_find_get_block(dir->i_sb, lba);
    if (bh) {
        if (buffer_uptodate(bh) && cetrafs_dirent_block_valid(bh))
            return bh;
        brelse(bh);
    }
    return cetrafs_dirent_bread(dir, lba);
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
 * stamp used here is a nanosecond wall-clock reading xor'd with the node
 * id, so it is unique in PRACTICE, not by construction. Writes by two
 * different nodes can collide only if their clock readings and node ids
 * cancel out in the high byte. Two writes by one node repeat the value
 * only if its clock returns the same nanosecond twice, or steps
 * backwards. A repeat is the one case where a stale revert can carry the
 * reader's own stamp, and then the reader is served from cache.
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
 * tree a regular file uses, at any depth, and read through the same walk
 * (cetrafs_tree_extents()) -- only the freshness question is the
 * directory's own, see cetrafs_dir_extents_get_unchecked().
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
    cetrafs_extent_t *arr; /* every extent, by logical block: cetrafs_dir_extents_put() frees it */
    u32 entries;
};

/*
 * Every extent a directory names must lie in the data area before any of
 * its blocks is read or rewritten (rule 19). The regular-file path has
 * always asked (cetrafs_lba_run_is_data() at get_block); directories
 * only asked it of their depth-1 leaf address. The dirent tail check
 * would refuse a global-table block in practice, but that is a checksum
 * standing in for an address check -- and a dirent block's image copied
 * anywhere still carries a valid one. Arithmetic only, no I/O.
 */
/* TEST ONLY: an unlink decrements a directory's size with no floor, as
 * before audit 2026-11-14 N4 -- the control of tests/kernel/dir_size_floor.sh. */
static bool cetrafs_dir_size_no_floor;
cetrafs_test_param(dir_size_no_floor, cetrafs_dir_size_no_floor, bool, 0644);
MODULE_PARM_DESC(dir_size_no_floor, "TEST ONLY: an unlink may wrap a directory's size below zero");

/* TEST ONLY: no cap on a directory's blocks, as before audit 2026-11-14
 * RT-3 -- the control of tests/kernel/dir_extent_len_bound.sh. */
static bool cetrafs_dir_len_unbounded;
cetrafs_test_param(dir_len_unbounded, cetrafs_dir_len_unbounded, bool, 0644);
MODULE_PARM_DESC(dir_len_unbounded, "TEST ONLY: a directory's extents may name any number of blocks");

static int cetrafs_dir_extents_addr_ok(struct inode *dir, const struct cetrafs_dir_extents *de)
{
    u64 total = 0;
    u32 i;

    for (i = 0; i < de->entries; i++) {
        u64 phys = cetrafs_ee_pblk(&de->arr[i]);
        u32 len = cetrafs_ee_len(&de->arr[i]);
        int chk = cetrafs_lba_run_check(dir->i_sb, phys, len);

        /* A count, not only an address (rule 19): every scan of the
         * directory reads that many blocks forced-fresh under its
         * namespace lock, and an extent of 2^31 blocks inside the data
         * area passed the address check -- one create held the lock
         * for hours (audit 2026-11-14 RT-3). A directory never grows
         * past CETRAFS_DIR_MAX_BLOCKS (cetrafs_dir_add_entry()), so more
         * is damage. */
        total += len;
        if (total > CETRAFS_DIR_MAX_BLOCKS && !READ_ONCE(cetrafs_dir_len_unbounded)) {
            pr_err_ratelimited("dir ino=%llu: its extents name %llu blocks, more than a directory may hold (%u) -- "
                               "refusing them (fsck)\n",
                               (unsigned long long) dir->i_ino, (unsigned long long) total, CETRAFS_DIR_MAX_BLOCKS);
            cetrafs_sb_corrupt_inode(dir);
            return -EUCLEAN;
        }

        if (chk == -EAGAIN)
            return -EIO; /* past a layout this node cannot catch up with: not damage */
        if (chk) {
            pr_err_ratelimited("dir ino=%llu: extent %u names blocks %llu+%u outside the data area -- refusing it "
                               "(fsck)\n",
                               (unsigned long long) dir->i_ino, i, (unsigned long long) phys, len);
            cetrafs_sb_corrupt_inode(dir);
            return -EUCLEAN;
        }
    }
    return 0;
}

static void cetrafs_dir_extents_put(struct cetrafs_dir_extents *de);

static int cetrafs_dir_extents_get_unchecked(struct inode *dir, const cetrafs_inode_t *raw,
                                             struct cetrafs_dir_extents *de);

static int cetrafs_dir_extents_get(struct inode *dir, const cetrafs_inode_t *raw, struct cetrafs_dir_extents *de)
{
    int ret = cetrafs_dir_extents_get_unchecked(dir, raw, de);

    if (ret)
        return ret;
    ret = cetrafs_dir_extents_addr_ok(dir, de);
    if (ret)
        cetrafs_dir_extents_put(de);
    return ret;
}

static int cetrafs_dir_ext_cmp(const void *a, const void *b)
{
    u64 x = cetrafs_ee_lblk(a), y = cetrafs_ee_lblk(b);

    return x < y ? -1 : x > y;
}

static int cetrafs_dir_extents_get_unchecked(struct inode *dir, const cetrafs_inode_t *raw,
                                             struct cetrafs_dir_extents *de)
{
    de->arr = NULL;
    de->entries = 0;

    /*
     * A directory a peer removed (nlink 0) or whose number was reused
     * (new generation) has no blocks of its own any more: rmdir gave them
     * back, and the allocator may already have handed them to another
     * directory. Walking its old extents read that directory's entries --
     * and unlink, rename and the '..' update rewrote them, with neither
     * its namespace lock nor its dirent_seq. Only add_entry used to ask.
     * Asked here because every reader of a directory's extents comes
     * through, with a record it has just read fresh: lookup, readdir and
     * verify_name_resolves via the walk, and add, remove, retarget and
     * the '..' update directly. Costs no I/O.
     * tests/kernel/dir_removed_by_peer.sh.
     */
    if (cetrafs_le32(raw->nlink) == 0 || cetrafs_le64(raw->generation) != cetrafs_inode_get_generation(dir)) {
        pr_warn_ratelimited("dir ino=%llu is gone (nlink=%u, generation disk=%llu core=%llu) -- a peer removed or "
                            "replaced it; not reading its old blocks\n",
                            (unsigned long long) dir->i_ino, (unsigned int) cetrafs_le32(raw->nlink),
                            (unsigned long long) cetrafs_le64(raw->generation),
                            (unsigned long long) cetrafs_inode_get_generation(dir));
        return -ENOENT;
    }

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw->eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH) {
        pr_warn_ratelimited("dir ino=%llu: bad extent header (magic=0x%x depth=%u entries=%u)\n",
                            (unsigned long long) dir->i_ino, cetrafs_le16(raw->eh.eh_magic),
                            cetrafs_le16(raw->eh.eh_depth), cetrafs_le16(raw->eh.eh_entries));
        return -EIO;
    }

    /*
     * The tree lists which data blocks this directory owns, so a stale
     * block of it makes a scan walk the wrong set and miss a peer's
     * growth block: duplicate names, INVISIBLE entries. A file's tree
     * trusts its cache by its lock, and that question is wrong for a
     * directory -- under nofilelock it reads "no peer has this OPEN",
     * while peers change a directory through namespace ops without ever
     * opening it (328 of 401 mkdir()s duplicated in a 3-node run). So
     * the tree is read fresh exactly when the dirent_seq gate says the
     * directory changed cross-node -- the signal the dirent-block reads
     * use -- and a single writer's own directory stays cached.
     */
    {
        struct cetrafs_tw w = {
            .inode = dir,
            .read = cetrafs_dir_needs_fresh(dir, raw) ? CETRAFS_TW_FRESH : CETRAFS_TW_CACHED,
        };
        int ret = cetrafs_tree_extents(&w, raw, &de->arr, &de->entries);

        if (ret == -EUCLEAN) {
            /* More extents than a directory may hold (cetrafs_tree_extents()). */
            cetrafs_sb_corrupt_inode(dir);
            return ret;
        }
        if (ret) {
            pr_warn_ratelimited("dir ino=%llu: extent tree unreadable (%d)\n", (unsigned long long) dir->i_ino, ret);
            return ret == -ENOMEM ? ret : -EIO;
        }
    }
    /* By logical block: readdir resumes at a position, so it must meet
     * the blocks in position order, and a tree's arrays are unordered. */
    sort(de->arr, de->entries, sizeof(*de->arr), cetrafs_dir_ext_cmp, NULL);
    return 0;
}

static void cetrafs_dir_extents_put(struct cetrafs_dir_extents *de)
{
    kvfree(de->arr);
    de->arr = NULL;
    de->entries = 0;
}

/* Total data blocks this directory currently owns. */
static u64 cetrafs_dir_extents_nblocks(const struct cetrafs_dir_extents *de)
{
    u64 n = 0;
    u32 i;

    for (i = 0; i < de->entries; i++)
        n += cetrafs_ee_len(&de->arr[i]);
    return n;
}

typedef int (*cetrafs_dirent_visit_fn)(void *priv, const cetrafs_dirent_t *de, loff_t pos);

/*
 * min_pos: every entry below this position is of no interest to the
 * caller, so a block wholly below it is not even read. readdir resumes
 * at its last position on every getdents call, and walking -- reading
 * -- the whole directory from the top each time made listing a large
 * directory quadratic in device reads whenever it had changed on
 * another node (every read is forced fresh then).
 */
/* TEST ONLY: visit the live buffer instead of a validated copy, as
 * before audit 2026-11-14 RT-1 -- the control of tests/kernel/readdir_live_buffer.sh. */
static unsigned int cetrafs_dir_walk_stall_ms;
cetrafs_test_param(dir_walk_stall_ms, cetrafs_dir_walk_stall_ms, uint, 0644);
MODULE_PARM_DESC(dir_walk_stall_ms, "TEST ONLY: one walk pauses between reading a dirent block and visiting it");
static bool cetrafs_dir_walk_no_copy;
cetrafs_test_param(dir_walk_no_copy, cetrafs_dir_walk_no_copy, bool, 0644);
MODULE_PARM_DESC(dir_walk_no_copy, "TEST ONLY: readdir and lookup read the live dirent buffer");

/*
 * A fatal signal stops a directory scan (RT-3: its length is the disk's)
 * -- except inside an UNDO. A rename that already took a directory's old
 * name away gives it back through the same scans, and a SIGKILL there
 * left the directory with no name at all (it used to fail only on a
 * device error). The undo registers the task for its duration; a
 * forward scan stays killable. Looked up only once a fatal signal is
 * pending, so the scans pay nothing for it.
 */
static DEFINE_XARRAY(cetrafs_dir_undo_tasks);

static bool cetrafs_dir_killed(void)
{
    return fatal_signal_pending(current) && !xa_load(&cetrafs_dir_undo_tasks, (unsigned long) current);
}

static void cetrafs_dir_undo_begin(void)
{
    /* Cannot fail for want of memory in a way that matters: without the
     * entry the undo is merely killable again, as before the fix. */
    xa_store(&cetrafs_dir_undo_tasks, (unsigned long) current, current, GFP_NOFS);
}

static void cetrafs_dir_undo_end(void)
{
    xa_erase(&cetrafs_dir_undo_tasks, (unsigned long) current);
}

/* TEST ONLY: deliver the rename undo a pending SIGKILL check as before the
 * fix -- the control of tests/kernel/rename_undo_sigkill.sh. */
static bool cetrafs_rename_undo_killable;
cetrafs_test_param(rename_undo_killable, cetrafs_rename_undo_killable, bool, 0644);
MODULE_PARM_DESC(rename_undo_killable, "TEST ONLY: a SIGKILL also stops a rename's undo");

/* TEST ONLY: a stale directory is re-read block by block by each walk,
 * as before audit 2026-11-14 P6 -- the control of
 * tests/kernel/dir_refresh_whole.sh. */
static bool cetrafs_dir_refresh_whole_off;
cetrafs_test_param(dir_refresh_whole_off, cetrafs_dir_refresh_whole_off, bool, 0644);
MODULE_PARM_DESC(dir_refresh_whole_off, "TEST ONLY: a stale directory is re-read per walk, block by block");

/* Read every dirent block of 'dx' forced-fresh, in batches. */
static noinline_for_stack int cetrafs_dir_refresh_whole(struct inode *dir, const struct cetrafs_dir_extents *de)
{
    struct buffer_head *bhs[32];
    u32 i;

    for (i = 0; i < de->entries; i++) {
        u64 phys = cetrafs_ee_pblk(&de->arr[i]);
        u32 len = cetrafs_ee_len(&de->arr[i]), b, n, k;
        int rr;

        for (b = 0; b < len; b += n) {
            cond_resched();
            if (cetrafs_dir_killed())
                return -EINTR; /* RT-3: the count is the disk's */
            n = min_t(u32, len - b, ARRAY_SIZE(bhs));
            cetrafs_dirent_load_begin(); /* BL-51 */
            rr = cetrafs_bread_uncached_batch(dir->i_sb, phys + b, n, bhs);
            cetrafs_dirent_load_end();
            if (rr)
                return -EIO;
            for (k = 0; k < n; k++)
                brelse(bhs[k]);
        }
    }
    return 0;
}

/* TEST ONLY: a lockless walk does not ask whether its directory still
 * lives, as before audit 2026-11-15 BL-51 (tests/kernel/dir_walk_block_reused.sh). */
static bool cetrafs_dir_walk_no_alive;
cetrafs_test_param(dir_walk_no_alive, cetrafs_dir_walk_no_alive, bool, 0644);
MODULE_PARM_DESC(dir_walk_no_alive, "TEST ONLY: a lockless directory walk does not check the directory lives");

/* TEST ONLY: a lockless walk visits a block installed after its record
 * read without reading the record again -- the recheck alone off, the
 * record read's own check kept (tests/kernel/dir_walk_block_reused.sh). */
static bool cetrafs_dir_walk_no_recheck;
cetrafs_test_param(dir_walk_no_recheck, cetrafs_dir_walk_no_recheck, bool, 0644);
MODULE_PARM_DESC(dir_walk_no_recheck, "TEST ONLY: a lockless directory walk does not re-check the directory before a newly installed block");

/* TEST ONLY: a lockless walk pauses this long once, right after its
 * record read (tests/kernel/dir_walk_block_reused.sh). */
static unsigned int cetrafs_dir_walk_record_stall_ms;
cetrafs_test_param(dir_walk_record_stall_ms, cetrafs_dir_walk_record_stall_ms, uint, 0644);
MODULE_PARM_DESC(dir_walk_record_stall_ms, "TEST ONLY: one lockless directory walk pauses after its record read");

/* The directory, read fresh, is still the one walked and alive: 0,
 * -ENOENT if not, or the read's error. */
static noinline_for_stack int cetrafs_dir_walk_alive(struct inode *dir)
{
    cetrafs_inode_t *now = kmalloc(sizeof(*now), GFP_NOFS);
    int ret;

    if (!now)
        return -ENOMEM;
    cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, now);
    if (!ret && (cetrafs_le64(now->generation) != cetrafs_inode_get_generation(dir) || cetrafs_le32(now->nlink) == 0))
        ret = -ENOENT;
    kfree(now);
    return ret;
}

/*
 * 'lockless': the caller holds nothing a peer's rmdir takes (lookup,
 * revalidate, readdir). Its directory can then die, and a block of it be
 * freed and become another directory's, between the record read and a
 * block read -- or before the record read, with that other directory's
 * block already cached here: a valid dirent block, of the right kind,
 * with another directory's names, and an open for write of one of them
 * lands in an unrelated file (audit 2026-11-15 BL-51). So a lockless walk
 * answers -ENOENT for a directory that reads dead, and visits a block
 * installed in the cache after its record read only once the record,
 * read again after the copy was taken, still reads alive: a directory's
 * blocks are freed only once its death is published (rule 21), and
 * directories never shrink or move a block, so an alive record vouches
 * for every block installed before it was read. Locked walks (the
 * recount, rename's and rmdir's) keep their errors: their directory
 * cannot die under them, and a dead one met there is the caller's to
 * judge, not an ENOENT for an operation on another file.
 */
static int cetrafs_walk_dirents_from_x(struct inode *dir, cetrafs_dirent_visit_fn visit, void *priv, loff_t min_pos,
                                       bool lockless)
{
    unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    bool fresh, skipped = false;
    cetrafs_dirent_t *img;
    s64 loads;
    int ret;
    u32 i;

    bool stall = lockless && READ_ONCE(cetrafs_dir_walk_record_stall_ms);

    lockless = lockless && !READ_ONCE(cetrafs_dir_walk_no_alive);
    /* Before the record read: an install counted after this may postdate it. */
    loads = cetrafs_dirent_loads_snap();

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
    if (lockless &&
        (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(dir) || cetrafs_le32(raw.nlink) == 0))
        return -ENOENT; /* removed: its blocks may be anyone's now */
    if (unlikely(stall)) {
        unsigned int ms = xchg(&cetrafs_dir_walk_record_stall_ms, 0);

        if (ms) {
            pr_info("dir: ino=%llu: TEST pause of %ums after a lockless walk's record read\n",
                    (unsigned long long) dir->i_ino, ms);
            msleep(ms);
        }
    }

    /* Each block is visited as a private copy, re-validated: the buffer
     * the read validated can be re-read under us by a forced-fresh
     * reader in another thread, and a hostile image landing between the
     * validation and dir_emit() handed it a name_len of thousands -- up
     * to ~4 KiB of adjacent kernel memory copied to userspace (audit
     * 2026-11-14 RT-1). xattr.c copies its block for the same reason. */
    img = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOFS);
    if (!img)
        return -ENOMEM;
    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret) {
        kfree(img);
        return ret;
    }

    fresh = cetrafs_dir_needs_fresh(dir, &raw);

    /* Stale: refresh the WHOLE directory once, in batches, and re-arm
     * the stamp -- not only on a pass that ran to the end. A lookup
     * stops at its match and readdir when the buffer fills, so after a
     * peer changed one entry every stat re-read the directory from block
     * 0, one forced-fresh round trip per block: ~134k reads for `ls -l`
     * of 2000 files (audit 2026-11-14 P6). The blocks are read after the
     * record whose dirent_seq is stamped (rule 10); the walk below then
     * reads the cache, and its validation re-reads any torn block fresh. */
    if (fresh && !READ_ONCE(cetrafs_dir_refresh_whole_off)) {
        ret = cetrafs_dir_refresh_whole(dir, &dx);
        if (ret == -EINTR)
            goto out;
        if (!ret) {
            cetrafs_inode_set_dirent_seq_cached(dir, cetrafs_le64(raw.dirent_seq));
            fresh = false;
        }
        ret = 0;
    }

    for (i = 0; i < dx.entries; i++) {
        const cetrafs_extent_t *ext = &dx.arr[i];
        u64 phys = cetrafs_ee_pblk(ext);
        u32 len = cetrafs_ee_len(ext);
        u64 first = min_pos > 0 ? (u64) min_pos / CETRAFS_BLOCK_SIZE : 0; /* first block not wholly below min_pos */
        u32 b = 0;

        /*
         * Skip the blocks below min_pos by arithmetic, not one at a time.
         * The per-block skip ran before the cond_resched() below, so a
         * corrupt length (up to 2^31) and a user lseek() made it billions
         * of silent iterations with nothing to reschedule (class 13).
         * Same set as "skip while base_pos + BLOCK_SIZE <= min_pos".
         */
        if (first > cetrafs_ee_lblk(ext)) {
            u64 s = first - cetrafs_ee_lblk(ext);

            skipped = true;
            if (s >= len)
                continue;
            b = (u32) s;
        }

        for (; b < len; b++) {
            loff_t base_pos = ((loff_t) cetrafs_ee_lblk(ext) + b) * CETRAFS_BLOCK_SIZE;
            struct buffer_head *bh;
            const cetrafs_dirent_t *de;
            unsigned int e;

            bool live = READ_ONCE(cetrafs_dir_walk_no_copy); /* test-only: see the parameter */
            unsigned int tries;

            cond_resched(); /* O(blocks) per pass, whatever their content */
            if (cetrafs_dir_killed()) { /* RT-3: the count is the disk's */
                ret = -EINTR;
                goto out;
            }
            for (tries = 0;; tries++) {
                bh = cetrafs_dirent_read(dir, phys + b, fresh || tries);
                if (!bh) {
                    /* A directory removed under the walk is not an I/O error. */
                    ret = lockless && cetrafs_dir_walk_alive(dir) == -ENOENT ? -ENOENT : -EIO;
                    goto out;
                }
                if (live)
                    break;
                cetrafs_bh_snapshot(bh, img, CETRAFS_BLOCK_SIZE, 0, 0, false);
                brelse(bh);
                bh = NULL;
                if (cetrafs_blk_image_valid(img, CETRAFS_DIRENT_TAIL_MAGIC))
                    break;
                /* Re-read under us into something invalid: a write in
                 * flight converges, damage does not (rule 3). */
                if (tries >= 3) {
                    ret = lockless && cetrafs_dir_walk_alive(dir) == -ENOENT ? -ENOENT : -EUCLEAN;
                    goto out;
                }
                msleep(10 << tries);
            }

            if (unlikely(READ_ONCE(cetrafs_dir_walk_stall_ms)))
                msleep(xchg(&cetrafs_dir_walk_stall_ms, 0)); /* test-only, one-shot */
            /* Installed since the last time the record read alive: ask
             * again, now that the copy is taken (see above). */
            if (lockless && !READ_ONCE(cetrafs_dir_walk_no_recheck)) {
                s64 now;

                if (cetrafs_dirent_loads_moved(loads, &now)) {
                    ret = cetrafs_dir_walk_alive(dir);
                    if (ret) {
                        brelse(bh);
                        goto out;
                    }
                    loads = now;
                }
            }
            de = live ? (const cetrafs_dirent_t *) bh->b_data : img;
            for (e = 0; e < dirents_per_block; e++) {
                if (cetrafs_le64(de[e].inode) == 0)
                    continue;

                ret = visit(priv, &de[e], base_pos + e * sizeof(cetrafs_dirent_t));
                if (ret)
                    break;
            }
            brelse(bh); /* NULL unless live */
            if (ret > 0) {
                ret = 0;
                goto out;
            }
            if (ret < 0)
                goto out;
        }
    }

    /* A pass that read every block fresh and ran to completion has put
     * the whole directory in cache at exactly this sequence; note that,
     * so the next walk can stay cached until someone mutates it. A pass
     * that stopped early (found what it wanted, or errored) has NOT
     * refreshed every block, so it must not claim this -- and neither
     * has one that skipped blocks below min_pos. */
    if (fresh && !skipped)
        cetrafs_inode_set_dirent_seq_cached(dir, cetrafs_le64(raw.dirent_seq));
    ret = 0;
out:
    cetrafs_dir_extents_put(&dx);
    kfree(img);
    return ret;
}

static int cetrafs_walk_dirents(struct inode *dir, cetrafs_dirent_visit_fn visit, void *priv)
{
    return cetrafs_walk_dirents_from_x(dir, visit, priv, 0, false);
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

    return cetrafs_le64(de[idx].inode) == 0;
}

/* Does 'name' appear anywhere in this one dirent block? */
static bool cetrafs_dirent_block_has_name(const struct buffer_head *bh, const struct qstr *name)
{
    const cetrafs_dirent_t *de = (const cetrafs_dirent_t *) bh->b_data;
    unsigned int e;

    for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++) {
        if (cetrafs_le64(de[e].inode) == 0)
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
        u64 phys = cetrafs_ee_pblk(ext);
        u32 len = cetrafs_ee_len(ext);
        u32 b;

        for (b = 0; b < len; b++) {
            struct buffer_head *sbh;
            const cetrafs_dirent_t *de;
            unsigned int e;

            cond_resched();
            if (cetrafs_dir_killed())
                return -EINTR; /* RT-3: the count is the disk's */
            sbh = cetrafs_dirent_read(dir, phys + b, fresh);

            if (!sbh) {
                pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during add\n",
                                    (unsigned long long) dir->i_ino, (unsigned long long) (phys + b));
                return -EIO;
            }

            de = (const cetrafs_dirent_t *) sbh->b_data;
            for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++) {
                if (cetrafs_le64(de[e].inode) == 0) {
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
    u32 read_nlink;
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    struct buffer_head *bh = NULL;
    cetrafs_dirent_t *slot = NULL;
    u64 now;
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
        pr_warn_ratelimited("refusing to add '%*pE' to dir ino=%llu: it is gone (nlink=%u, generation disk=%llu core=%llu) -- a peer removed or replaced it\n",
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
        bh = cetrafs_dirent_read(dir, slot_lba, /*fresh=*/true);
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
        u64 next_logical = cetrafs_dir_extents_nblocks(&dx);

        cetrafs_dir_extents_put(&dx);
        /* The cap every reader enforces (cetrafs_dir_extents_addr_ok()). */
        /* Either limit names the directory in the log
         * (docs/internal/LIMITATIONS.md): an ENOSPC on a create in a
         * volume with free space is otherwise a mystery. */
        if (next_logical >= CETRAFS_DIR_MAX_BLOCKS) {
            pr_warn_ratelimited("dir ino=%llu is full: %u blocks, the most a directory may hold\n",
                                (unsigned long long) dir->i_ino, CETRAFS_DIR_MAX_BLOCKS);
            return -ENOSPC;
        }

        ret = cetrafs_inode_map_block(dir, next_logical, /*create=*/true, &new_lba);
        if (ret == -ENOSPC)
            pr_warn_ratelimited("dir ino=%llu cannot grow past %llu blocks: its extent tree is full or the volume "
                                "is out of space\n",
                                (unsigned long long) dir->i_ino, next_logical);
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
        cetrafs_dirent_load_begin(); /* may be a load (BL-51) */
        bh = cetrafs_bread_retry(dir->i_sb, new_lba);
        cetrafs_dirent_load_end();
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
    ret = cetrafs_journal_write_block(dir->i_sb, cetrafs_journal_owner_of(dir), bh, prev_crc);
    brelse(bh);
    if (ret)
        return ret; /* a grown block stays as a valid empty one -- see above */

    /* update dir's own metadata */
    now = cetrafs_now_disk();
    raw.size = cetrafs_cpu_to_le64(cetrafs_le64(raw.size) + (sizeof(cetrafs_dirent_t)));
    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb)); /* this directory's blocks just changed -- see cetrafs_dirent_read() */
    raw.mtime = cetrafs_cpu_to_le64(now);
    raw.ctime = cetrafs_cpu_to_le64(now);
    read_nlink = cetrafs_le32(raw.nlink);
    if (file_type == CETRAFS_FT_DIR)
        raw.nlink = cetrafs_cpu_to_le32(cetrafs_le32(raw.nlink) + 1);

    /* Staged rather than written: the namespace lock's release is a
     * compare-and-swap of this very record, so it can publish these
     * fields in the swap it was going to make anyway -- one device
     * round trip instead of two. See cetrafs_inode_stage_record(). */
    cetrafs_inode_stage_record(dir, &raw, /*fd_too=*/true, read_nlink);

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
    cetrafs_set_mtime_disk(dir, now);
    cetrafs_set_ctime_disk(dir, now);
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
/* TEST ONLY: the next unlink pauses between verifying its name and
 * removing it (ms, one-shot), so a name retargeted on the device in that
 * gap reaches cetrafs_dir_remove_entry() -- and remove_expect_off, the
 * control, lets that remove through.
 * tests/kernel/remove_names_locked_inode.sh. */
static unsigned int cetrafs_unlink_verify_stall_ms;
cetrafs_test_param(unlink_verify_stall_ms, cetrafs_unlink_verify_stall_ms, uint, 0644);
MODULE_PARM_DESC(unlink_verify_stall_ms, "TEST ONLY: pause the next unlink between its name check and its remove");
static bool cetrafs_remove_expect_off;
cetrafs_test_param(remove_expect_off, cetrafs_remove_expect_off, bool, 0644);
MODULE_PARM_DESC(remove_expect_off, "TEST ONLY: a dirent remove does not check it names the locked inode");

int cetrafs_dir_remove_entry(struct inode *dir, const struct qstr *name, u64 expect_ino, u64 *out_ino,
                             u8 *out_file_type)
{
    u32 read_nlink;
    unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
    struct cetrafs_dir_extents dx;
    cetrafs_inode_t raw;
    struct buffer_head *bh = NULL;
    cetrafs_dirent_t *slot = NULL;
    u64 now;
    bool fresh;
    int ret;
    u32 i;

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
        u64 phys = cetrafs_ee_pblk(ext);
        u32 len = cetrafs_ee_len(ext);
        u32 b;

        for (b = 0; b < len && !slot; b++) {
            cetrafs_dirent_t *de;
            unsigned int e;

            cond_resched();
            if (cetrafs_dir_killed()) { /* RT-3: the count is the disk's */
                cetrafs_dir_extents_put(&dx);
                return -EINTR;
            }
            bh = cetrafs_dirent_read(dir, phys + b, fresh);
            if (!bh) {
                pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during remove\n",
                                    (unsigned long long) dir->i_ino, (unsigned long long) (phys + b));
                cetrafs_dir_extents_put(&dx);
                return -EIO;
            }

            de = (cetrafs_dirent_t *) bh->b_data;
            for (e = 0; e < dirents_per_block; e++) {
                if (cetrafs_le64(de[e].inode) != 0 && cetrafs_le16(de[e].name_len) == name->len &&
                    !memcmp(de[e].name, name->name, name->len)) { /* the length just compared, not a re-read (RT-1) */
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

    /*
     * Only the name of the inode the caller holds the namespace lock of.
     * A name of X is added, removed or moved only under X's own lock,
     * and the online recount relies on it: it counts X's names across
     * the volume, and a count of 0 frees X (cetrafs_ns_count_names()).
     * Removing a name that resolved to some other inode -- unlocked --
     * broke that, and the callers then had a "mismatch branch" adjusting
     * a record they held no lock on. The caller verified the name under
     * the parent's lock, so this cannot happen; if it does, nothing is
     * written and the operation fails as a lost race.
     */
    if (cetrafs_le64(slot->inode) != expect_ino && !READ_ONCE(cetrafs_remove_expect_off)) {
        pr_warn_ratelimited("dir ino=%llu: '%.*s' names ino=%llu, not the locked ino=%llu -- refusing the remove\n",
                            (unsigned long long) dir->i_ino, (int) name->len, name->name,
                            (unsigned long long) cetrafs_le64(slot->inode), (unsigned long long) expect_ino);
        brelse(bh);
        return -ESTALE;
    }

    *out_ino = cetrafs_le64(slot->inode);
    *out_file_type = slot->file_type;
    ctrace("REMNAME dir=%llu name='%.*s' ino=%llu\n",
            (unsigned long long) dir->i_ino, (int) name->len, name->name, (unsigned long long) *out_ino);
    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
    memset(slot, 0, sizeof(*slot));

    cetrafs_dirent_block_stamp(bh);
    ret = cetrafs_journal_write_block(dir->i_sb, cetrafs_journal_owner_of(dir), bh, prev_crc);
    brelse(bh);
    if (ret)
        return ret;

    now = cetrafs_now_disk();
    /* Floored: a directory whose size was mis-counted -- a lost staged
     * publish, a peer's damage -- wrapped to 2^64 here and read back as
     * corrupt from then on (audit 2026-11-14 N4). A size below one entry
     * with an entry still in it is wrong already; say so, keep it at 0,
     * and let fsck recount it. */
    if (cetrafs_le64(raw.size) < sizeof(cetrafs_dirent_t) && !READ_ONCE(cetrafs_dir_size_no_floor)) {
        pr_warn_ratelimited("dir ino=%llu: size %llu is below the entry just removed -- holding it at 0 (fsck "
                            "recounts it)\n",
                            (unsigned long long) dir->i_ino, (unsigned long long) cetrafs_le64(raw.size));
        raw.size = cetrafs_cpu_to_le64(0);
    } else {
        raw.size = cetrafs_cpu_to_le64(cetrafs_le64(raw.size) - (sizeof(cetrafs_dirent_t)));
    }
    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb)); /* this directory's blocks just changed -- see cetrafs_dirent_read() */
    raw.mtime = cetrafs_cpu_to_le64(now);
    raw.ctime = cetrafs_cpu_to_le64(now);
    read_nlink = cetrafs_le32(raw.nlink);
    if (*out_file_type == CETRAFS_FT_DIR)
        raw.nlink = cetrafs_cpu_to_le32(cetrafs_le32(raw.nlink) - 1);

    /* Staged for the namespace lock's release -- see
     * cetrafs_dir_add_entry(). */
    cetrafs_inode_stage_record(dir, &raw, /*fd_too=*/true, read_nlink);

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
    cetrafs_set_mtime_disk(dir, now);
    cetrafs_set_ctime_disk(dir, now);
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
    int ret;
    u32 i;

    cetrafs_invalidate_raw_inode(dir->i_sb, dir->i_ino);
    ret = cetrafs_read_raw_inode(dir->i_sb, dir->i_ino, &raw);
    if (ret)
        return ret;

    ret = cetrafs_dir_extents_get(dir, &raw, &dx);
    if (ret)
        return ret;

    for (i = 0; i < dx.entries; i++) {
        const cetrafs_extent_t *ext = &dx.arr[i];
        u64 phys = cetrafs_ee_pblk(ext);
        u32 len = cetrafs_ee_len(ext);
        unsigned int dirents_per_block = CETRAFS_DIRENTS_PER_BLOCK;
        u32 b;

        for (b = 0; b < len; b++) {
            struct buffer_head *bh;
            cetrafs_dirent_t *de;
            unsigned int e;

            cond_resched();
            if (cetrafs_dir_killed()) { /* RT-3: the count is the disk's */
                cetrafs_dir_extents_put(&dx);
                return -EINTR;
            }
            bh = cetrafs_dirent_bread(dir, phys + b);
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
                    ret = cetrafs_journal_write_block(dir->i_sb, cetrafs_journal_owner_of(dir), bh, prev_crc);
                    brelse(bh);
                    cetrafs_dir_extents_put(&dx);
                    if (ret)
                        return ret;

                    /* This rewrote a dirent block, so the sequence has
                     * to move even though no entry was added or removed
                     * -- otherwise a peer whose cached seq still matches
                     * would go on serving the old '..' from its cache. */
                    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb));
                    ret = cetrafs_write_raw_inode_self(dir, &raw);
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
/* TEST ONLY: a rename-over retargets whatever the slot names, as before
 * audit 2026-11-14 N1 -- the control of tests/kernel/retarget_names_locked_inode.sh. */
static unsigned int cetrafs_rename_verify_stall_ms;
cetrafs_test_param(rename_verify_stall_ms, cetrafs_rename_verify_stall_ms, uint, 0644);
MODULE_PARM_DESC(rename_verify_stall_ms, "TEST ONLY: pause the next rename-over between its target check and its retarget");
static bool cetrafs_retarget_expect_off;
cetrafs_test_param(retarget_expect_off, cetrafs_retarget_expect_off, bool, 0644);
MODULE_PARM_DESC(retarget_expect_off, "TEST ONLY: a rename-over does not check the slot names the locked inode");

static int cetrafs_dir_retarget_entry(struct inode *dir,
                                      const struct qstr *name,
                                      u64 expect_ino,
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
    u64 now;
    int ret;
    u32 i;

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
        u64 phys = cetrafs_ee_pblk(ext);
        u32 len = cetrafs_ee_len(ext);
        u32 b;

        for (b = 0; b < len && !slot; b++) {
            cetrafs_dirent_t *de;
            unsigned int e;

            cond_resched();
            if (cetrafs_dir_killed()) { /* RT-3: the count is the disk's */
                cetrafs_dir_extents_put(&dx);
                return -EINTR;
            }
            /* A writer never uses the dirent cache -- see
             * cetrafs_dir_needs_fresh(). */
            bh = cetrafs_dirent_read(dir, phys + b, true);
            if (!bh) {
                pr_warn_ratelimited("dir ino=%llu: dirent block %llu unreadable during retarget\n",
                                    (unsigned long long) dir->i_ino, (unsigned long long) (phys + b));
                cetrafs_dir_extents_put(&dx);
                return -EIO;
            }

            de = (cetrafs_dirent_t *) bh->b_data;
            for (e = 0; e < dirents_per_block; e++) {
                if (cetrafs_le64(de[e].inode) != 0 && cetrafs_le16(de[e].name_len) == name->len &&
                    !memcmp(de[e].name, name->name, name->len)) { /* the length just compared, not a re-read (RT-1) */
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

    /* The name must still name the inode the rename locked, as for a
     * remove (cetrafs_dir_remove_entry()): the caller decrements the
     * count of whatever the slot named, and a slot naming another inode
     * would have it mutate a record it holds no lock on. Nothing is
     * written; the VFS retries the rename against what is there now
     * (audit 2026-11-14 N1). */
    if (cetrafs_le64(slot->inode) != expect_ino && !READ_ONCE(cetrafs_retarget_expect_off)) {
        pr_warn_ratelimited("dir ino=%llu: '%.*s' names ino=%llu, not the locked ino=%llu -- refusing the rename\n",
                            (unsigned long long) dir->i_ino, (int) name->len, name->name,
                            (unsigned long long) cetrafs_le64(slot->inode), (unsigned long long) expect_ino);
        brelse(bh);
        return -ESTALE;
    }

    *out_old_ino = cetrafs_le64(slot->inode);
    *out_old_file_type = slot->file_type;

    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
    slot->inode = cetrafs_cpu_to_le64(new_ino);
    slot->file_type = new_file_type;
    cetrafs_dirent_block_stamp(bh);
    ret = cetrafs_journal_write_block(dir->i_sb, cetrafs_journal_owner_of(dir), bh, prev_crc);
    brelse(bh);
    if (ret)
        return ret;

    now = cetrafs_now_disk();
    raw.dirent_seq = cetrafs_cpu_to_le64(cetrafs_dirent_seq_new(dir->i_sb)); /* this directory's blocks just changed */
    raw.mtime = cetrafs_cpu_to_le64(now);
    raw.ctime = cetrafs_cpu_to_le64(now);
    /* size and nlink unchanged: one entry became a different entry.
     *
     * A whole-record write from a fresh read, which rule 5 allows only
     * where nothing else writes the record meanwhile. For a directory
     * that holds: its namespace lock is ours, and the fields other
     * writers move WITHOUT it -- the file lock and read presence -- are
     * never set on a directory, because cetrafs_dir_ops has no .open,
     * .release, .flock or .lock (tests/image/source_invariants.sh,
     * "directory records"). In a same-directory rename the record
     * remove_entry staged is not read here: it is published at the
     * release, nlink as a delta against the device, so this write
     * reverts nothing of it (audit 2026-11-05, ruled out). */

    ctrace("RETGT dir=%llu name='%.*s' new_ino=%llu removed_ino=%llu\n",
            (unsigned long long) dir->i_ino, (int) name->len, name->name,
            (unsigned long long) new_ino, (unsigned long long) *out_old_ino);
    ret = cetrafs_write_raw_inode_self(dir, &raw);
    if (ret)
        return ret;

    /* Not claiming the dirent cache, for the same reason
     * cetrafs_dir_remove_entry() does not: the scan stopped at the
     * entry it came for, so the blocks past it were never refreshed. */
    cetrafs_set_mtime_disk(dir, now);
    cetrafs_set_ctime_disk(dir, now);
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

    if (cetrafs_le16(de->name_len) == ctx->name->len && !memcmp(de->name, ctx->name->name, ctx->name->len)) {
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
    int ret = cetrafs_read_gate(dir->i_sb);

    if (ret)
        return ERR_PTR(ret);

    fs_debug(info, "lookup '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    if (dentry->d_name.len > CETRAFS_FILENAME_MAX)
        return ERR_PTR(-ENAMETOOLONG);

    ret = cetrafs_walk_dirents_from_x(dir, cetrafs_lookup_visit, &ctx, 0, true); /* no lock: BL-51 */
    if (ret)
        return ERR_PTR(ret);

    if (ctx.ino) {
        inode = cetrafs_iget(dir->i_sb, ctx.ino);
        /* -ESTALE out of iget means one thing: the name points at a
         * record that says nlink=0 -- a file a peer has deleted while
         * this directory view still names it, or a dangling entry fsck
         * reports. The file does not exist; "Stale file handle" is an
         * NFS answer to a question nobody asked, and the VFS spends a
         * LOOKUP_REVAL retry on it first. iget has already logged it. */
        if (inode == ERR_PTR(-ESTALE))
            return ERR_PTR(-ENOENT);
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
/*
 * Test-only: make the next positive-dentry revalidation fail to
 * determine anything, as a device error reading the directory would.
 * The consequence of answering that with "invalid" -- the VFS
 * detaching the caller's mounts -- is not otherwise reachable on
 * demand.
 */
static bool cetrafs_revalidate_fail_once;
cetrafs_test_param(revalidate_fail_once, cetrafs_revalidate_fail_once, bool, 0644);
MODULE_PARM_DESC(revalidate_fail_once, "TEST ONLY: the next dentry revalidation cannot determine validity");

static int cetrafs_d_revalidate(struct inode *dir, const struct qstr *name, struct dentry *dentry, unsigned int flags)
{
    if (flags & LOOKUP_RCU)
        return -ECHILD; /* can't block in RCU-walk mode; make the VFS retry in ref-walk mode instead */

    if (d_really_is_positive(dentry)) {
        struct cetrafs_lookup_ctx ctx = {.name = name, .ino = 0};
        struct inode *inode = d_inode(dentry);
        int ret;

        /*
         * Two different answers live here and they must not be
         * conflated.
         *
         * "This name no longer resolves to this inode" is INVALID: 0,
         * and the VFS looks it up again.
         *
         * "I could not find out" -- a device error reading the dirents,
         * an allocation failure -- is an ERROR, and returning 0 for it
         * asserts something we do not know. The VFS answers a 0 with
         * d_invalidate(), which unhashes the dentry and DETACHES ANY
         * MOUNTS ON IT. A transient -EIO on one directory block would
         * therefore tear down a bind mount, permanently, and report
         * nothing. Propagating the errno leaves the mount alone and
         * lets the caller see what actually happened.
         */
        if (cetrafs_revalidate_fail_once) {
            cetrafs_revalidate_fail_once = false;
            return -EIO; /* test-only, see the knob */
        }

        ret = cetrafs_walk_dirents_from_x(dir, cetrafs_lookup_visit, &ctx, 0, true); /* no lock: BL-51 */
        if (ret == -ENOENT)
            return 0; /* the directory is gone: nothing in it is valid */
        if (ret)
            return ret; /* could not determine -- not the same as "invalid" */
        if (ctx.ino != inode->i_ino)
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
         * churn dentries for dirty inodes.
         *
         * Of its failures only -ESTALE means "this is a different file
         * now", which is genuinely invalid. -EUCLEAN and -EIO mean the
         * record could not be read or did not validate, and the honest
         * answer to the VFS is the errno, not an invalidation that
         * would take the caller's mounts with it. */
        ret = cetrafs_refresh_vfs_inode_if_newer(inode);
        if (ret == -ESTALE)
            return 0; /* same number, different FILE: genuinely invalid */
        if (ret)
            return ret; /* -EIO, -EUCLEAN, -ENOMEM: we could not tell */
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
    int ret = cetrafs_read_gate(file_inode(file)->i_sb);

    if (ret)
        return ret;
    return cetrafs_walk_dirents_from_x(file_inode(file), cetrafs_readdir_visit, &ctx, dctx->pos, true); /* BL-51 */
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
 * The mnt_idmap argument is honoured here, but cetrafs does NOT support
 * idmapped mounts: FS_ALLOW_IDMAP is not set (kmod.c), so the kernel
 * refuses to create one and 'idmap' is always nop_mnt_idmap today.
 * Setting that flag needs every setattr, getattr and permission path
 * audited for the idmap first, not just this one.
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

    /* The lock it was born holding goes first: the free below claims the
     * record, which a held lock refuses (cetrafs_new_record_locked()). */
    if (cetrafs_inode_ns_held_by_current(inode))
        cetrafs_nslock_release(inode);

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
        raw.nlink = cetrafs_cpu_to_le32(0);
        (void) cetrafs_write_raw_inode_self(inode, &raw);
    }

    /* The birth is over: it failed. Eviction frees the number through
     * cetrafs_free_inode_begin(), which refuses a number still in the
     * birth registry -- there that means "a create of this node took it
     * after the verdict", and a leftover entry of our own would make the
     * discard free nothing at all. Nothing else can be born on this
     * number meanwhile: its bit stays set until the free. */
    cetrafs_sb_birth_end(sb, inode->i_ino);
    clear_nlink(inode);
    iput(inode);
}

/*
 * A new record is written holding its own namespace lock, and keeps it
 * until its name lands (cetrafs_create_publish()). It used to be written
 * unlocked with its link count already 1: a node that stopped between
 * the record and the dirent left a file -- or an empty directory -- that
 * no name reaches, whose count says it is named, and that no lock or
 * flag marks, so nothing online ever reclaimed it (audit 2026-11-15
 * BM-29). Held, the stop leaves the lock of a stopped holder, and that
 * is a case every node already finishes: the scrub breaks it
 * (scrub_reconcile_stopped_op()) or this node's re-attach sweeps it
 * (cetrafs_lock_sweep_own_claims()), and the recount finds no name --
 * nlink 0, and its own eviction frees it. One swap more per create, the
 * release. A record this node cannot name itself the holder of (no node
 * id: nothing mounts that far without one) is written unlocked.
 */
static bool cetrafs_born_unlocked; /* TEST ONLY: see the parameter */
cetrafs_test_param(born_unlocked, cetrafs_born_unlocked, bool, 0644);
MODULE_PARM_DESC(born_unlocked, "TEST ONLY: new records are written unlocked, as before BM-29");

static void cetrafs_new_record_locked(struct super_block *sb, cetrafs_inode_t *raw)
{
    u32 me;

    raw->ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE); /* v0x000A: 0 is a real node id */
    if (READ_ONCE(cetrafs_born_unlocked) || cetrafs_sb_get_node_id(sb, &me))
        return;
    raw->ns_lock_owner = cetrafs_cpu_to_le32(me);
    raw->ns_lock_incarnation = cetrafs_cpu_to_le32(cetrafs_sb_incarnation(sb));
}

/*
 * A birth that failed after its record was written but before it had an
 * object to adopt the lock with (iget failed): the record goes back
 * dead and unlocked, then the number is freed (audit F-52). The free
 * zeroes nlink by a swap that leaves the lock alone, so the number went
 * back carrying this node's live lock and every allocator refused it
 * until this node's next mount swept it. Nothing else can touch the
 * record meanwhile: the number is ours by its birth claim and no name
 * reaches it. A rewrite the device refuses leaves it to that sweep, as
 * before -- a number leaked until the next mount, never shared.
 */
static bool cetrafs_born_unwind_off; /* TEST ONLY: see the parameter */
cetrafs_test_param(born_unwind_off, cetrafs_born_unwind_off, bool, 0644);
MODULE_PARM_DESC(born_unwind_off, "TEST ONLY: a failed birth frees its number still locked, as before F-52");

static void cetrafs_new_record_unwind(struct super_block *sb, u64 ino, const cetrafs_inode_t *raw)
{
    cetrafs_inode_t dead = *raw;

    if (cetrafs_le32(raw->ns_lock_owner) != CETRAFS_NODE_ID_NONE && !READ_ONCE(cetrafs_born_unwind_off)) {
        dead.nlink = cetrafs_cpu_to_le32(0);
        dead.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        dead.ns_lock_incarnation = cetrafs_cpu_to_le32(0);
        cetrafs_invalidate_raw_inode(sb, ino);
        if (cetrafs_write_raw_inode_new(sb, ino, &dead))
            pr_warn_ratelimited("%s: ino=%llu: a failed create could not unlock its record -- the number stays "
                                "out of use until this node's next mount\n",
                                sb->s_id, (unsigned long long) ino);
    }
    cetrafs_free_inode(sb, ino);
}

/* The in-core half of the lock a record was born holding, once its
 * object exists: what an acquire leaves (cetrafs_inode_ns_adopt()). */
static void cetrafs_new_inode_take_born_lock(struct inode *inode, const cetrafs_inode_t *raw)
{
    if (cetrafs_le32(raw->ns_lock_owner) != CETRAFS_NODE_ID_NONE)
        cetrafs_inode_ns_adopt(inode);
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
/* TEST ONLY: hold a create between its record and its name, so a suite
 * can copy the device as a crash there leaves it
 * (tests/kernel/create_stopped_unnamed.sh). */
static unsigned int cetrafs_create_name_stall_ms;
cetrafs_test_param(create_name_stall_ms, cetrafs_create_name_stall_ms, uint, 0644);
MODULE_PARM_DESC(create_name_stall_ms, "TEST ONLY: pause a create between its record write and its name");

static int cetrafs_create_publish(struct inode *dir, struct dentry *dentry, struct inode *inode)
{
    int ret = cetrafs_init_security(inode, dir, &dentry->d_name);

    if (ret)
        return ret;
    if (READ_ONCE(cetrafs_create_name_stall_ms))
        msleep(min_t(unsigned int, READ_ONCE(cetrafs_create_name_stall_ms), 30000));

    ret = cetrafs_dir_add_entry(dir, &dentry->d_name, inode->i_ino, cetrafs_dirent_type(inode));
    if (ret)
        return ret;
    /* Named: the lock it was born holding goes (cetrafs_new_record_locked()). */
    if (cetrafs_inode_ns_held_by_current(inode))
        cetrafs_nslock_release(inode);

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
    u64 now;
    int ret;

    fs_debug(info, "create '%.*s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) dir->i_ino);

    ret = cetrafs_alloc_inode(sb, &ino);
    if (ret)
        return ret;

    now = cetrafs_now_disk();
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
    raw.crtime = raw.ctime = raw.mtime = raw.atime = cetrafs_cpu_to_le64(now);
    raw.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    raw.generation = cetrafs_cpu_to_le64(cetrafs_inode_new_generation(sb)); /* v0x0008 reuse detector */
    cetrafs_new_record_locked(sb, &raw); /* held until its name lands (BM-29) */
    raw.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    raw.eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw.et.leaf));
    /* eh_entries = 0, eh_depth = 0: a fresh file has no data blocks yet */

    /* This node's copy of the number's previous life goes first. (It
     * once guarded a neighbour's record sharing the block; one record
     * per block since v0x0007, and the write below replaces the whole
     * block, so nothing of a cached copy reaches the device.) */
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_write_raw_inode_new(sb, ino, &raw);
    if (ret) {
        cetrafs_free_inode(sb, ino);
        return ret;
    }
    /* No mid-birth theft check here: cetrafs_alloc_inode()'s birth claim
     * made this record ours on the device, and a scrub's reclaim claim
     * cannot land on it -- see cetrafs_inode_birth_claim(). */

    /* Instantiate, label, and only then name it -- see
     * cetrafs_create_publish(). Nothing on these failure paths removes a
     * dirent, because none exists yet. */
    inode = cetrafs_iget(sb, ino);
    if (IS_ERR(inode)) {
        cetrafs_new_record_unwind(sb, ino, &raw);
        return PTR_ERR(inode);
    }
    cetrafs_new_inode_take_born_lock(inode, &raw);

    ret = cetrafs_create_publish(dir, dentry, inode);
    if (ret) {
        cetrafs_new_inode_discard(inode);
        return ret;
    }
    return 0;
}

/*
 * The namespace walks (cetrafs_ns_count_names(), cetrafs_dir_raw_visit())
 * read their blocks in batches of this many: one plugged submission and
 * one wait per batch, not one round trip per block (audit 2026-11-14 N2).
 * Every block of a batch is still read forced-fresh (ioutil.c's batch
 * helpers) and checked by the same validator as the single-block path.
 */
#define CETRAFS_NS_WALK_BATCH 64

/* TEST ONLY: the namespace walks read one block per round trip, as they
 * did before the batching (tests/kernel/ns_count_walk_reads.sh). */
static bool cetrafs_ns_count_serial;
cetrafs_test_param(ns_count_serial, cetrafs_ns_count_serial, bool, 0644);
MODULE_PARM_DESC(ns_count_serial, "TEST ONLY: the namespace recount reads one block per round trip");

struct cetrafs_dir_runs {
    /* One batch of dirent blocks, held between its read and its visit. */
    struct buffer_head *bh[CETRAFS_NS_WALK_BATCH];
};

/*
 * Read the n dirent blocks lba..lba+n into dr->bh[0..n) as one batch
 * (cetrafs_bread_uncached_batch(): forced-fresh, one wait per batch), each
 * checked by cetrafs_dirent_block_valid() -- the validator the single-block
 * path uses. A block the batch did not deliver, or delivered damaged, is
 * read again alone through cetrafs_dirent_bread_why(), which owns the retry
 * budget and the damage accounting. On failure every buffer is released and
 * dr->bh[] is left empty.
 */
static int cetrafs_dirent_batch_read(struct super_block *sb, const cetrafs_inode_t *raw, struct cetrafs_dir_runs *dr,
                                     u64 lba, u32 n)
{
    bool batched;

    cetrafs_dirent_load_begin(); /* BL-51: the batch; its per-block fallback brackets itself */
    batched = !READ_ONCE(cetrafs_ns_count_serial) && !cetrafs_bread_uncached_batch(sb, lba, n, dr->bh);
    cetrafs_dirent_load_end();
    int why = -EIO;
    u32 k;

    for (k = 0; k < n; k++) {
        if (batched && !cetrafs_tear_injected() && cetrafs_dirent_block_valid(dr->bh[k]))
            continue;
        if (batched)
            brelse(dr->bh[k]);
        dr->bh[k] = cetrafs_dirent_bread_why(sb, cetrafs_le64(raw->ino), cetrafs_le64(raw->generation), lba + k, &why);
        if (!dr->bh[k]) {
            for (k = 0; k < n; k++) {
                brelse(dr->bh[k]); /* NULL-safe */
                dr->bh[k] = NULL;
            }
            return why;
        }
    }
    return 0;
}

/* Read every dirent block of a directory record forced-fresh; visit each
 * occupied entry. The record was read fresh by the caller, and its tree
 * is read fresh here, at any depth: no inode is in hand, so through the
 * scrub's deciding read. */
static int cetrafs_dir_raw_visit(struct super_block *sb, const cetrafs_inode_t *raw, struct cetrafs_dir_runs *dr,
                                 void (*visit)(void *priv, const cetrafs_dirent_t *de), void *priv)
{
    struct cetrafs_tw w = {.sb = sb, .read = CETRAFS_TW_SCRUB_FRESH};
    cetrafs_extent_t *ext = NULL;
    u64 total = 0;
    u32 n = 0, i;
    int ret;

    memset(dr, 0, sizeof(*dr));
    ret = cetrafs_tree_extents(&w, raw, &ext, &n);
    if (ret)
        return ret;
    /* The count every other scan refuses (cetrafs_dir_extents_addr_ok(),
     * audit 2026-11-14 RT-3), and this one is a forced-fresh read per
     * block too: a record naming more is damage, not 2^31 reads (re-audit
     * of the fixes -- the signal check made it killable, not bounded). */
    for (i = 0; i < n; i++)
        total += cetrafs_ee_len(&ext[i]);
    if (total > CETRAFS_DIR_MAX_BLOCKS && !READ_ONCE(cetrafs_dir_len_unbounded)) {
        pr_err_ratelimited("dir record: its extents name %llu blocks, more than a directory may hold (%u) -- "
                           "not scanned (fsck)\n",
                           (unsigned long long) total, CETRAFS_DIR_MAX_BLOCKS);
        ret = -EUCLEAN;
        goto out;
    }
    for (i = 0; i < n; i++) {
        u64 lba = cetrafs_ee_pblk(&ext[i]);
        u32 len = cetrafs_ee_len(&ext[i]), b = 0;

        /* An address read off the disk aims a read here (rule 19), and
         * "not data" marks the record damaged -- unless it only lies past
         * a grow this node has not caught up with (class 48). */
        ret = cetrafs_lba_run_check(sb, lba, len);
        if (ret) /* -EAGAIN: past a grow not caught up with -- not damage, the caller catches up */
            goto out;
        while (b < len) {
            u32 nb = min_t(u32, CETRAFS_NS_WALK_BATCH, len - b);
            u32 k;

            /* -EUCLEAN only for a block every attempt found damaged */
            ret = cetrafs_dirent_batch_read(sb, raw, dr, lba + b, nb);
            if (ret)
                goto out;
            for (k = 0; k < nb; k++) {
                const cetrafs_dirent_t *de = (const cetrafs_dirent_t *) dr->bh[k]->b_data;
                unsigned int e;

                for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++)
                    if (cetrafs_le64(de[e].inode) != 0)
                        visit(priv, &de[e]);
                brelse(dr->bh[k]);
                dr->bh[k] = NULL;
            }
            b += nb;
            cond_resched();
            if (fatal_signal_pending(current)) {
                ret = -EINTR; /* N2: a directory's worth of reads, killable */
                goto out;
            }
        }
    }
    ret = 0;
out:
    kvfree(ext);
    return ret;
}

static bool cetrafs_dirent_is_dot(const cetrafs_dirent_t *de)
{
    u16 nl = cetrafs_le16(de->name_len);

    return (nl == 1 && de->name[0] == '.') || (nl == 2 && de->name[0] == '.' && de->name[1] == '.');
}

struct cetrafs_dir_tally {
    u64 slots, subdirs;
};

static void cetrafs_dir_tally_visit(void *priv, const cetrafs_dirent_t *de)
{
    struct cetrafs_dir_tally *t = priv;

    t->slots++;
    if (de->file_type == CETRAFS_FT_DIR && !cetrafs_dirent_is_dot(de))
        t->subdirs++;
}

struct cetrafs_name_tally {
    const u64 *inos;
    u32 *counts;
    u32 n;
};

static void cetrafs_name_tally_visit(void *priv, const cetrafs_dirent_t *de)
{
    struct cetrafs_name_tally *t = priv;
    u64 target = cetrafs_le64(de->inode);
    u32 i;

    if (cetrafs_dirent_is_dot(de))
        return;
    if (t->n > 8) {
        /* inos is ascending (cetrafs_ns_count_names()'s contract): one
         * search per entry, not a scan of up to 256 (the mount sweep). */
        u32 lo = 0, hi = t->n;

        while (lo < hi) {
            u32 mid = lo + (hi - lo) / 2;

            if (t->inos[mid] < target)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo < t->n && t->inos[lo] == target && t->counts[lo] < U32_MAX)
            t->counts[lo]++;
        return;
    }
    for (i = 0; i < t->n; i++)
        if (t->inos[i] == target && t->counts[i] < U32_MAX)
            t->counts[i]++;
}

/*
 * How many entries, in every directory on the volume, name each of
 * inos[0..n)? Every directory record and every dirent block is read
 * forced-fresh.
 *
 * The answer FREES (a count of 0 makes the file dead), so it must be
 * exact, and it is only while the caller holds the namespace lock of
 * every inode in the set. A name of X is added, removed or moved only
 * under X's own lock -- link and unlink lock the target, rename the moved
 * inode and the one it replaces -- so the set of entries naming X is
 * frozen for the whole walk, whichever directories are created, renamed
 * or removed meanwhile: a directory being created holds no name of X
 * unless X's lock allowed it, and one being removed is empty. A record or
 * block that cannot be read makes the answer unknown, and that is an
 * error: nothing may be decided from a count that skipped a directory.
 * O(directory blocks on the volume); paid only after a crash, once per
 * inode an operation stopped holding.
 */
/* One window of the inode scan: its allocated numbers, and their records
 * read as one batch (see cetrafs_ns_count_names()). */
struct cetrafs_ns_window {
    u64 ino[CETRAFS_NS_WALK_BATCH];
    sector_t blk[CETRAFS_NS_WALK_BATCH];
    struct buffer_head *bh[CETRAFS_NS_WALK_BATCH];
};

/*
 * Why the batched scan may read a record that was prefetched a window ago
 * (rule 1 asks for forced-fresh reads under a lock; this is one, and the
 * argument is what makes it safe here):
 *
 * - Every name of X is frozen for the walk: X's namespace lock is held, and
 *   an entry naming X is only added or removed under it. So which blocks
 *   hold an X-name cannot change while we read, and a block read at any
 *   moment of the walk shows the same X-names as one read at its start.
 * - A directory that holds an X-name cannot be created or removed during the
 *   walk (creating it would add a name of X; removing it needs it empty). A
 *   directory created after a window was read has no X-name, and one removed
 *   after it was read is caught by the fresh re-read below.
 * - A directory's blocks are read immediately after its own record is read
 *   fresh (cetrafs_dir_raw_visit() is given that record), so the verdict on
 *   the record is close to the act (rule 15).
 *
 * So the prefetch changes how many requests the scan makes, not what it
 * counts. ns_count_serial restores the one-read-per-record walk.
 *
 * Exact, because of the lock. A count of X's names is the number of entries
 * naming X across the volume; every directory is read, and every name
 * counted once. A block that cannot be read makes the answer unknown, and
 * that is an error: nothing may be decided from a count that skipped a
 * directory. O(the volume), paid only after a crash, once per inode an
 * operation stopped holding -- but in batches, so a volume costs its blocks
 * in round trips of CETRAFS_NS_WALK_BATCH, not one per inode.
 */
/* 'inos' must be ascending and without repeats when n > 8. */
/* TEST ONLY: the recount trusts the cached inode bitmap (B-22's control). */
static bool cetrafs_ns_count_cached_bmap;
cetrafs_test_param(ns_count_cached_bmap, cetrafs_ns_count_cached_bmap, bool, 0644);

/* TEST ONLY: a half-born record is unknown to the recount, as before
 * F-12 (tests/kernel/half_born_settled.sh). */
static bool cetrafs_ns_count_half_born_unknown;
cetrafs_test_param(ns_count_half_born_unknown, cetrafs_ns_count_half_born_unknown, bool, 0644);
MODULE_PARM_DESC(ns_count_half_born_unknown, "TEST ONLY: the namespace recount fails on a half-born record");

int cetrafs_ns_count_names(struct super_block *sb, const u64 *inos, u32 n, u32 *counts)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_name_tally t = {.inos = inos, .counts = counts, .n = n};
    struct cetrafs_dir_runs *dr;
    struct cetrafs_ns_window *win;
    cetrafs_inode_t *raw;
    bool serial = READ_ONCE(cetrafs_ns_count_serial);
    u64 ninodes, d;
    int ret = 0;

    if (!raw_sb)
        return -EINVAL;
    memset(counts, 0, n * sizeof(*counts));
    if (!n)
        return 0;
    raw = kmalloc(sizeof(*raw), GFP_NOFS);
    dr = kmalloc(sizeof(*dr), GFP_NOFS);
    win = kmalloc(sizeof(*win), GFP_NOFS);
    if (!raw || !dr || !win) {
        ret = -ENOMEM;
        goto out;
    }
    /*
     * The bound fresh, too: a directory in a segment a peer's grow added
     * since this node's last heartbeat is past cetrafs_sb_inodes(), and
     * the file it names would count 0 for the same reason (rule 6). A
     * layout that cannot be confirmed leaves the count unknown.
     */
    ret = cetrafs_sb_layout_refresh(sb);
    if (ret < 0)
        goto out;
    ret = 0;
    ninodes = cetrafs_sb_inodes(sb);
    /*
     * The inode bitmap fresh, first: it decides which records are walked
     * at all, and a cached block changes only on this node's own swaps.
     * A directory a peer created since was skipped, the file it names
     * counted 0, and 0 is the count that frees it -- the destructive
     * direction of staleness (rule 6; audit 2026-11-15 B-22). A handful
     * of blocks, under a lock already held; as the scrub's fresh pass.
     */
    if (!READ_ONCE(cetrafs_ns_count_cached_bmap))
        cetrafs_ibmap_invalidate(sb);
    for (d = 1; d <= ninodes; d += CETRAFS_NS_WALK_BATCH) {
        u64 end = min_t(u64, d + CETRAFS_NS_WALK_BATCH - 1, ninodes), x;
        u32 nw = 0, j;

        cond_resched();
        /* Killable: the count is unknown, so nothing is decided; the lock
         * stays stopped for the next taker (audit 2026-11-14 N2). */
        if (fatal_signal_pending(current)) {
            ret = -EINTR;
            goto out;
        }
        for (x = d; x <= end; x++) {
            bool allocated = false;

            ret = cetrafs_inode_is_allocated(sb, x, &allocated);
            if (ret)
                goto out;
            if (allocated)
                win->ino[nw++] = x;
        }
        if (!serial && nw) {
            /* The window's records, one batch: each forced-fresh, and the
             * reads below find them in the buffer cache (see above). */
            for (j = 0; j < nw; j++)
                win->blk[j] = cetrafs_inode_lba(sb, win->ino[j]);
            ret = cetrafs_bread_uncached_list(sb, win->blk, nw, win->bh);
            if (ret)
                goto out;
            for (j = 0; j < nw; j++) {
                brelse(win->bh[j]);
                win->bh[j] = NULL;
            }
        }
        for (j = 0; j < nw; j++) {
            x = win->ino[j];
            if (serial)
                cetrafs_invalidate_raw_inode(sb, x);
            ret = cetrafs_read_raw_inode_walk(sb, x, raw);
            if (ret == -ENODATA && cetrafs_walk_zero_owns_nothing_test()) {
                ret = 0;
                continue; /* TEST ONLY: names nothing, as F-7 had it */
            }
            /* Half-born: a create between its birth claim and its record
             * write, which settling left alone (its creator is live).
             * Not a directory yet, and nothing a live record reads back
             * as -- a checksummed namespace sector naming no file -- so
             * it names nothing. Unknown, it failed the recount of every
             * file while the create lasted, and for good if it never
             * finished (audit 2026-11-15 F-12). */
            if (ret == -ENODATA && (cetrafs_inode_half_born(raw, x) || cetrafs_inode_half_landed(raw, x)) &&
                !READ_ONCE(cetrafs_ns_count_half_born_unknown)) {
                ret = 0;
                continue;
            }
            /* -ENODATA: never written, or a directory's record read back
             * as zeros -- the same bytes, and a count that skipped it
             * could publish nlink 0 for a file named only there (review
             * F-11). No count, so nothing is published. */
            if (ret)
                goto out;
            /* A removed directory is empty, and its blocks may be anyone's. */
            if (!S_ISDIR(cetrafs_le32(raw->mode)) || cetrafs_le32(raw->nlink) == 0)
                continue;
            if (!serial) {
                /* The verdict above may be a window old: re-read the record
                 * now, the read a directory's blocks are about to follow. */
                cetrafs_invalidate_raw_inode(sb, x);
                ret = cetrafs_read_raw_inode(sb, x, raw);
                if (ret)
                    goto out;
                if (!S_ISDIR(cetrafs_le32(raw->mode)) || cetrafs_le32(raw->nlink) == 0)
                    continue;
            }
            ret = cetrafs_dir_raw_visit(sb, raw, dr, cetrafs_name_tally_visit, &t);
            if (ret)
                goto out;
        }
    }
out:
    kfree(win);
    kfree(dr);
    kfree(raw);
    return ret;
}

static void cetrafs_ns_apply_set_nlink(cetrafs_inode_t *rec, void *arg)
{
    rec->nlink = cetrafs_cpu_to_le32(*(const u32 *) arg);
}

/* Publish a recounted link count; 'self' follows it. */
int cetrafs_ns_publish_nlink(struct super_block *sb, u64 ino, u64 generation, const cetrafs_inode_t *seed,
                             u32 want, struct inode *self)
{
    int ret = cetrafs_inode_ns_cas(sb, ino, generation, seed, cetrafs_ns_apply_set_nlink, &want);

    if (!ret && self)
        set_nlink(self, want);
    return ret;
}

static atomic64_t cetrafs_ns_recounts = ATOMIC64_INIT(0);
u64 cetrafs_ns_recounts_count(void)
{
    return (u64) atomic64_read(&cetrafs_ns_recounts);
}

/*
 * Recount an inode whose namespace lock was taken over from a holder
 * that stopped inside an operation.
 *
 * Every namespace operation writes its entry first -- journaled, synced
 * (cetrafs_dir_add_entry(), cetrafs_dir_remove_entry()) -- and publishes
 * the counts that describe it only in the swap that releases each lock
 * (cetrafs_nslock_release()): a directory's size and, for a
 * subdirectory, its nlink; an unlinked or renamed-over file's nlink. A
 * node that stops between the two leaves the entries ahead of their
 * counts, and the locks still set. The crash census found the directory
 * half at a third of its cuts (tests/crash/crash_residue.sh); the file
 * half is an unlinked file whose name is gone and whose nlink still says
 * 1 -- unreachable, holding its blocks. Nothing re-derived either: every
 * later operation adjusts the value it reads, so they stayed until an
 * offline fsck -r -- and a parent's nlink left low by two interrupted
 * mkdirs reaches 0 once its subdirectories go, and the directory then
 * reads as removed (cetrafs_dir_add_entry()'s "is it still THERE?").
 *
 * The set lock is the signal and covers every such stop: a count is
 * behind its entries only between an entry write and its release, and
 * the lock is held across exactly that. Whoever takes it over calls this
 * holding it: this node taking a lock back or a peer breaking a dead
 * holder's (cetrafs_nslock_try()), this node re-attached after a crash
 * (cetrafs_lock_sweep_own_claims()), the scrub for a file no name
 * reaches any more (scrub_reconcile_stopped_ops()).
 *
 * Exact, because of the lock. A directory: its entries, size and nlink
 * change only under it, so the blocks read here are the ones the counts
 * describe; the values are fsck's (one slot per occupied entry, '.' and
 * '..' included; 2 plus one per subdirectory, by the entry's file_type
 * as the operations count them -- fsck uses the target's mode, which
 * differs only on a wrong type byte it reports on its own). nlink never
 * comes out below 2, so a live directory cannot read as removed. A
 * file: its names, counted across the volume (cetrafs_ns_count_names()).
 * A count of 0 makes it dead, which is what the stopped unlink meant.
 *
 * 'self' is the in-core object when there is one (brought to the new
 * values, the fd publish ordered by its fd_pub_mutex); NULL otherwise.
 * Returns 0, -ESTALE if the number now names a different object, or an
 * error with nothing published: -EUCLEAN only when THIS record or one of
 * its own blocks is damaged, -EAGAIN when a block lies past a grow this
 * node has not caught up with, anything else for what may pass.
 */
/* TEST ONLY: the next N recounts fail as if out of memory, whoever calls
 * them (tests/kernel/ns_recount_fail_retry.sh). */
static unsigned int cetrafs_nslock_recount_fail;
cetrafs_test_param(nslock_recount_fail, cetrafs_nslock_recount_fail, uint, 0644);
MODULE_PARM_DESC(nslock_recount_fail, "TEST ONLY: fail the next N namespace recounts with -ENOMEM");

int cetrafs_ns_reconcile(struct super_block *sb, u64 ino, u64 generation, struct inode *self)
{
    return cetrafs_ns_reconcile_counted(sb, ino, generation, self, NULL);
}

/*
 * cetrafs_ns_reconcile(), with a file's names already counted by the
 * caller in one walk shared with other files (the mount sweep of this
 * node's stopped claims, cetrafs_lock_sweep_own_claims()). 'counted' is
 * exact only if the caller held the file's namespace lock from before
 * that walk until now, so no name of it could change; NULL counts here.
 * A directory counts its own blocks either way.
 */
int cetrafs_ns_reconcile_counted(struct super_block *sb, u64 ino, u64 generation, struct inode *self,
                                 const u32 *counted)
{
    struct cetrafs_dir_tally tally = {0};
    struct cetrafs_dir_runs *dr = NULL;
    cetrafs_inode_t *raw;
    u64 want_size;
    u32 want_nlink;
    int ret;
    unsigned int n = READ_ONCE(cetrafs_nslock_recount_fail);

    if (n && cmpxchg(&cetrafs_nslock_recount_fail, n, n - 1) == n)
        return -ENOMEM; /* test-only, see the knob */

    raw = kmalloc(sizeof(*raw), GFP_NOFS);
    if (!raw)
        return -ENOMEM;
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_read_raw_inode(sb, ino, raw);
    if (ret)
        goto out;
    if (cetrafs_le64(raw->generation) != generation) {
        ret = -ESTALE;
        goto out;
    }
    /* Already dead -- an unlink that published, a removed directory, an
     * evict's free claim: the free path's, not a count to correct. */
    if (cetrafs_le32(raw->nlink) == 0)
        goto out;

    if (!S_ISDIR(cetrafs_le32(raw->mode))) {
        u32 names = counted ? *counted : 0;

        ret = counted ? 0 : cetrafs_ns_count_names(sb, &ino, 1, &names);
        if (ret == -EUCLEAN)
            ret = -EIO; /* damage in some directory read for the count is not this file's */
        if (ret || names == cetrafs_le32(raw->nlink))
            goto out;
        pr_warn("ino=%llu: recounted after an operation that stopped holding its lock: nlink %u -> %u\n",
                (unsigned long long) ino, cetrafs_le32(raw->nlink), names);
        ret = cetrafs_ns_publish_nlink(sb, ino, generation, raw, names, self);
        if (!ret)
            atomic64_inc(&cetrafs_ns_recounts);
        goto out;
    }

    dr = kmalloc(sizeof(*dr), GFP_NOFS);
    if (!dr) {
        ret = -ENOMEM;
        goto out;
    }
    ret = cetrafs_dir_raw_visit(sb, raw, dr, cetrafs_dir_tally_visit, &tally);
    if (ret)
        goto out;
    want_size = tally.slots * sizeof(cetrafs_dirent_t);
    want_nlink = (u32) min_t(u64, tally.subdirs + 2, U32_MAX);
    /* An EMPTY directory no name reaches: a mkdir that stopped between
     * its record and its entry (BM-29), the lock it was born holding
     * still set. Dead, as an unnamed file is -- its eviction frees it.
     * Only empty: one with children is somebody's tree, left whole for
     * fsck -r to put in lost+found. The names are counted across the
     * volume, which only an empty directory taken over from a stopped
     * holder pays. */
    if (tally.slots == 2 && !tally.subdirs && ino != 1 /* the root */ && !READ_ONCE(cetrafs_born_unlocked)) {
        u32 names = 0;

        ret = cetrafs_ns_count_names(sb, &ino, 1, &names);
        if (ret == -EUCLEAN)
            ret = -EIO; /* damage in some directory read for the count is not this one's */
        if (ret)
            goto out;
        if (!names) {
            pr_warn("dir ino=%llu: empty and named nowhere after an operation that stopped holding its lock -- "
                    "removed\n",
                    (unsigned long long) ino);
            ret = cetrafs_ns_publish_nlink(sb, ino, generation, raw, 0, self);
            if (!ret)
                atomic64_inc(&cetrafs_ns_recounts);
            goto out;
        }
    }
    if (cetrafs_le64(raw->size) == want_size && cetrafs_le32(raw->nlink) == want_nlink)
        goto out; /* the operation that stopped had published, or changed nothing */

    pr_warn("dir ino=%llu: recounted after an operation that stopped holding its lock: size %llu -> %llu, "
            "nlink %u -> %u\n",
            (unsigned long long) ino, (unsigned long long) cetrafs_le64(raw->size), (unsigned long long) want_size,
            cetrafs_le32(raw->nlink), want_nlink);
    if (cetrafs_le64(raw->size) != want_size) {
        /* The file sector, fed the fresh read above; its other fields
         * are the directory's and change only under the lock we hold. */
        raw->size = cetrafs_cpu_to_le64(want_size);
        if (self)
            cetrafs_inode_fd_pub_lock(self);
        ret = cetrafs_write_raw_inode_fd(sb, ino, raw, self, NULL);
        if (self) {
            if (!ret)
                i_size_write(self, want_size);
            cetrafs_inode_fd_pub_unlock(self);
        }
        if (ret)
            goto out;
    }
    /* Absolute, which nlink otherwise never is: a directory's nlink
     * changes only under its own lock, and this is the count. */
    if (cetrafs_le32(raw->nlink) != want_nlink)
        ret = cetrafs_ns_publish_nlink(sb, ino, generation, raw, want_nlink, self);
    if (!ret)
        atomic64_inc(&cetrafs_ns_recounts);
out:
    kfree(dr);
    kfree(raw);
    return ret;
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
    if (!ret || ret == -ENOENT || ret == -EEXIST || ret == -ENOTEMPTY || ret == -ENOTDIR || ret == -EISDIR ||
        ret == -ERESTARTNOINTR)
        return; /* ordinary, expected answers -- not failures (a restart waits out a peer's lock) */
    pr_warn_ratelimited("%s '%*pE' in dir ino=%llu failed: %d\n", op, name ? (int) name->len : 0,
                        name ? (const char *) name->name : "", (unsigned long long) dir->i_ino, ret);
}

/* TEST ONLY: stall a create between the VFS's lookup and the namespace
 * lock, so a suite can land a "peer's" name there. */
static unsigned int cetrafs_create_prelock_stall_ms;
cetrafs_test_param(create_prelock_stall_ms, cetrafs_create_prelock_stall_ms, uint, 0644);
MODULE_PARM_DESC(create_prelock_stall_ms, "TEST ONLY: widen the window between a create's lookup and its namespace lock");

static int cetrafs_create(struct mnt_idmap *idmap, struct inode *dir, struct dentry *dentry, umode_t mode, bool excl)
{
    /* Only the parent: the child's record is freshly allocated, and its
     * inode-bitmap bit was claimed by an atomic CAS, so no other node
     * can be looking at it yet. */
    struct inode *set[] = {dir};
    int ret;

    if (cetrafs_create_prelock_stall_ms)
        msleep(cetrafs_create_prelock_stall_ms);
    ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));
    if (ret) {
        cetrafs_ns_report("create (lock)", dir, &dentry->d_name, ret);
        return ret;
    }

    ret = cetrafs_create_locked(idmap, dir, dentry, mode, excl);
    cetrafs_ns_report("create", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));

    /*
     * The VFS looked the name up negative before this call reached the
     * namespace lock, and a peer may have created it in between. For
     * O_EXCL (and mknod) EEXIST is the answer. For a plain O_CREAT it
     * is not one open(2) may give: the file exists, so the open should
     * open it -- the lesson rename learned (see cetrafs_rename()), here
     * for create (audit 2026-11-05, N4). -ESTALE makes do_filp_open()
     * walk again with LOOKUP_REVAL; our negative dentry never survives
     * d_revalidate, so that walk looks the name up fresh, finds the
     * peer's file and opens it with the ordinary permission checks and
     * O_TRUNC. A second lost race in a row returns ESTALE.
     * tests/kernel/create_race_opens_peer_file.sh.
     */
    if (ret == -EEXIST && !excl)
        ret = -ESTALE;
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
    u64 now;
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

    /* The same guard a growing directory's block gets: if the allocator
     * handed out a block a live directory still lists, or one whose
     * owner cannot be read, it stays allocated and untouched (audit
     * 2026-11-06 L1 -- mkdir overwrote it unchecked). */
    ret = cetrafs_dirent_block_live_owner(sb, lba, ino);
    if (ret) {
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(ret);
    }
    /* Claimed without reading: every byte is overwritten below. An
     * install, as a load (BL-51), until its update ends. */
    cetrafs_dirent_load_begin();
    bh = cetrafs_getblk_overwrite(sb, lba);
    if (!bh) {
        cetrafs_dirent_load_end();
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
    cetrafs_bh_end_update(sb, bh);
    cetrafs_dirent_load_end();
    ret = cetrafs_sync_new_buffer(sb, bh); /* nothing names it yet: a full thin pool is ENOSPC */
    brelse(bh);
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(ret);
    }

    now = cetrafs_now_disk();
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
    cetrafs_new_record_locked(sb, &raw); /* held until its name lands (BM-29) */
    raw.size = cetrafs_cpu_to_le64(sizeof(cetrafs_dirent_t) * 2);
    raw.blocks = cetrafs_cpu_to_le64(CETRAFS_BLOCK_SIZE / 512);
    raw.crtime = raw.ctime = raw.mtime = raw.atime = cetrafs_cpu_to_le64(now);
    raw.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    raw.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    raw.eh.eh_entries = cetrafs_cpu_to_le16(1);
    raw.eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw.et.leaf));
    cetrafs_ee_set_lblk(&raw.et.leaf[0], 0);
    cetrafs_ee_set_len(&raw.et.leaf[0], 1, 0);
    cetrafs_ee_set_pblk(&raw.et.leaf[0], lba);

    /* As cetrafs_create_locked(): the previous life's copy goes first. */
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_write_raw_inode_new(sb, ino, &raw);
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        cetrafs_free_inode(sb, ino);
        return ERR_PTR(ret);
    }
    /* No mid-birth theft check here: cetrafs_alloc_inode()'s birth claim
     * made this record ours on the device, and a scrub's reclaim claim
     * cannot land on it -- see cetrafs_inode_birth_claim(). */

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
        cetrafs_new_record_unwind(sb, ino, &raw);
        return ERR_CAST(inode);
    }
    cetrafs_new_inode_take_born_lock(inode, &raw);

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
    int ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));

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
                "'%*pE' in dir ino=%llu still names ino=%llu, but that is a DIFFERENT file now "
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
    u64 gen;            /* nonzero: only on this generation (cetrafs_rename_ns_delta()) */
};

static void cetrafs_ns_apply_delta(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_ns_delta *d = arg;
    long live = (long) cetrafs_le32(rec->nlink) + d->nlink_delta;

    if (live < 0)
        live = 0;
    /* Saturate, never wrap: 2^32 links stored as (u32) read as 0 -- a
     * dead inode, freed with its names still pointing at it. Peers add
     * links without seeing each other's in-core count, so the VFS's
     * s_max_links check alone cannot promise this (audit 2026-11-05,
     * section 3; tests/kernel/nlink_saturates.sh). A count stuck high
     * leaks; one that wrapped would free. */
    if (live > U32_MAX)
        live = U32_MAX;
    if (d->set_nlink_zero)
        live = 0;
    rec->nlink = cetrafs_cpu_to_le32((u32) live);
    if (d->ctime)
        rec->ctime = cetrafs_cpu_to_le64(d->ctime);
    d->out_nlink = (u32) live;
}

static int cetrafs_unlink_locked(struct inode *dir, struct dentry *dentry)
{
    u32 read_nlink;
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
    if (READ_ONCE(cetrafs_unlink_verify_stall_ms)) {
        unsigned int pause = xchg(&cetrafs_unlink_verify_stall_ms, 0);

        if (pause) {
            pr_info("unlink: name verified, pausing %u ms (test)\n", pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }

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

        /* A wait it would do -- a dead holder's fence and replay, a
         * mover asked back -- outside the directory's locks (BM-27):
         * nothing is changed yet. */
        if (cetrafs_lock_foreign_user_would_wait(inode, my_node_id) && !cetrafs_nslock_defer_settle(inode))
            return -ERESTARTNOINTR;
        ret = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, NULL, NULL);
        if (ret)
            return ret;
        if (blocked || reader)
            return -ETXTBSY;
    }

    ret = cetrafs_dir_remove_entry(dir, &dentry->d_name, inode->i_ino, &ino, &file_type);
    if (ret)
        return ret;

    /*
     * The entry named the inode we verified and locked
     * (cetrafs_dir_remove_entry() refuses any other), so `raw` is
     * already this inode's record, read fresh a few lines up, and
     * nothing can have changed it since: this node holds that inode's
     * OWN namespace lock, so no peer may touch it, and
     * cetrafs_dir_remove_entry() writes the parent's dirent block and
     * the parent's record, never the victim's.
     */

    read_nlink = cetrafs_le32(raw.nlink);
    if (cetrafs_le32(raw.nlink) > 0)
        raw.nlink = cetrafs_cpu_to_le32(cetrafs_le32(raw.nlink) - 1);
    /* POSIX: removing a link updates the inode's ctime. This was set on
     * the in-core object a few lines below and never on the record, so
     * a surviving hardlink's ctime was whatever it had been before. */
    raw.ctime = cetrafs_cpu_to_le64(cetrafs_now_disk());

    /* Persist nlink (possibly now 0) but never free blocks/the inode
     * number here -- see super_ops.c's cetrafs_evict_inode() for why
     * that's deferred to actual VFS eviction, not this nlink-drops-to-0
     * moment.
     *
     * Staged for the namespace lock's release. */
    cetrafs_inode_stage_record(inode, &raw, /*fd_too=*/false, read_nlink);

    /* Sync the in-core link count to the ABSOLUTE value just computed
     * from the forced-fresh on-disk read -- not a relative drop_nlink()
     * from this node's cached count. nlink is a cross-node accumulator:
     * a peer that added or removed another name of this inode since we
     * cached it left our i_nlink stale, and decrementing a stale count
     * gives a stale result. That matters because evict_inode() gates the
     * actual free on inode->i_nlink: a last unlink that computes disk
     * nlink=0 but drops a stale-high cached count to 1 leaves the file
     * with no names yet UNFREED -- "allocated but no directory entry --
     * unreachable" on a 3-node run ([create,link,unlink]). */
    set_nlink(inode, cetrafs_le32(raw.nlink));
    cetrafs_set_ctime_disk(inode, cetrafs_le64(raw.ctime));

    return 0;
}

static int cetrafs_unlink(struct inode *dir, struct dentry *dentry)
{
    /* Parent and victim both: the victim's nlink is mutated too, and another node can reach
     * that same inode through a different hardlink's parent. */
    struct inode *set[] = {dir, d_inode(dentry)};
    int ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));

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
/* TEST ONLY: fail rmdir's next read of the victim's record, as a device
 * error would (tests/kernel/rmdir_read_error.sh). */
static bool cetrafs_rmdir_victim_read_fail;
cetrafs_test_param(rmdir_victim_read_fail, cetrafs_rmdir_victim_read_fail, bool, 0644);
MODULE_PARM_DESC(rmdir_victim_read_fail, "TEST ONLY: fail rmdir's next read of the victim's record with -EIO");

static int cetrafs_rmdir_read_victim(struct super_block *sb, u64 ino, cetrafs_inode_t *raw)
{
    if (READ_ONCE(cetrafs_rmdir_victim_read_fail) && xchg(&cetrafs_rmdir_victim_read_fail, false))
        return -EIO; /* test-only; see the parameter */
    cetrafs_invalidate_raw_inode(sb, ino);
    return cetrafs_read_raw_inode(sb, ino, raw);
}

static int cetrafs_rmdir_locked(struct inode *dir, struct dentry *dentry)
{
    u32 read_nlink;
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


    /* The victim's record BEFORE its name goes: read after, a read
     * error returned EIO with the directory already unnamed -- gone
     * from the namespace, nlink still 2, reachable by nobody (audit
     * L4). The name was verified to resolve to this inode above. */
    ret = cetrafs_rmdir_read_victim(dir->i_sb, inode->i_ino, &raw);
    if (ret)
        return ret;

    ret = cetrafs_dir_remove_entry(dir, &dentry->d_name, inode->i_ino, &ino, &file_type);
    if (ret)
        return ret;

    /* Persist nlink=0 but never free blocks/the inode number here -- see
     * super_ops.c's cetrafs_evict_inode() for why that's deferred to
     * actual VFS eviction, not this point. Staged for the namespace
     * lock's release (the entry named the locked inode:
     * cetrafs_dir_remove_entry() refuses any other). */
    read_nlink = cetrafs_le32(raw.nlink);
    raw.nlink = cetrafs_cpu_to_le32(0);
    cetrafs_inode_stage_record(inode, &raw, /*fd_too=*/false, read_nlink);

    clear_nlink(inode);
    cetrafs_set_ctime_disk(inode, cetrafs_now_disk());

    return 0;
}

static int cetrafs_rmdir(struct inode *dir, struct dentry *dentry)
{
    /* Parent and victim both: the victim directory is itself a lockable parent, so a peer
     * could otherwise be mid-create inside the directory we free. */
    struct inode *set[] = {dir, d_inode(dentry)};
    int ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_rmdir_locked(dir, dentry);
    cetrafs_ns_report("rmdir", dir, &dentry->d_name, ret);

    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/*
 * Test-only: sleep between the two durable steps of link() and rename()
 * -- the instant a crash would freeze -- so a test can snapshot the
 * device there and check which way the record and the names disagree.
 */
static unsigned int cetrafs_ns_step_gap_ms;
cetrafs_test_param(ns_step_gap_ms, cetrafs_ns_step_gap_ms, uint, 0644);
MODULE_PARM_DESC(ns_step_gap_ms, "TEST ONLY: sleep between link/rename's count change and its name change");

/*
 * Move 'inode''s link count by 'delta' through a namespace-sector CAS
 * on generation 'generation', and set the in-core count to the value
 * the swap landed (evict_inode() reads i_nlink; a stale relative change
 * misleads it). 'seed' is a fresh read of the record, or NULL to read
 * one here.
 */
static int cetrafs_nlink_step(struct super_block *sb,
                              struct inode *inode,
                              u64 generation,
                              const cetrafs_inode_t *seed,
                              s32 delta,
                              u64 now)
{
    struct cetrafs_ns_delta d = {.nlink_delta = delta, .ctime = now};
    cetrafs_inode_t raw;
    int ret;

    if (!seed) {
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
        if (ret)
            return ret;
        seed = &raw;
    }
    ret = cetrafs_inode_ns_cas(sb, inode->i_ino, generation, seed, cetrafs_ns_apply_delta, &d);
    if (!ret)
        set_nlink(inode, d.out_nlink);
    return ret;
}

/*
 * Rename/move a dirent, optionally replacing an existing target (POSIX
 * semantics: replacing a directory requires the target be an empty
 * directory and the source also be a directory; replacing a non-directory
 * requires the source also be a non-directory). RENAME_EXCHANGE and
 * RENAME_WHITEOUT aren't supported (-EINVAL); RENAME_NOREPLACE is.
 *
 * Adds the new dirent before removing the old one, so a failure to ADD
 * (-ENOSPC, an I/O error) leaves the source intact under its original
 * name rather than losing it. A failure to REMOVE the old name after
 * that leaves the file under both names -- with the link count raised
 * to match first (see below), so that state is consistent, merely
 * surprising, and never one where unlinking a name frees live blocks. If an existing target is
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
cetrafs_test_param(rename_force_retry, cetrafs_rename_force_retry, uint, 0644);
MODULE_PARM_DESC(rename_force_retry, "test only: report a lost destination race on the next N renames");

/*
 * Test only: the next rename destination re-verification cannot read the
 * target's record, as a device error would.
 */
static bool cetrafs_rename_recheck_read_fail;
cetrafs_test_param(rename_recheck_read_fail, cetrafs_rename_recheck_read_fail, bool, 0644);
MODULE_PARM_DESC(rename_recheck_read_fail, "test only: the next rename target re-check cannot read the record");

/* TEST ONLY: the next '..' rewrite of a directory changing parent fails,
 * as a device error would. */
static bool cetrafs_rename_dotdot_fail_once;
cetrafs_test_param(rename_dotdot_fail_once, cetrafs_rename_dotdot_fail_once, bool, 0644);
MODULE_PARM_DESC(rename_dotdot_fail_once, "TEST ONLY: the next rename's '..' rewrite fails with -EIO");

/* TEST ONLY: the next rename's new-name write (add or retarget) fails,
 * as a device error would -- after a directory's old name has gone. */
static bool cetrafs_rename_name_fail_once;
cetrafs_test_param(rename_name_fail_once, cetrafs_rename_name_fail_once, bool, 0644);
MODULE_PARM_DESC(rename_name_fail_once, "TEST ONLY: the next rename's new-name write fails with -EIO");

/* TEST ONLY: fail the next N link-count swaps of a rename (the replaced
 * target's -1, the moved file's final -1) with -EIO, as a device refusal
 * would (tests/kernel/rename_nlink_fail.sh). */
static unsigned int cetrafs_rename_nlink_fail;
cetrafs_test_param(rename_nlink_fail, cetrafs_rename_nlink_fail, uint, 0644);
MODULE_PARM_DESC(rename_nlink_fail, "TEST ONLY: fail the next N rename link-count swaps with -EIO");

/*
 * A rename's link-count swap on a record whose NAME has already moved:
 * nothing can be undone by then, and the rename has happened. A count
 * left one high is the safe direction -- evict reads the device and
 * frees nothing -- but the inode is then unreachable and keeps its
 * blocks, and the scrub reclaims only nlink 0, so it is a leak until
 * fsck. A failure used to be dropped without a word, and its error lost
 * in a 'ret' the next step overwrote. So: retry a refused swap from a
 * fresh read (a definite refusal did not apply; an undecidable one has
 * already stopped the mount in caw.c), and say plainly what is left if
 * it still does not land. The moved file's own final -1 has the same
 * shape: it keeps its name, but its last unlink then frees nothing. Returns the swap's result; 'd->out_nlink' is
 * valid on 0.
 */
static bool cetrafs_rename_dir_one_attempt;
cetrafs_test_param(rename_dir_one_attempt, cetrafs_rename_dir_one_attempt, bool, 0644);
MODULE_PARM_DESC(rename_dir_one_attempt, "TEST ONLY: a replaced directory's count gets one swap attempt");

static int cetrafs_rename_ns_delta(struct super_block *sb, u64 ino, struct cetrafs_ns_delta *d, const char *what)
{
    cetrafs_inode_t raw;
    int ret = -EIO, attempt;

    /* rename_dir_one_attempt: the replaced directory's single swap, as
     * before audit 2026-11-14 N8 (test-only). */
    int attempts = d->set_nlink_zero && READ_ONCE(cetrafs_rename_dir_one_attempt) ? 1 : 3;

    for (attempt = 0; attempt < attempts; attempt++) {
        cetrafs_invalidate_raw_inode(sb, ino);
        ret = cetrafs_read_raw_inode(sb, ino, &raw);
        if (!ret && READ_ONCE(cetrafs_rename_nlink_fail)) {
            WRITE_ONCE(cetrafs_rename_nlink_fail, cetrafs_rename_nlink_fail - 1);
            ret = -EIO;
        } else if (!ret && d->gen && cetrafs_le64(raw.generation) != d->gen) {
            ret = -ESTALE; /* the number is another file's now: not ours to move */
        } else if (!ret) {
            ret = cetrafs_inode_ns_cas(sb, ino, cetrafs_le64(raw.generation), &raw, cetrafs_ns_apply_delta, d);
        }
        if (!ret || ret == -ESTALE || ret == -EUCLEAN || cetrafs_sb_is_fenced(sb))
            break;
    }
    if (ret && d->nlink_delta)
        pr_err("%s ino=%llu kept a link count one too high (%d) -- it will not be freed when its last name "
               "goes; fsck -r corrects the count\n",
               what, (unsigned long long) ino, ret);
    return ret;
}

/*
 * Give back the +1 a link or rename took for a name that never landed.
 * One swap whose result nobody read left the count one high on any
 * refusal, silently: the file then never freed (audit 2026-11-06 L4).
 * Same retry and report as the rename's own -1, on the generation the
 * +1 was taken on.
 */
static void cetrafs_nlink_giveback(struct super_block *sb, struct inode *inode, u64 gen, u64 now,
                                   const char *what)
{
    struct cetrafs_ns_delta d = {.ctime = now, .nlink_delta = -1, .gen = gen};

    if (!cetrafs_rename_ns_delta(sb, inode->i_ino, &d, what))
        set_nlink(inode, d.out_nlink);
}

static int cetrafs_rename_dotdot(struct inode *dir, u64 parent_ino)
{
    if (cetrafs_rename_dotdot_fail_once) {
        cetrafs_rename_dotdot_fail_once = false;
        return -EIO;
    }
    return cetrafs_dir_update_dotdot(dir, parent_ino);
}

static void cetrafs_rename_undo_rest(struct inode *old_dir, struct inode *new_dir, struct inode *old_inode, u64 old_ino,
                                     u64 old_gen, u64 now, bool counted, bool dotdot_moved);

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
    u64 old_ino, discard_ino, old_gen = 0;
    bool counted = false;
    bool dotdot_moved = false;
    bool removed_first = false;
    u8 discard_file_type;
    u8 old_file_type;
    u64 now;
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

            /* A check that could not run is not a pass: renaming over a
             * target whose identity went unverified is exactly what this
             * guards against, so a failed read or allocation fails the
             * rename instead of skipping the check. */
            if (!tr)
                return -ENOMEM;
            cetrafs_invalidate_raw_inode(new_dir->i_sb, ctx.ino);
            ret = cetrafs_read_raw_inode(new_dir->i_sb, ctx.ino, tr);
            if (cetrafs_rename_recheck_read_fail) {
                cetrafs_rename_recheck_read_fail = false;
                ret = -EIO; /* test only, see the knob */
            }
            if (ret) {
                kfree(tr);
                return ret;
            }
            if (cetrafs_le64(tr->generation) != cetrafs_inode_get_generation(new_inode)) {
                pr_warn_ratelimited(
                    "rename: '%*pE' in dir ino=%llu still names ino=%llu, but that is a DIFFERENT file now "
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
        if (new_inode && READ_ONCE(cetrafs_rename_verify_stall_ms)) {
            unsigned int pause = xchg(&cetrafs_rename_verify_stall_ms, 0);

            if (pause) {
                pr_info("rename: target verified, pausing %u ms (test)\n", pause);
                msleep(pause); /* test-only, see the knob */
            }
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

            /* As unlink: a wait outside the directories' locks (BM-27). */
            if (cetrafs_lock_foreign_user_would_wait(new_inode, my_node_id) &&
                !cetrafs_nslock_defer_settle(new_inode)) {
                ret = -ERESTARTNOINTR;
                goto out;
            }
            ret = cetrafs_lock_foreign_user_settled(new_inode, my_node_id, &blocked, &reader, NULL, NULL);
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
    now = cetrafs_now_disk();

    /*
     * Between the new name landing and the old one going, the moved
     * file has TWO names, each durable on its own -- the journal does
     * not make the pair atomic. A crash there kept both under nlink=1,
     * and unlinking either name then freed the blocks the other still
     * names. So the count goes up first, and comes back down in the
     * ctime swap at the end, once the old name is gone: at every
     * instant nlink >= names, the direction that can only leak.
     *
     * Not for a directory: its nlink is not a name count, so no count
     * can cover a second name -- a directory gets the opposite order
     * instead (removed_first, below).
     */
    old_gen = cetrafs_inode_get_generation(old_inode);
    if (old_file_type != CETRAFS_FT_DIR) {
        ret = cetrafs_nlink_step(old_dir->i_sb, old_inode, old_gen, NULL, 1, now);
        if (ret)
            goto out;
        counted = true;
    }

    /*
     * A directory changing parent: its '..' FIRST. It used to be the
     * last of the three writes, so when it failed the directory had
     * already moved -- new name in, old name out -- while rename(2)
     * reported an error and '..' still named the old parent; fsck then
     * found a '..' naming a directory that is not the parent
     * (tests/kernel/rename_dotdot_error.sh). Now its failure leaves
     * everything untouched, and a failure of the name write below puts
     * it back. A crash between the two leaves a '..' ahead of the names,
     * which fsck reports the same way it reported the old order's crash
     * window (names ahead of '..').
     */
    if (old_file_type == CETRAFS_FT_DIR && old_dir != new_dir) {
        ret = cetrafs_rename_dotdot(old_inode, new_dir->i_ino);
        if (ret)
            goto out_uncount;
        dotdot_moved = true;
    }

    /*
     * A DIRECTORY loses its old name before it gains the new one.
     *
     * The other order left it with two names between the two dirent
     * writes, each durable on its own, and a crash there kept both. A
     * directory with two names is not a leak a count can absorb, as it
     * is for a file: rmdir through either name zeroes it and frees its
     * number while the other name still points there, and the next file
     * to take the number appears under that name -- a second name for a
     * stranger, whose unlink then frees the stranger's blocks.
     *
     * Old name first, a crash in between leaves the directory with NO
     * name: unreachable, its contents intact, and fsck links it into
     * /lost+found. A failure in between gives the old name back
     * (out_unremove).
     */
    removed_first = old_file_type == CETRAFS_FT_DIR;
    if (removed_first) {
        ret = cetrafs_dir_remove_entry(old_dir, &old_dentry->d_name, old_inode->i_ino, &discard_ino,
                                       &discard_file_type);
        if (ret)
            goto out_uncount;
        if (cetrafs_ns_step_gap_ms)
            msleep(cetrafs_ns_step_gap_ms); /* test-only, see the knob */
    }
    if (cetrafs_rename_name_fail_once) {
        cetrafs_rename_name_fail_once = false;
        ret = -EIO; /* test-only, see the knob */
        goto out_unremove;
    }

    if (new_inode) {
        u64 removed_ino;
        u8 removed_file_type;

        /* One dirent write, so the destination name never stops
         * resolving -- see cetrafs_dir_retarget_entry(). This both
         * satisfies POSIX ("the link named by new shall remain visible
         * to other processes throughout the renaming operation") and
         * removes the window in which a failure here could destroy the
         * target while leaving the source in place. */
        ret = cetrafs_dir_retarget_entry(new_dir, &new_dentry->d_name, new_inode->i_ino, old_ino, old_file_type,
                                         &removed_ino, &removed_file_type);
        if (ret)
            goto out_unremove;

        /* Neither branch frees blocks/the inode number here -- just
         * persists the correct nlink (0 for a replaced directory, which
         * can't be hardlinked; decremented otherwise) and lets the VFS's
         * own eviction trigger super_ops.c's cetrafs_evict_inode() once
         * the last reference actually goes away. Same reasoning as
         * cetrafs_unlink_locked()/cetrafs_rmdir_locked() above. */
        if (removed_file_type == CETRAFS_FT_DIR) {
            struct cetrafs_ns_delta d = {.set_nlink_zero = true, .ctime = now};
            int nret;

            /* The same retries as the replaced file's -1 below: one
             * refused swap left the directory unreachable and allocated
             * until fsck (audit 2026-11-14 N8). */
            if (removed_ino == new_inode->i_ino)
                d.gen = cetrafs_inode_get_generation(new_inode);
            nret = cetrafs_rename_ns_delta(new_dir->i_sb, removed_ino, &d, "rename: replaced directory");
            /*
             * Both results used to be discarded, and the rename carried
             * on as if the record had been zeroed. It cannot be undone
             * from here -- the entry has already been replaced, so the
             * directory is unreachable whatever its record says -- but
             * it must not pass in SILENCE: the record then still claims
             * a live link while nothing names it, evict's re-read
             * refuses to free an inode that is not dead, and the number
             * stays allocated until fsck notices. Saying
             * so is the difference between a known orphan and a
             * mystery. The sibling branch below has always reported it.
             * Nothing online reclaims it: the scrub's orphan pass takes
             * only records whose count is already 0
             * (scrub_reclaim_orphan_inodes()), so this one waits for
             * fsck -r, which links it into /lost+found.
             */
            if (nret)
                pr_warn_ratelimited(
                    "rename: replaced directory ino=%llu kept a live link count (%d) -- it is unreachable and "
                    "stays allocated until fsck -r links it into /lost+found\n",
                    (unsigned long long) removed_ino, nret);
            clear_nlink(new_inode);
        } else {
            struct cetrafs_ns_delta d = {.nlink_delta = -1, .ctime = now};

            ret = cetrafs_rename_ns_delta(new_dir->i_sb, removed_ino, &d, "rename: replaced file");
            /* In-core absolute from the value the swap landed, not a
             * relative drop off a possibly stale cached count --
             * evict_inode() gates the free on the replaced target's
             * in-core i_nlink. */
            if (!ret && removed_ino == new_inode->i_ino)
                set_nlink(new_inode, d.out_nlink);
            else
                drop_nlink(new_inode);
        }
        cetrafs_set_ctime_disk(new_inode, now);
    }

    if (!new_inode) {
        /* No target to replace: add the new name before removing the
         * old one, so a failure leaves the source intact. */
        ret = cetrafs_dir_add_entry(new_dir, &new_dentry->d_name, old_ino, old_file_type);
        if (ret)
            goto out_unremove;
    }
    if (!removed_first) {
        if (cetrafs_ns_step_gap_ms)
            msleep(cetrafs_ns_step_gap_ms); /* test-only, see the knob */

        /* A failure from here on leaves the file with both names and the
         * count that says so: consistent, so nothing is given back. */
        ret = cetrafs_dir_remove_entry(old_dir, &old_dentry->d_name, old_inode->i_ino, &discard_ino,
                                       &discard_file_type);
        if (ret)
            goto out;
    }

    /* POSIX: a successful rename updates the moved inode's ctime. This
     * used to touch only the in-core object, which nothing then wrote
     * out (inode_set_ctime() does not dirty the inode), so the on-disk
     * value never moved. Same omission N6 found in unlink. */
    {
        /* The moved inode's on-disk ctime, by namespace-sector CAS: it
         * cannot touch the file sector, so renaming a file a peer is
         * actively WRITING is safe again (v0x0005) -- the old blind
         * whole-record rewrite here had to be skipped under a foreign
         * opener to avoid racing its deferred record state.
         *
         * ...carrying the -1 that matches the +1 above, now that the old
         * name is gone. If it does not land the count stays one high: a
         * leak, never a free -- and said so (cetrafs_rename_ns_delta()). */
        struct cetrafs_ns_delta d = {.ctime = now, .nlink_delta = counted ? -1 : 0};

        /* A directory renamed inside one parent is not locked by the VFS
         * (vfs_rename() locks a moved directory only when its parent
         * changes), so the swap and the in-core stores below run under
         * fd_pub_mutex instead: a refresh of it holds that from its read
         * to its apply, and would otherwise put the old ctime back
         * (BUG-CLASSES class 29). */
        cetrafs_inode_fd_pub_lock(old_inode);
        if (!cetrafs_rename_ns_delta(old_dir->i_sb, old_ino, &d, "rename: moved file") && counted)
            set_nlink(old_inode, d.out_nlink);
        cetrafs_set_ctime_disk(old_inode, now);
        cetrafs_inode_fd_pub_unlock(old_inode);
    }
    ret = 0;

out:
    return ret;

out_unremove:
    /* A directory's new name never landed after its old one went: give
     * the old one back. Its slot was freed a moment ago, so this cannot
     * need room the directory does not have; if it fails anyway the
     * directory has no name at all, and says so -- fsck finds it and
     * links it into /lost+found, contents intact. */
    /* The undo is not interruptible: a SIGKILL that stopped the forward
     * step must not also stop the step that puts things back. */
    if (!READ_ONCE(cetrafs_rename_undo_killable))
        cetrafs_dir_undo_begin();
    if (removed_first) {
        int rret = cetrafs_dir_add_entry(old_dir, &old_dentry->d_name, old_ino, old_file_type);

        /* Failed anyway (a device error): the directory has no name, and
         * the count and '..' below are still given back -- fsck then
         * finds a consistent orphan to link into /lost+found. */
        if (rret)
            pr_err("rename: directory ino=%llu lost its name '%*pE' in ino=%llu and could neither take the new one "
                   "(%d) nor get the old one back (%d) -- it is unnamed until fsck links it into /lost+found\n",
                   (unsigned long long) old_ino, (int) old_dentry->d_name.len, old_dentry->d_name.name,
                   (unsigned long long) old_dir->i_ino, ret, rret);
    }
    cetrafs_rename_undo_rest(old_dir, new_dir, old_inode, old_ino, old_gen, now, counted, dotdot_moved);
    if (!READ_ONCE(cetrafs_rename_undo_killable))
        cetrafs_dir_undo_end();
    return ret;

out_uncount:
    if (!READ_ONCE(cetrafs_rename_undo_killable))
        cetrafs_dir_undo_begin();
    cetrafs_rename_undo_rest(old_dir, new_dir, old_inode, old_ino, old_gen, now, counted, dotdot_moved);
    if (!READ_ONCE(cetrafs_rename_undo_killable))
        cetrafs_dir_undo_end();
    return ret;
}

/* The new name never landed: give the count back, and the '..'. */
static void cetrafs_rename_undo_rest(struct inode *old_dir, struct inode *new_dir, struct inode *old_inode, u64 old_ino,
                                     u64 old_gen, u64 now, bool counted, bool dotdot_moved)
{
    if (counted)
        cetrafs_nlink_giveback(old_dir->i_sb, old_inode, old_gen, now, "rename: un-moved file");
    if (dotdot_moved) {
        int dret = cetrafs_dir_update_dotdot(old_inode, old_dir->i_ino);

        if (dret)
            pr_err("rename: directory ino=%llu stayed in ino=%llu but its '..' could not be put back from ino=%llu "
                   "(%d) -- fsck will report it\n",
                   (unsigned long long) old_ino, (unsigned long long) old_dir->i_ino,
                   (unsigned long long) new_dir->i_ino, dret);
    }
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

/* How far up the '..' chain a directory move looks before calling the
 * chain corrupt. Far deeper than any path can be (PATH_MAX allows ~2048
 * levels); the bound exists so a corrupt chain -- a loop already on the
 * device -- ends the walk instead of spinning (rule 14). */
#define CETRAFS_RENAME_MAX_DEPTH 4096

/*
 * Would moving 'moved_ino' into 'new_dir' put it inside itself? Asked
 * of the DEVICE, from 'new_dir' up through each '..' to the root.
 *
 * The VFS asks the same question of this node's dentry cache, which is
 * enough on one machine and not on a shared LUN: a peer's move is not
 * in our cache. Node A `mv P Q/` and node B `mv Q P/` each passed the
 * VFS check, and P and Q left the tree as each other's children --
 * unreachable from the root on every node
 * (tests/kernel/rename_cycle_peer.sh).
 *
 * Only sound under the root directory's namespace lock, which every
 * directory move to another parent takes (cetrafs_rename()): those are
 * the only operations that rewrite a '..', so the chain cannot change
 * under the walk. Each step's dirent read goes through the dirent_seq
 * gate, which reads the record forced-fresh and re-reads the blocks if
 * a peer changed them.
 */
static int cetrafs_rename_dest_under_source(struct inode *new_dir, u64 moved_ino)
{
    static const struct qstr dotdot = QSTR_INIT("..", 2);
    struct super_block *sb = new_dir->i_sb;
    u64 root_ino = d_inode(sb->s_root)->i_ino;
    u64 cur = new_dir->i_ino;
    unsigned int depth;

    for (depth = 0; depth < CETRAFS_RENAME_MAX_DEPTH; depth++) {
        struct cetrafs_lookup_ctx ctx = {.name = &dotdot, .ino = 0};
        struct inode *dir;
        int ret;

        if (cur == moved_ino)
            return -EINVAL; /* the destination is inside what is being moved */
        if (cur == root_ino)
            return 0;
        dir = cetrafs_iget(sb, cur);
        if (IS_ERR(dir))
            return PTR_ERR(dir);
        if (!S_ISDIR(dir->i_mode)) {
            iput(dir);
            return -EUCLEAN;
        }
        ret = cetrafs_walk_dirents(dir, cetrafs_lookup_visit, &ctx);
        iput(dir);
        if (ret < 0)
            return ret;
        if (!ctx.ino) {
            pr_err("rename: directory ino=%llu has no '..' -- refusing the move\n", (unsigned long long) cur);
            return -EUCLEAN;
        }
        cur = ctx.ino;
        cond_resched();
    }
    pr_err("rename: the '..' chain above ino=%llu is longer than %u -- a loop already on the device; refusing\n",
           (unsigned long long) new_dir->i_ino, CETRAFS_RENAME_MAX_DEPTH);
    return -EUCLEAN;
}

/* TEST ONLY: stall a rename after the VFS's lookups and before its
 * namespace locks, where a peer's rename lands in the real race. */
static unsigned int cetrafs_rename_prelock_stall_ms;
cetrafs_test_param(rename_prelock_stall_ms, cetrafs_rename_prelock_stall_ms, uint, 0644);
MODULE_PARM_DESC(rename_prelock_stall_ms, "TEST ONLY: pause a rename between its lookups and its namespace locks");

/* TEST ONLY: skip the device-side cycle check, so ctest's rename-loop
 * scenario can show it is the only thing between two nodes' crossed
 * directory moves and an unreachable pair. */
static bool cetrafs_rename_skip_cycle_check;
cetrafs_test_param(rename_skip_cycle_check, cetrafs_rename_skip_cycle_check, bool, 0644);
MODULE_PARM_DESC(rename_skip_cycle_check, "TEST ONLY: a directory move does not check the device for a cycle");

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
        struct inode *set[5];
        struct inode *moved = d_inode(old_dentry);
        bool dir_move = S_ISDIR(moved->i_mode) && old_dir != new_dir;
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
        set[2] = moved;
        set[3] = target;
        /* A directory changing parent also takes the ROOT directory's
         * lock: one lock every such move on every node takes, so they
         * are totally ordered and the '..' walk below sees a chain no
         * peer is rewriting. A directory's ancestry is changed by
         * nothing else. Same-parent renames and file moves skip it. */
        set[4] = dir_move ? d_inode(old_dir->i_sb->s_root) : NULL;

        if (cetrafs_rename_prelock_stall_ms && attempt == 0)
            msleep(cetrafs_rename_prelock_stall_ms);

        ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));
        if (ret) {
            if (discovered)
                iput(discovered);
            return ret;
        }

        ret = dir_move && !READ_ONCE(cetrafs_rename_skip_cycle_check)
                  ? cetrafs_rename_dest_under_source(new_dir, moved->i_ino)
                  : 0;
        if (!ret)
            ret = cetrafs_rename_locked(idmap, old_dir, old_dentry, new_dir, new_dentry, flags, target,
                                        &target_changed);
        cetrafs_ns_report("rename", old_dir, &old_dentry->d_name, ret);

        cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
        if (discovered)
            iput(discovered);

        if (!target_changed)
            return ret;
    }

    pr_warn_ratelimited("rename: '%*pE' in dir ino=%llu changed under us %u times running -- giving up\n",
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
/* TEST ONLY: pause a link between its fresh read and its +1, where a
 * peer's links can land (tests/kernel/nlink_saturates.sh). */
static unsigned int cetrafs_link_step_stall_ms;
cetrafs_test_param(link_step_stall_ms, cetrafs_link_step_stall_ms, uint, 0644);
/* TEST ONLY: the next link's name write fails, after its +1 landed
 * (tests/kernel/nlink_giveback_retry.sh). */
static bool cetrafs_link_name_fail_once;
cetrafs_test_param(link_name_fail_once, cetrafs_link_name_fail_once, bool, 0644);
MODULE_PARM_DESC(link_name_fail_once, "TEST ONLY: the next link's name write fails with -EIO");
MODULE_PARM_DESC(link_step_stall_ms, "TEST ONLY: pause a link between its record read and its nlink step");

static int cetrafs_link_locked(struct dentry *old_dentry, struct inode *dir, struct dentry *dentry)
{
    struct inode *inode = d_inode(old_dentry);
    cetrafs_inode_t raw;
    u64 now;
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
             * that opener's; refuse exactly as unlink does. A wait it
             * would do runs outside the directory's locks (BM-27). */
            if (cetrafs_lock_foreign_user_would_wait(inode, my_node_id) && !cetrafs_nslock_defer_settle(inode))
                return -ERESTARTNOINTR;
            ret = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, NULL, NULL);
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
        pr_warn_ratelimited("refusing to link '%*pE' -> ino=%llu: that number is a DIFFERENT file now (generation disk=%llu core=%llu)\n",
                            (int) dentry->d_name.len, dentry->d_name.name, (unsigned long long) inode->i_ino,
                            (unsigned long long) cetrafs_le64(raw.generation),
                            (unsigned long long) cetrafs_inode_get_generation(inode));
        return -ESTALE;
    }
    if (cetrafs_le32(raw.nlink) == 0) {
        pr_warn_ratelimited("refusing to link '%*pE' -> ino=%llu: it has no names left (nlink=0)\n",
                            (int) dentry->d_name.len, dentry->d_name.name, (unsigned long long) inode->i_ino);
        return -ENOENT;
    }

    fs_debug(info, "link '%.*s' -> ino=%llu in dir ino=%llu", (int) dentry->d_name.len, dentry->d_name.name,
             (unsigned long long) inode->i_ino, (unsigned long long) dir->i_ino);

    /*
     * The +1 FIRST, then the name. Each is durable on its own and the
     * journal does not make the pair atomic, so a crash between them
     * keeps whichever came first -- and the two orders fail in opposite
     * directions. Name first left two names and nlink=1: unlinking
     * either one then frees the blocks the other still names. Count
     * first leaves nlink one too high: a leak, which fsck repairs and
     * nothing reads as license to free.
     *
     * By namespace-sector CAS (v0x0005): applied to the LIVE value, so
     * it composes with every other sector-0 mutation -- lock.c's
     * presence bits above all, which run without this lock. The seed is
     * the forced-fresh read that just verified the identity.
     */
    now = cetrafs_now_disk();
    if (cetrafs_link_step_stall_ms)
        msleep(cetrafs_link_step_stall_ms); /* test-only, see the knob */
    ret = cetrafs_nlink_step(dir->i_sb, inode, cetrafs_le64(raw.generation), &raw, 1, now);
    if (ret)
        return ret;
    if (cetrafs_ns_step_gap_ms)
        msleep(cetrafs_ns_step_gap_ms); /* test-only, see the knob */

    if (cetrafs_link_name_fail_once) {
        cetrafs_link_name_fail_once = false;
        ret = -EIO; /* test-only, see the knob */
    } else {
        ret = cetrafs_dir_add_entry(dir, &dentry->d_name, inode->i_ino, cetrafs_dirent_type(inode));
    }
    if (ret) {
        /* No name was added: give the count back. If even that fails
         * the count stays one high -- the safe direction. */
        cetrafs_nlink_giveback(dir->i_sb, inode, cetrafs_le64(raw.generation), now, "link: un-linked file");
        return ret;
    }
    cetrafs_set_ctime_disk(inode, now);
    ihold(inode);
    d_instantiate(dentry, inode);

    return 0;
}

static int cetrafs_link(struct dentry *old_dentry, struct inode *dir, struct dentry *dentry)
{
    /* Parent and target both: the target's nlink is mutated, and a peer
     * can be reaching it through one of its other names. */
    struct inode *set[] = {dir, d_inode(old_dentry)};
    int ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));

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
cetrafs_test_param(symlink_fail_after_write, cetrafs_symlink_fail_after_write, bool, 0644);
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
    u64 now;
    int len = strlen(symname) + 1; /* page_symlink() wants the NUL included */
    int ret;

    if (len > CETRAFS_BLOCK_SIZE)
        return -ENAMETOOLONG; /* target must fit in the one block a symlink gets */

    fs_debug(info, "symlink '%.*s' -> '%s' in ino=%llu", (int) dentry->d_name.len, dentry->d_name.name, symname,
             (unsigned long long) dir->i_ino);

    ret = cetrafs_alloc_inode(sb, &ino);
    if (ret)
        return ret;

    now = cetrafs_now_disk();
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
    raw.crtime = raw.ctime = raw.mtime = raw.atime = cetrafs_cpu_to_le64(now);
    raw.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    raw.generation = cetrafs_cpu_to_le64(cetrafs_inode_new_generation(sb)); /* v0x0008 reuse detector */
    cetrafs_new_record_locked(sb, &raw); /* held until its name lands (BM-29) */
    raw.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    raw.eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw.et.leaf));

    /* As cetrafs_create_locked(): the previous life's copy goes first. */
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_write_raw_inode_new(sb, ino, &raw);
    if (ret) {
        cetrafs_free_inode(sb, ino);
        return ret;
    }
    /* No mid-birth theft check here: cetrafs_alloc_inode()'s birth claim
     * made this record ours on the device, and a scrub's reclaim claim
     * cannot land on it -- see cetrafs_inode_birth_claim(). */

    /* Instantiate, write the target text, label, and only then name it --
     * see cetrafs_create_publish(). The text goes in while the symlink is
     * still unreachable, so no peer (or local lookup) can ever resolve
     * the name to a size-0, target-less link mid-build. Nothing on these
     * failure paths removes a dirent, because none exists yet. */
    inode = cetrafs_iget(sb, ino);
    if (IS_ERR(inode)) {
        cetrafs_new_record_unwind(sb, ino, &raw);
        return PTR_ERR(inode);
    }
    cetrafs_new_inode_take_born_lock(inode, &raw);

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
    int ret = cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));

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
    .getattr = cetrafs_getattr,
};
