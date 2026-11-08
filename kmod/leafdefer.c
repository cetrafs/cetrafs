// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * leafdefer.c -- a regular file's extent-tree blocks, held back from the
 * device until a durability boundary and then written through the
 * journal.
 *
 * Every 4 KiB guest write into a preallocated image converts a block out
 * of an uninit extent, so its leaf changes on every write. Journaling each
 * change costs three device cache flushes, which is the "unusably slow
 * guest" (file.c, the convert path), so a regular file's leaf and
 * interior edits wait for the next boundary -- close, fsync, sync_fs,
 * unmount. Until 2026-11-08 "wait" meant "left dirty in the buffer
 * cache", and then:
 *
 *  - the boundary wrote them IN PLACE, unjournaled. A 4 KiB leaf on a
 *    512-byte-sector device written across a power cut tears, the tear
 *    destroys the old map with the new one, every read of the range it
 *    maps returns -EIO and fsck cannot repair it: the one way a dying
 *    hypervisor left an image that neither restarts nor repairs
 *    (CRASH-CONSISTENCY C1);
 *  - kernel writeback could write them at ANY moment, with no flush
 *    ahead of them, so a reordering cache could persist a leaf marking a
 *    block written while the block's data or allocation bit was still
 *    volatile (C2) -- and torn, as above;
 *  - nothing dropped a deferred leaf whose block a truncate or punch
 *    freed, so writeback later wrote the old leaf over the block's next
 *    owner.
 *
 * Now a deferred block is NOT dirty. It carries BH_CetraDeferred and a
 * reference that pins it in the cache, and it is listed here with the
 * checksum of the image still on the device (the journal entry's replay
 * guard) and its inode. Writeback never sees it. A boundary writes all
 * of an inode's deferred blocks in one journal batch
 * (cetrafs_journal_write_deferred(): data and bits flushed first, then
 * the entries, a flush, the targets), so a crash anywhere leaves either
 * the old map or one the journal redoes. A free of the block drops it.
 *
 * Everything that treated "dirty" as "this buffer holds a write the
 * device has not seen; do not discard it" now asks cetrafs_bh_pending().
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/fs.h>
#include <linux/pagemap.h>
#include <linux/slab.h>
#include <linux/xarray.h>

#include "kmod.h"

struct cetrafs_deferred {
    struct buffer_head *bh; /* pinned: one reference held while listed */
    u64 ino;
    u32 disk_crc; /* CRC32C of the block as it reads on the device */
};

/*
 * End an update by deferring the block instead of dirtying it. The
 * buffer must be locked in an update (cetrafs_bh_begin_update_crc()),
 * and prev_crc is what that returned: the image before THIS update,
 * which is the device's image the first time the block is deferred.
 *
 * 0: deferred, and the buffer is unlocked. Nonzero: nothing was done and
 * the buffer is STILL LOCKED -- the caller writes it now instead, through
 * cetrafs_journal_write_block() with the same prev_crc.
 */
int cetrafs_bh_defer_update(struct inode *inode, struct buffer_head *bh, u32 prev_crc)
{
    struct xarray *xa = cetrafs_sb_deferred(inode->i_sb);
    struct cetrafs_deferred *d, *old;

    if (!xa)
        return -EINVAL;
    if (buffer_cetra_deferred(bh)) {
        cetrafs_bh_end_update_deferred(bh);
        return 0; /* listed already, with the device's image */
    }
    /* Nothing leaves a tree block dirty any more: its pre-update image
     * would not be the device's, and the replay guard recorded from it
     * would refuse a torn target's redo. Say so; the boundary still
     * writes it. */
    WARN_ON_ONCE(buffer_dirty(bh));
    /* Cannot fail: a block not listed would have to be written now, and
     * a leaf written ahead of its index is the ordering this exists to
     * keep (cetrafs_convert_source_durable()). 24 bytes. */
    d = kmalloc(sizeof(*d), GFP_NOFS | __GFP_NOFAIL);
    d->bh = bh;
    d->ino = inode->i_ino;
    d->disk_crc = prev_crc;
    old = xa_store(xa, bh->b_blocknr, d, GFP_NOFS | __GFP_NOFAIL);
    if (WARN_ON_ONCE(old)) {
        /* Listed without its bit: cannot happen while the pin holds the
         * buffer. Keep the older entry's device image, drop its pin. */
        d->disk_crc = old->disk_crc;
        brelse(old->bh);
        kfree(old);
    }
    cetrafs_bh_end_update_deferred(bh); /* pins it, sets the bit, unlocks */
    return 0;
}

/* The device's checksum for a deferred block, or 'fallback' if it is not
 * deferred. */
u32 cetrafs_deferred_disk_crc(struct super_block *sb, struct buffer_head *bh, u32 fallback)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d;
    u32 crc = fallback;

    if (!xa || !buffer_cetra_deferred(bh))
        return fallback;
    xa_lock(xa);
    d = xa_load(xa, bh->b_blocknr);
    if (d)
        crc = d->disk_crc;
    xa_unlock(xa);
    return crc;
}

/* Unlist one entry: the block was written, freed or dropped. The bit
 * goes under the buffer lock. 'drop': also forget the cached image (a
 * freed block, or a stopped mount's unwritten change). */
static void cetrafs_deferred_unlist(struct xarray *xa, struct cetrafs_deferred *d, bool drop)
{
    cetrafs_bh_undefer(d->bh, drop);
    brelse(d->bh); /* the pin */
    kfree(d);
}

void cetrafs_deferred_clear(struct super_block *sb, struct buffer_head *bh)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d;

    if (!xa || !buffer_cetra_deferred(bh))
        return;
    d = xa_erase(xa, bh->b_blocknr);
    if (d)
        cetrafs_deferred_unlist(xa, d, false);
}

/*
 * Blocks [lba, lba + count) are being freed: a deferred copy of any of
 * them is an edit of a tree that no longer names it, and written later it
 * would land on the block's next owner. Dropped, image and all. Every
 * free goes through __cetrafs_free_data_extent(), which calls this.
 */
void cetrafs_deferred_forget_range(struct super_block *sb, u64 lba, u32 count)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d;
    unsigned long idx;

    if (!xa || !count || xa_empty(xa))
        return;
    xa_for_each_range(xa, idx, d, (unsigned long) lba, (unsigned long) (lba + count - 1)) {
        d = xa_erase(xa, idx);
        if (d)
            cetrafs_deferred_unlist(xa, d, true);
    }
}

/* Snapshot the entries of one inode (or all, ino == 0) with a reference
 * each. *out is kvmalloc'd; the caller brelse()s and kvfree()s. */
static int cetrafs_deferred_collect(struct xarray *xa, u64 ino, struct buffer_head ***out, u32 **crcs,
                                    unsigned int *n)
{
    struct cetrafs_deferred *d;
    unsigned long idx;
    unsigned int cnt = 0, i = 0;

    *out = NULL;
    *crcs = NULL;
    *n = 0;
    xa_lock(xa);
    xa_for_each(xa, idx, d)
        if (!ino || d->ino == ino)
            cnt++;
    xa_unlock(xa);
    if (!cnt)
        return 0;
    *out = kvmalloc_array(cnt, sizeof(**out), GFP_NOFS);
    *crcs = kvmalloc_array(cnt, sizeof(**crcs), GFP_NOFS);
    if (!*out || !*crcs) {
        kvfree(*out);
        kvfree(*crcs);
        *out = NULL;
        *crcs = NULL;
        return -ENOMEM;
    }
    xa_lock(xa);
    xa_for_each(xa, idx, d) {
        if (i == cnt)
            break; /* listed since the count: the next boundary's */
        if (ino && d->ino != ino)
            continue;
        get_bh(d->bh);
        (*out)[i] = d->bh;
        (*crcs)[i] = d->disk_crc;
        i++;
    }
    xa_unlock(xa);
    *n = i;
    return 0;
}

static int cetrafs_deferred_write_set(struct super_block *sb, struct buffer_head **bhs, u32 *crcs, unsigned int n)
{
    bool *written;
    unsigned int i;
    int ret;

    written = kvcalloc(n, sizeof(*written), GFP_NOFS);
    if (!written)
        return -ENOMEM;
    ret = cetrafs_journal_write_deferred(sb, bhs, crcs, n, written);
    for (i = 0; i < n; i++)
        if (written[i])
            cetrafs_deferred_clear(sb, bhs[i]);
    kvfree(written);
    return ret;
}

/* TEST ONLY: the next inode flush fails as a device error would. */
static bool cetrafs_tree_flush_fail_once;
cetrafs_test_param(tree_flush_fail_once, cetrafs_tree_flush_fail_once, bool, 0644);
MODULE_PARM_DESC(tree_flush_fail_once, "TEST ONLY: the next extent-tree block flush fails with -EIO");

/*
 * The boundary: write every deferred tree block of this inode, through
 * the journal, in one batch. Nothing may modify them meanwhile: the
 * caller holds invalidate_lock (mapping_locked) or this takes it shared
 * -- every tree mutator holds it exclusively (CLAUDE.md rule 18), the
 * O_DIRECT completion's conversion included.
 */
int cetrafs_deferred_flush_inode(struct inode *inode, bool mapping_locked)
{
    struct super_block *sb = inode->i_sb;
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct buffer_head **bhs;
    unsigned int n, i;
    u32 *crcs;
    int ret;

    if (cetrafs_tree_flush_fail_once) {
        cetrafs_tree_flush_fail_once = false;
        return -EIO; /* test-only, see the knob */
    }
    if (!xa || xa_empty(xa))
        return 0;
    if (!mapping_locked)
        filemap_invalidate_lock_shared(inode->i_mapping);
    ret = cetrafs_deferred_collect(xa, inode->i_ino, &bhs, &crcs, &n);
    if (!ret && n)
        ret = cetrafs_deferred_write_set(sb, bhs, crcs, n);
    if (!mapping_locked)
        filemap_invalidate_unlock_shared(inode->i_mapping);
    for (i = 0; i < n; i++)
        brelse(bhs[i]);
    kvfree(bhs);
    kvfree(crcs);
    return ret;
}

/*
 * sync_fs and unmount: every deferred block on the mount. An inode still
 * in core is flushed under its own lock; one that is not has no mutator
 * left, and its blocks go as they are.
 */
int cetrafs_deferred_flush_all(struct super_block *sb)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    unsigned long rounds = 0, limit = 0, idx;
    struct cetrafs_deferred *d;
    int ret = 0;

    if (!xa)
        return 0;
    /* Bounded by what is listed now: a writer still deferring blocks
     * must not keep a sync going for ever. */
    xa_lock(xa);
    xa_for_each(xa, idx, d)
        limit++;
    xa_unlock(xa);
    while (!xa_empty(xa) && rounds++ < limit) {
        unsigned long first = 0;
        struct inode *inode;
        u64 ino;
        int r;

        xa_lock(xa);
        d = xa_find(xa, &first, ULONG_MAX, XA_PRESENT);
        ino = d ? d->ino : 0;
        xa_unlock(xa);
        if (!ino)
            break;
        inode = ilookup(sb, ino);
        if (inode) {
            r = cetrafs_deferred_flush_inode(inode, false);
            iput(inode);
        } else {
            struct buffer_head **bhs;
            unsigned int n, i;
            u32 *crcs;

            r = cetrafs_deferred_collect(xa, ino, &bhs, &crcs, &n);
            if (!r && n)
                r = cetrafs_deferred_write_set(sb, bhs, crcs, n);
            for (i = 0; i < n; i++)
                brelse(bhs[i]);
            kvfree(bhs);
            kvfree(crcs);
        }
        if (r) {
            ret = r;
            break; /* left listed: the next sync, or unmount, retries */
        }
    }
    return ret;
}

/*
 * A stopped mount writes nothing (docs/internal/ERRORS.md): its deferred
 * blocks are dropped, as its dirty ones are, and unmount releases what is
 * left the same way. Returns how many.
 */
unsigned long cetrafs_deferred_drop_all(struct super_block *sb)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d;
    unsigned long idx, n = 0;

    if (!xa)
        return 0;
    xa_for_each(xa, idx, d) {
        d = xa_erase(xa, idx);
        if (d) {
            cetrafs_deferred_unlist(xa, d, true);
            n++;
        }
    }
    return n;
}
