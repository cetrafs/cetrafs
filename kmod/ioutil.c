// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * ioutil.c -- the shared low-level read primitive for any on-disk
 * structure another cluster node might have just written.
 *
 * The Linux buffer cache assumes one kernel owns the device: once this
 * node has read a block and marked it uptodate, sb_bread() returns that
 * copy forever and never notices a peer overwriting the same LBA. That
 * undermines every "read the current cluster state" check here --
 * Node Registry rows, ZG descriptors, inode lock fields, dirent/xattr/
 * extent-leaf blocks, bitmap and BG state -- including the
 * write-then-verify-readback used to catch a lost race: the verify read
 * is satisfied by this node's own just-written buffer, so it can never
 * see what a peer wrote. On two-node hardware that showed up as a
 * heartbeat renewal invisible to the peer, and as both nodes winning the
 * same exclusive open-lock race.
 *
 * cetrafs_bread_uncached() is the drop-in replacement for those call
 * sites: discard what the buffer cache believes and read the device.
 * Deliberately not used everywhere -- journal replay and freshly
 * allocated, about-to-be-overwritten blocks stay on sb_bread(), since no
 * other node reads them before this one owns them, and forcing a device
 * round trip there buys nothing but mount-time latency.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/version.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/pagemap.h>
/* struct folio_batch moved out of pagevec.h; build against either. */
#if __has_include(<linux/folio_batch.h>)
#include <linux/folio_batch.h>
#else
#include <linux/pagevec.h>
#endif

#include <linux/crc32c.h>

#include "kmod.h"

struct buffer_head *cetrafs_bread_uncached(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_getblk(sb, block);

    if (!bh)
        return NULL;

    /*
     * Only discard a *clean* cached copy before re-reading. A dirty
     * buffer holds a write that hasn't reached the device yet (e.g. this
     * node's own recent write, mid-flight before its own
     * sync_dirty_buffer()) -- forcing a read on top of it would fetch
     * whatever is still physically on the device and silently clobber
     * that pending write with stale content. Caught via a real
     * regression: a test helper's unsynced pwrite() direct to the block
     * device raced against an immediate remount, and this function's
     * first version discarded the test helper's not-yet-flushed write
     * every time, always reading back the previous content instead.
     * Dirty implies uptodate in this cache, so leaving a dirty buffer
     * alone here is always safe: bh_read() below will see it's already
     * uptodate and return immediately without touching it.
     */
    lock_buffer(bh);
    if (buffer_uptodate(bh) && !buffer_dirty(bh))
        clear_buffer_uptodate(bh);
    unlock_buffer(bh);

    if (bh_read(bh, 0) < 0) {
        brelse(bh);
        return NULL;
    }

    return bh;
}

/*
 * sb_bread() with bounded retries, for any block another thread may be
 * invalidating underneath us.
 *
 * __bread_slow() re-checks buffer_uptodate AFTER its read completes and
 * returns NULL if the bit is no longer set -- so a perfectly healthy read
 * racing a cetrafs_invalidate_block() of the same block comes back NULL,
 * indistinguishable from a real device error. Callers turned that into
 * -EIO. It is reached constantly in practice: cetrafs_apply_raw_to_vfs_
 * inode() invalidates a depth-1 inode's external extent-leaf block on
 * EVERY dentry revalidate, so any directory busy enough to be looked up
 * while it is being read hits it. Confirmed: a thread creating
 * files in one directory while another ran `ls` over it saw open() fail
 * with EIO several times per 300 creates, with no device error anywhere.
 *
 * A failure caused by a racing invalidation is transient and converges on
 * re-read; a real I/O error persists. Retrying a bounded number of times
 * separates the two -- the same reasoning the checksummed-record readers
 * already use for torn reads (see cetrafs_read_raw_inode() and the dirent
 * tail check), applied to the layer below them.
 */
struct buffer_head *cetrafs_bread_retry(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh;
    int attempt;

    for (attempt = 0; attempt < CETRAFS_BREAD_RETRIES; attempt++) {
        bh = sb_bread(sb, block);
        if (bh)
            return bh;
        /* Back off rather than spin: the window is another thread's
         * invalidate, and retrying instantly just lands in the same
         * storm when that thread is invalidating in a loop (every
         * dentry revalidate does). */
        usleep_range(50, 200);
    }

    pr_err("block %llu unreadable after %d attempts\n", (unsigned long long) block, CETRAFS_BREAD_RETRIES);
    return NULL;
}

/* cetrafs_bread_uncached() with the same bounded retries as
 * cetrafs_bread_retry(), for the same reason: bh_read() reports failure
 * if the uptodate bit is gone by the time it re-checks, which a
 * concurrent forced-fresh read of the same block can cause. */
struct buffer_head *cetrafs_bread_uncached_retry(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh;
    int attempt;

    for (attempt = 0; attempt < CETRAFS_BREAD_RETRIES; attempt++) {
        bh = cetrafs_bread_uncached(sb, block);
        if (bh)
            return bh;
        usleep_range(50, 200);
    }

    /* Ratelimited: when the DEVICE is gone rather than a single block
     * being bad, every caller fails, and the heartbeat alone sweeps 64
     * registry rows per tick -- measured at ~500 of these lines in
     * eight seconds, which buries the one message that explains what
     * happened. The failure is still reported, just not once per
     * block. */
    pr_err_ratelimited("block %llu unreadable (forced-fresh) after %d attempts\n", (unsigned long long) block,
                       CETRAFS_BREAD_RETRIES);
    return NULL;
}

/*
 * Claim a cached buffer for modification; cetrafs_bh_end_update()
 * publishes the result. Only the buffer LOCK excludes both hazards:
 *
 *  1. The forced-fresh readers above clear uptodate and re-read into the
 *     buffer's memory. Against a buffer a local thread is partway
 *     through modifying, the modification is overwritten and then
 *     persisted over -- measured as 12 of 292 dirents silently lost.
 *     They take the lock before clearing, so holding it makes them wait.
 *
 *  2. Writeback can flush a DIRTY buffer at any moment, and a block
 *     modified but not yet restamped is not a legal image: a peer reads
 *     it and it fails its tail checksum until our sync lands. Writeback
 *     locks the buffer, so holding the lock across modify-and-restamp
 *     means only complete, checksummed images reach the device.
 *
 * Marking the buffer dirty up front instead closes (1) and causes (2).
 *
 * Between begin and end, call nothing that takes the buffer lock itself
 * (sync_dirty_buffer(), bh_read()). The one exception is
 * cetrafs_journal_write_block(), which REQUIRES the buffer still locked
 * and not yet dirty and owns ending the update on every path: a
 * journaled block is modify, restamp, journal -- never end_update in the
 * caller, which would dirty it before its entry commits and let
 * writeback flush the target ahead of the journal.
 */
void cetrafs_bh_begin_update(struct buffer_head *bh)
{
    lock_buffer(bh);
    /* The content at this instant is still the valid on-disk image, so
     * asserting uptodate is honest -- and it must be set before any
     * modification, since a reader may have cleared it. */
    set_buffer_uptodate(bh);
}

/*
 * cetrafs_bh_begin_update() for a block that is about to be JOURNALED,
 * returning the CRC32C of the pristine image it just locked.
 *
 * That CRC goes into the journal entry as prev_checksum, and is what
 * lets replay prove the target has not been rewritten by somebody else
 * since (see cetrafs_journal_header_t). Taking it here rather than at
 * the call site is the point: the lock and the snapshot come from one
 * call, so a caller cannot read the "prior" image a modification too
 * late. Costs one 4 KiB CRC (~0.5 us) on paths that are already doing a
 * synchronous device round trip (~38 ms on the deployment LUN), and
 * never runs on the per-block data path -- see docs/PERFORMANCE.md
 * invariant 1 before moving it anywhere else.
 */
u32 cetrafs_bh_begin_update_crc(struct buffer_head *bh)
{
    cetrafs_bh_begin_update(bh);
    return ~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE);
}

/* Publish a buffer modified under cetrafs_bh_begin_update(): it is a
 * complete, correctly-checksummed image from here on. */
void cetrafs_bh_end_update(struct buffer_head *bh)
{
    mark_buffer_dirty(bh);
    unlock_buffer(bh);
}

/*
 * Write a dirty buffer synchronously and say whether it reached the
 * device. Use this, not sync_dirty_buffer(), wherever the answer matters.
 *
 * sync_dirty_buffer() decides failure by looking at BH_Uptodate AFTER
 * the write completes. In this module that is a race, not an answer: a
 * forced-fresh reader (cetrafs_bread_uncached(), every stat/lookup)
 * takes the buffer lock the moment the write's completion drops it and
 * clears BH_Uptodate to re-read. The writer then sees !uptodate and
 * reports -EIO for a write that landed -- measured as creates failing
 * EIO while `ls -la` loops ran (dir_concurrency.sh), the moment the
 * record writers started honouring the result. BH_Write_EIO is set by
 * the write's own completion and nothing else clears it, so it is the
 * one honest witness.
 *
 * Not dirty: nothing to write, 0 -- after waiting out a write already in
 * flight (the buffer lock), whose own caller owns its result.
 */
int cetrafs_sync_buffer(struct buffer_head *bh)
{
    lock_buffer(bh);
    if (!test_clear_buffer_dirty(bh)) {
        unlock_buffer(bh);
        return 0;
    }
    clear_buffer_write_io_error(bh);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
    /* 7.2 completes per bio and takes no buffer reference of its own;
     * bh_end_write() is end_buffer_write_sync() without the put_bh(). */
    bh_submit(bh, REQ_OP_WRITE | REQ_SYNC, bh_end_write);
#else
    get_bh(bh);
    bh->b_end_io = end_buffer_write_sync;
    submit_bh(REQ_OP_WRITE | REQ_SYNC, bh);
#endif
    wait_on_buffer(bh);
    return buffer_write_io_error(bh) ? -EIO : 0;
}

/*
 * Completion for cetrafs_sync_buffer_keep(): unlike end_buffer_write_sync()
 * it never clears BH_Uptodate on an error -- see there.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
static void cetrafs_end_write_keep(struct bio *bio)
{
    struct buffer_head *bh;

    if (!bio_endio_bh(bio, &bh))
        set_buffer_write_io_error(bh);
    unlock_buffer(bh);
}
#else
static void cetrafs_end_write_keep(struct buffer_head *bh, int uptodate)
{
    if (!uptodate)
        set_buffer_write_io_error(bh);
    unlock_buffer(bh);
    put_bh(bh);
}
#endif

/*
 * cetrafs_sync_buffer() for a block whose cached bytes are the ONLY copy
 * of state the device does not have yet -- the allocation bitmaps. A
 * failed write must not discard them: a buffer left !uptodate is re-read
 * from the device by the next sb_bread(), which silently forgets
 * allocations of blocks already in use. So on failure the buffer stays
 * uptodate and is re-dirtied, and the next durability boundary retries.
 *
 * Also catches an EARLIER failed write of the same block (the flusher's,
 * whose completion does clear BH_Uptodate): while the bit is still clear
 * nobody has re-read the block over our bytes, so they are put back.
 */
int cetrafs_sync_buffer_keep(struct buffer_head *bh)
{
    lock_buffer(bh); /* also waits out a writeback already in flight */
    if (buffer_write_io_error(bh)) {
        clear_buffer_write_io_error(bh);
        set_buffer_uptodate(bh);
        unlock_buffer(bh);
        mark_buffer_dirty(bh);
        return -EIO;
    }
    if (!test_clear_buffer_dirty(bh)) {
        unlock_buffer(bh);
        return 0;
    }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
    bh_submit(bh, REQ_OP_WRITE | REQ_SYNC, cetrafs_end_write_keep);
#else
    get_bh(bh);
    bh->b_end_io = cetrafs_end_write_keep;
    submit_bh(REQ_OP_WRITE | REQ_SYNC, bh);
#endif
    wait_on_buffer(bh);
    if (buffer_write_io_error(bh)) {
        clear_buffer_write_io_error(bh);
        mark_buffer_dirty(bh); /* still uptodate: the next boundary retries it */
        return -EIO;
    }
    return 0;
}

/*
 * Copy bytes out of a buffer a writer may be modifying RIGHT NOW under
 * the update protocol above. An unlocked memcpy can copy mid-
 * modification: a torn in-memory view that fails its checksum even
 * though the device and the writer are both fine. Readers that verify
 * a checksum over what they copy must copy under the same lock the
 * writers hold.
 */
void cetrafs_bh_copy_stable(struct buffer_head *bh, void *out, size_t len)
{
    lock_buffer(bh);
    memcpy(out, bh->b_data, len);
    unlock_buffer(bh);
}

/*
 * Run a read-only test over a buffer's bytes under the buffer lock, for
 * a reader that must not see a writer's half-edited image -- and must
 * not CLAIM the buffer to get that guarantee: a claim released with
 * cetrafs_bh_abort_update() drops a clean buffer's cached image, which
 * on a lookup path means a device re-read every time (file.c's
 * cetrafs_leaf_bh_holds_uninit()).
 */
bool cetrafs_bh_test_stable(struct buffer_head *bh, bool (*test)(const void *data, void *arg), void *arg)
{
    bool r;

    lock_buffer(bh);
    r = test(bh->b_data, arg);
    unlock_buffer(bh);
    return r;
}

/* Release a buffer claimed by cetrafs_bh_begin_update() WITHOUT
 * publishing it: for a path that claimed the block and then decided it
 * had nothing to write after all, or that is about to free the block
 * outright. Every begin must reach exactly one of end/abort on every
 * path -- a buffer left locked wedges every later access to it. */
void cetrafs_bh_abort_update(struct buffer_head *bh)
{
    /* Nothing was published, so drop the uptodate claim -- unless the
     * buffer holds a pending write, where clearing it would discard a
     * write that has not reached the device yet.
     *
     * This matters for a buffer claimed by cetrafs_getblk_overwrite():
     * that one was never read, so its contents are whatever memory the
     * buffer came with, and begin_update has already declared them
     * uptodate. Leaving that behind would let the next CACHED read hand
     * out uninitialised memory as the block's real image. For a buffer
     * that really was read the clear is merely a wasted re-read on the
     * next access, and these are rare error paths. */
    if (!buffer_dirty(bh))
        clear_buffer_uptodate(bh);
    unlock_buffer(bh);
}

/*
 * Claim a block for a write that replaces ALL CETRAFS_BLOCK_SIZE bytes
 * of it.
 *
 * sb_bread() would fetch the old contents first -- a full device round
 * trip to read bytes the very next statement destroys. On a loop device
 * that is free, which is why it went unnoticed; on the shared LUN this
 * filesystem is for it is ~5 ms, and the journal pays it three times per
 * journaled block (payload, header, consume).
 *
 * sb_getblk() allocates the buffer without reading it, and
 * cetrafs_bh_begin_update() marks it uptodate -- honest only because the
 * caller overwrites every byte before cetrafs_bh_end_update() publishes
 * it. Returns the buffer LOCKED: exactly one of cetrafs_bh_end_update()
 * / cetrafs_bh_abort_update() must follow on every path, as for
 * begin_update itself.
 *
 * ONLY for a complete overwrite. A partial update must read the block
 * first, or it publishes uninitialised memory as the untouched bytes.
 */
struct buffer_head *cetrafs_getblk_overwrite(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_getblk(sb, block);

    if (!bh)
        return NULL;

    cetrafs_bh_begin_update(bh);
    return bh;
}

/*
 * Patch a region of a cached block with content we KNOW is now on the
 * device, instead of dropping the cached copy.
 *
 * A successful compare-and-swap goes straight to the device behind the
 * buffer cache, so the cached copy has to stop being trusted -- but
 * invalidating it throws away a block that is about to be read again
 * (the record a namespace operation just updated is the record the next
 * lookup reads), turning each swap into a later device read. We know
 * the exact bytes the device now holds, so write them into the cached
 * buffer and leave it CLEAN: coherent, and still warm.
 *
 * Any uptodate buffer is patched, dirty or not. A dirty one holds a
 * write that has not reached the device; the swap was computed against
 * the device without it, so for THIS region the swap's bytes are the
 * newer truth, and the rest of the block keeps its pending write. What
 * must not happen is the old fallback, which cleared uptodate on a
 * dirty buffer: "dirty implies uptodate" is what every forced-fresh
 * read relies on to leave a pending write alone (cetrafs_bread_uncached
 * above), and without it the next read fetched the device over the
 * pending write and the write-back then put the old bytes back. A
 * buffer that is not uptodate has nothing stale to correct.
 */
void cetrafs_cache_region_after_cas(struct super_block *sb, sector_t block, unsigned int off, const void *src,
                                    unsigned int len)
{
    struct buffer_head *bh;

    if (off + len > CETRAFS_BLOCK_SIZE)
        return;

    bh = sb_getblk(sb, block);
    if (!bh)
        return;

    lock_buffer(bh);
    if (buffer_uptodate(bh))
        memcpy(bh->b_data + off, src, len);
    unlock_buffer(bh);
    brelse(bh);
}

/*
 * Drop a clean cached copy of 'block', if any, so the next read is forced
 * to go back to the device -- the complement to cetrafs_bread_uncached()
 * above, used when a caller knows a *specific* block's ownership just
 * changed hands (a Zone Group or inode just claimed/reclaimed) rather
 * than needing every read of it to always bypass the cache. Same
 * dirty-buffer safety as cetrafs_bread_uncached(): never discard a
 * pending unflushed write. Lazy -- doesn't perform any I/O itself, just
 * clears the uptodate bit so whoever next actually reads this block pays
 * for a real fetch.
 */
void cetrafs_invalidate_block(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_find_get_block(sb, block);

    if (!bh)
        return;

    lock_buffer(bh);
    if (buffer_uptodate(bh) && !buffer_dirty(bh))
        clear_buffer_uptodate(bh);
    unlock_buffer(bh);

    brelse(bh);
}

/*
 * A block is about to be FREED: drop this node's cached copy of it,
 * dirty or not. cetrafs_invalidate_block() above deliberately leaves a
 * dirty buffer alone -- right for a block we still own, whose pending
 * write is the newest content -- and exactly wrong for one we are
 * giving away: that pending write would land after the next owner's.
 * Taking the buffer lock waits out a write already in flight, which
 * lands while the block is still ours and is harmless.
 */
/*
 * Self-fence: discard every dirty metadata buffer this node holds, without
 * writing it.
 *
 * Fenced means a peer has declared this node dead and taken its Zone
 * Groups, locks and journal; from then on every image this node had
 * dirtied -- allocation bitmaps set with sync=false, tree blocks waiting
 * for a boundary -- is a write aimed at blocks somebody else now owns.
 * The entry points refuse new writes and writepages refuses file data,
 * but what was already dirty in the block device's cache went out with
 * ordinary writeback, over the new owner's bitmap
 * (tests/kernel/fence_drops_dirty_metadata.sh).
 *
 * Only the dirty state goes: buffers stay mapped and uptodate, because
 * this node still holds references to some of them and a cleared mapping
 * under a later submit_bh() is a BUG. Takes the folio lock, then each
 * buffer's lock (the order writeback uses); a write already in flight is
 * waited out -- it was issued before the fence was noticed, the window
 * the fence has always had. Call from process context with nothing held
 * (the heartbeat).
 */
unsigned long cetrafs_drop_dirty_metadata(struct super_block *sb)
{
    struct address_space *mapping = sb->s_bdev->bd_mapping;
    struct folio_batch fbatch;
    unsigned long dropped = 0;
    pgoff_t index = 0;
    unsigned int nr, i;

    folio_batch_init(&fbatch);
    while ((nr = filemap_get_folios_tag(mapping, &index, (pgoff_t) -1, PAGECACHE_TAG_DIRTY, &fbatch))) {
        for (i = 0; i < nr; i++) {
            struct folio *folio = fbatch.folios[i];
            struct buffer_head *head, *bh;

            folio_lock(folio);
            if (folio->mapping != mapping) {
                folio_unlock(folio);
                continue;
            }
            folio_wait_writeback(folio);
            head = folio_buffers(folio);
            if (head) {
                bh = head;
                do {
                    lock_buffer(bh);
                    if (test_clear_buffer_dirty(bh))
                        dropped++;
                    unlock_buffer(bh);
                    bh = bh->b_this_page;
                } while (bh != head);
            }
            folio_cancel_dirty(folio);
            folio_unlock(folio);
        }
        folio_batch_release(&fbatch);
        cond_resched();
    }
    return dropped;
}

void cetrafs_forget_block(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_find_get_block(sb, block);

    if (!bh)
        return;

    lock_buffer(bh);
    clear_buffer_dirty(bh);
    clear_buffer_uptodate(bh);
    unlock_buffer(bh);

    brelse(bh);
}

/*
 * The {magic, crc} tail that whole-block structures carry so a lock-free
 * reader can tell a torn concurrent write from real corruption
 * (format v0x000F).
 *
 * Generic because three structures need exactly the same thing and only
 * the magic differs: dirent blocks (which have their own implementation
 * in dir.c predating this), extent-leaf blocks and xattr blocks. Each magic is
 * distinct so a block of the wrong KIND is caught rather than parsed as
 * though it were the right one.
 *
 * A record does NOT need this: it lives wholly inside one 512-byte
 * logical sector and cannot tear. These span all eight
 * sectors of their block, so they can.
 */
void cetrafs_blk_tail_stamp(struct buffer_head *bh, u32 magic)
{
    cetrafs_blk_tail_t *tail = (cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);

    tail->magic = cetrafs_cpu_to_le32(magic);
    tail->crc = cetrafs_cpu_to_le32(~crc32c(~0U, bh->b_data, CETRAFS_BLK_TAIL_OFF));
}

/*
 * Structure sanity, which is NOT what the checksum proves.
 *
 * A CRC says the bytes are the ones that were written. It says nothing
 * about whether they make sense, and every field below was trusted the
 * moment the CRC passed: a dirent's name_len went straight to
 * dir_emit(), an xattr's value_len straight to a memcpy() aimed at
 * userspace, an extent header's entry count straight into an array
 * index. A peer running older or broken code, a crafted image, or a
 * flipped bit inside a correctly restamped block all produce exactly
 * that -- hostile values behind a valid checksum.
 *
 * Checked where the block is READ rather than at each use, because
 * eh_entries alone has 69 use sites and a rule that every one of them
 * must remember is a rule one of them will forget.
 *
 * Cost: for an extent leaf or index this is ONE comparison, because
 * that read is on the per-block mapping path and anything proportional
 * to the entry count would land in cetrafs_get_block()'s budget
 * (docs/PERFORMANCE.md). Dirent and xattr blocks are read by namespace
 * and xattr operations only, never per block of data, so there the scan
 * over the entries is affordable and is done.
 */
bool cetrafs_blk_struct_ok_magic(const struct buffer_head *bh, u32 magic)
{
    /* The rules live in cetrafs.h, shared with fsck. */
    return cetrafs_blk_struct_ok(bh->b_data, magic);
}

bool cetrafs_blk_tail_valid(const struct buffer_head *bh, u32 magic)
{
    const cetrafs_blk_tail_t *tail = (const cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);

    if (cetrafs_le32(tail->magic) != magic)
        return false;
    if (cetrafs_le32(tail->crc) != ~crc32c(~0U, bh->b_data, CETRAFS_BLK_TAIL_OFF))
        return false;
    /* Integrity first, then sense. Both failures take the same route --
     * retry fresh, then -EUCLEAN -- because a lockless reader can catch
     * a writer mid-update and see either. */
    return cetrafs_blk_struct_ok_magic(bh, magic);
}

/*
 * Forced-fresh read of a tail-checksummed block, retrying a mismatch.
 *
 * A mismatch is usually NOT corruption: it is a peer's in-flight 4 KiB
 * write seen torn, which converges as soon as that write completes. So
 * back off and re-read, with a budget measured in the time a peer's
 * write takes (milliseconds on a real LUN) rather than in microseconds
 * -- P5's rule, learned when three readers spent a five-attempt budget
 * in a few microseconds against a write that takes milliseconds.
 */
struct buffer_head *cetrafs_blk_tail_bread(struct super_block *sb, u64 lba, u32 magic, const char *what)
{
    int attempt;

    for (attempt = 0; attempt < CETRAFS_BLK_TAIL_READ_RETRIES; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, lba);

        if (bh) {
            if (cetrafs_blk_tail_valid(bh, magic))
                return bh;
            brelse(bh);
        }
        usleep_range(100, 400);
    }

    pr_err("%s block %llu failed its tail checksum %d times -- corrupted, not just a torn concurrent read\n", what,
           (unsigned long long) lba, CETRAFS_BLK_TAIL_READ_RETRIES);
    /* And do not leave it behind. The last attempt's buffer is still
     * cached and uptodate, and a reader that trusts its cache takes an
     * uptodate block as already verified -- so the read that this call
     * just refused would be served, unchecked, by the next one. */
    cetrafs_invalidate_block(sb, lba);
    return NULL;
}
