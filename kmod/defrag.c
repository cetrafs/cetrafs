// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * defrag.c -- per-file online defragmentation.
 *
 * The mover is INCREMENTAL: it relocates the file's physical blocks into
 * a single contiguous run one step at a time, taking inode_lock only for
 * the duration of each step and dropping it in between, so a file that is
 * CONTINUOUSLY OPEN FOR WRITE (the target workload -- a VM disk image
 * open for months) still gets defragmented, with the VM's own writes
 * interleaving freely between steps. An "inode_lock across the whole
 * move" design would leave exactly those always-open files unreachable,
 * which is the whole point of doing it this way.
 *
 * Each step moves one or more WHOLE original extents from the front of
 * the still-unmoved region into their final contiguous position, then
 * rewrites the extent tree to: [already-moved prefix, as one contiguous
 * run] + [not-yet-moved suffix, still its ORIGINAL extents]. Moving on
 * whole-extent boundaries is not cosmetic -- it's what bounds the
 * intermediate entry count. With k front extents consumed (spanning B
 * blocks, each extent <= CETRAFS_EXT_LEN_MASK), the prefix needs
 * ceil(B/MASK) <= k run entries and the suffix drops k, so the combined
 * tree is always <= the original entry count and can never overflow the
 * single external leaf block. (A naive fixed-block chunk could split a
 * boundary extent and transiently need origcount+1 entries -- which has
 * nowhere to go, since this format chains no further leaf blocks.)
 *
 * The tree is valid and consistent at EVERY step boundary: the suffix
 * still points at its untouched original blocks, the prefix at the new
 * run. An interrupted pass (concurrent unlink/truncate/hole-punch,
 * unmount drain, fence, I/O error, crash) just leaves a
 * partially-defragmented but perfectly correct file -- there is no
 * mid-swap window to recover and no fsck reconciliation needed.
 *
 * Cross-node safety comes from the pass pinning this node's on-disk
 * whole-file exclusive lock (lock.c's cetrafs_lock_defrag_begin()): the
 * file either already had local writers (lock was ours) or the mover
 * claims it exactly as a write-open would, only if the file is idle and
 * fully unlocked. No other NODE can touch the file for the pass's life.
 * LOCAL concurrency is what the per-step inode_lock handles.
 *
 * Triggers (both in lock.c / file.c): the last-writer close reports the
 * final extent count, and -- crucially for always-open files --
 * file.c's extent-append path reports when a growing open file crosses
 * the threshold mid-flight. Either queues the inode (deduped) onto a
 * per-mount ordered workqueue, gated/tuned by the auto_defrag /
 * auto_defrag_extents module params.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/minmax.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/workqueue.h>

#include <linux/mm.h>

#include "kmod.h"

/* TEST ONLY: make invalidate_inode_pages2_range() "fail" after a step's
 * commit, on demand. The abort that used to sit on that failure freed
 * part of the just-committed destination run (cross-file overlap); the
 * forced-drop that replaced it is only testable if the failure can be
 * produced deterministically. */
/* TEST ONLY: skip the preallocated-extent refusal below, which is the
 * only way to show that the refusal -- and not something further down --
 * is what keeps an uninitialized extent's stale blocks out of the
 * file's data. */
/* TEST ONLY: leave the destination run OFF the live-reservation
 * registry, the way it used to be -- the negative control showing that
 * the registration is what stops the scrub reclaiming a move in
 * progress. */
static bool cetrafs_defrag_skip_resv;
module_param_named(defrag_skip_resv, cetrafs_defrag_skip_resv, bool, 0644);
MODULE_PARM_DESC(defrag_skip_resv,
                 "TEST ONLY: do not register the defrag destination run (the scrub may reclaim it mid-move)");

static bool cetrafs_defrag_ignore_uninit;
module_param_named(defrag_ignore_uninit, cetrafs_defrag_ignore_uninit, bool, 0644);
MODULE_PARM_DESC(defrag_ignore_uninit,
                 "TEST ONLY: defrag a file with preallocated extents anyway (publishes their stale blocks)");

static bool cetrafs_defrag_fail_invalidate;
module_param_named(defrag_fail_invalidate, cetrafs_defrag_fail_invalidate, bool, 0644);
MODULE_PARM_DESC(defrag_fail_invalidate,
                 "TEST ONLY: make the post-commit page drop fail, exercising the forced-drop path");

/* Soft cap on blocks relocated per inode_lock hold -- rounded UP to the
 * next whole original extent (always at least one), so a step never
 * splits an extent. Small enough that a VM write rarely waits long for
 * the lock. */
#define CETRAFS_DEFRAG_STEP_BLOCKS 128

/* A file's extent list, read out of the inode (inline) or its one
 * external leaf. 'arr' is caller-allocated (CETRAFS_EXT_BLOCK_MAX_LEAVES
 * entries). */
struct cetrafs_ext_list {
    cetrafs_extent_t *arr;
    u32 count;
    u32 cap; /* entries the caller allocated arr for */
    u16 depth;
    u64 nblocks;     /* total logical blocks covered */
    u64 leaf_lba;    /* external leaf LBA if depth==1, else 0 */
    bool dense;      /* no interior holes: extent i starts where i-1 ended */
    bool has_uninit; /* any extent is preallocated-but-never-written */
};

/* Cap on how fragmented a file this collapser will take on. Each commit
 * rebuilds the shrinking tree (tree_build writes ~entries/255 blocks), so
 * the whole pass is ~O(count^2/255) block writes -- seconds for a
 * realistically fragmented file, ~a minute at this cap, and declined
 * above it (a file that fragmented past 64k extents is better left than
 * churned for many minutes; it still works). */
#define CETRAFS_DEFRAG_MAX_EXTENTS 65536u

static int cetrafs_defrag_read_extents(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_ext_list *el)
{
    struct super_block *sb = inode->i_sb;
    u32 i;
    u64 expect = 0;

    el->depth = cetrafs_le16(raw->eh.eh_depth);
    el->leaf_lba = 0;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;

    if (raw->eh.eh_depth == 0) {
        el->count = min_t(u32, cetrafs_le16(raw->eh.eh_entries), 4);
        memcpy(el->arr, raw->et.leaf, el->count * sizeof(el->arr[0]));
    } else if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        struct buffer_head *bh;
        const cetrafs_extent_hdr_t *hdr;

        el->leaf_lba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        /* defrag pins the file's exclusive write lock for the whole
         * move, so no peer can be rewriting this leaf: cached is correct. */
        bh = cetrafs_bread_retry(sb, el->leaf_lba);
        if (!bh)
            return -EIO;
        hdr = (const cetrafs_extent_hdr_t *) bh->b_data;
        el->count = min_t(u32, cetrafs_le16(hdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
        memcpy(el->arr, bh->b_data + sizeof(*hdr), el->count * sizeof(el->arr[0]));
        brelse(bh);
    } else {
        /* Depth 2 (v2): flatten the whole tree. Beyond the cap it is
         * declined (not failed) -- the file works, it is just left
         * fragmented rather than churned for many minutes. */
        cetrafs_extent_t *flat = NULL;
        u32 n = 0;
        int fret = cetrafs_tree_flatten(inode, raw, &flat, &n);

        if (fret)
            return fret;
        if (n > el->cap) {
            kfree(flat);
            pr_debug("defrag: ino=%llu has %u extents (> cap %u) -- declined\n", (unsigned long long) inode->i_ino, n,
                     el->cap);
            return -EOPNOTSUPP;
        }
        el->count = n;
        if (n)
            memcpy(el->arr, flat, (size_t) n * sizeof(el->arr[0]));
        kfree(flat);
    }

    el->dense = true;
    el->has_uninit = false;
    for (i = 0; i < el->count; i++) {
        if (cetrafs_le32(el->arr[i].ee_block) != expect)
            el->dense = false;
        /* cetrafs_extent_len() MASKS the uninit bit off, so a
         * preallocated extent is indistinguishable from data here
         * unless it is asked about explicitly. See the refusal below
         * for why that mattered. */
        if (cetrafs_extent_is_uninit(el->arr[i].ee_len))
            el->has_uninit = true;
        expect += cetrafs_extent_len(el->arr[i].ee_len);
    }
    el->nblocks = expect;
    return 0;
}

/*
 * Persist a layout of: prefix [0, moved) as a contiguous run at
 * 'dst_base', followed by the suffix [moved, nblocks) copied verbatim
 * from 'suffix' (the original extents, already shifted so entry 0 is the
 * first extent at or after logical 'moved'). Builds a FRESH tree at
 * whatever depth the result needs (0/1/2), publishes the new root, and
 * frees the OLD tree's meta blocks -- so it correctly handles a depth-2
 * file collapsing through depth 1 to depth 0, one step at a time. Caller
 * holds inode_lock and the defrag pin.
 *
 * Fresh-build-and-free (rather than in-place leaf rewrite) is what makes
 * it depth-agnostic and crash-safe: the old tree is intact until the new
 * root is durable, and new/old meta are disjoint (new allocated before
 * old freed). It also keeps raw.blocks honest across a depth change,
 * which the old in-place path did not (a depth-1->0 collapse leaked the
 * leaf from i_blocks).
 */
static int cetrafs_defrag_commit(struct inode *inode,
                                 cetrafs_inode_t *raw,
                                 u64 dst_base,
                                 u64 moved,
                                 u64 nblocks,
                                 const cetrafs_extent_t *suffix,
                                 u32 suffix_count)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_extent_t *out;
    cetrafs_inode_t old = *raw; /* names the OLD tree, freed after publish */
    u32 n = 0, i, cap = suffix_count + 8;
    u64 off, meta = 0;
    int ret;

    out = kvmalloc_array(cap, sizeof(*out), GFP_KERNEL);
    if (!out)
        return -ENOMEM;

    /* Prefix: [0, moved) as contiguous run entries, split at the length cap. */
    for (off = 0; off < moved && n < cap;) {
        u32 len = (u32) min_t(u64, moved - off, (u64) CETRAFS_EXT_LEN_MASK);

        out[n].ee_block = cetrafs_cpu_to_le32((u32) off);
        out[n].ee_pad = 0;
        out[n].ee_len = cetrafs_extent_pack_len(len, 0);
        cetrafs_extent_phys_to_hilo(dst_base + off, &out[n].ee_start_hi, &out[n].ee_start_lo);
        n++;
        off += len;
    }
    /* Suffix: original extents for [moved, nblocks), verbatim. */
    for (i = 0; i < suffix_count && n < cap; i++)
        out[n++] = suffix[i];

    ret = cetrafs_tree_build(inode, out, n, raw, &meta);
    if (ret) {
        *raw = old;
        goto out;
    }
    raw->blocks = cetrafs_cpu_to_le64((nblocks + meta) * (CETRAFS_BLOCK_SIZE / 512));
    {
        u64 fd_seq;

        cetrafs_inode_fd_pub_lock(inode);
        /*
         * Size and times come from the LIVE inode, read under the
         * publish mutex -- NOT from the record image this move started
         * from. The mover re-reads the extent map every step, so the
         * tree it publishes tracks a concurrent local writer -- but
         * raw->size was frozen at move start, and the final step's
         * publish copied it wholesale over a size the owner had grown
         * meanwhile: fresh tree, stale size, fresh stamp. An 8-core
         * churn run lost the owner's extension to exactly this (ino 76:
         * blocks said 95, size said 76 -- a mixed-vintage record), and
         * it is why "defrag an open file" is legal but was not SAFE.
         * Every local size writer updates i_size under locks this mutex
         * orders with, so this read cannot regress (2026-10-29).
         */
        raw->size = cetrafs_cpu_to_le64((u64) i_size_read(inode));
        raw->atime = cetrafs_cpu_to_le64((u64) inode_get_atime_sec(inode));
        raw->mtime = cetrafs_cpu_to_le64((u64) inode_get_mtime_sec(inode));
        fd_seq = cetrafs_inode_fd_seq(inode);
        ret = cetrafs_write_raw_inode_fd(sb, inode->i_ino, raw, inode);
        if (!ret)
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        cetrafs_tree_free_meta(inode, raw); /* undo the fresh tree */
        *raw = old;
        goto out;
    }
    cetrafs_tree_free_meta(inode, &old); /* the old tree's meta is now unreferenced */

out:
    kvfree(out);
    return ret;
}

/*
 * The relocation core, shared by the explicit ioctl and the background
 * worker. Caller must already hold the defrag pin
 * (cetrafs_lock_defrag_begin()). Incremental: see the file header.
 */
int cetrafs_defrag_inode(struct inode *inode, struct cetrafs_defrag_stats *out_stats)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_ext_list el;
    struct cetrafs_defrag_stats stats = {0};
    cetrafs_inode_t raw;
    u64 nblocks, dst_base = 0, moved = 0;
    bool have_dst = false;
    /*
     * The destination run is bitmap-allocated and referenced by NOTHING
     * until each step's commit publishes it -- for the whole move, which
     * for a large file is seconds, not the single get_block() the
     * scrub's leak argument assumes. scrub.c's header states the rule:
     * "anything that leaves a block bitmap-allocated for longer than one
     * get_block() without committing an extent MUST appear there [on the
     * reservation registry]". This run did not, and lock.c's speculative
     * run was the only thing that ever did -- so the background scrub
     * reclaimed a live defrag destination, the allocator handed those
     * blocks to another file, and the commit published them anyway.
     */
    struct cetrafs_resv_span dst_span = {.link = LIST_HEAD_INIT(dst_span.link)};
    int ret;

    el.cap = CETRAFS_DEFRAG_MAX_EXTENTS;
    el.arr = kvmalloc_array(el.cap, sizeof(*el.arr), GFP_KERNEL);
    if (!el.arr)
        return -ENOMEM;

    inode_lock(inode);
    ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        goto out_unlock;
    if (!S_ISREG(inode->i_mode)) {
        ret = -EINVAL;
        goto out_unlock;
    }
    ret = cetrafs_defrag_read_extents(inode, &raw, &el);
    if (ret)
        goto out_unlock;

    stats.extents_before = el.count;
    stats.extents_after = el.count;
    nblocks = el.nblocks;

    if (el.count <= 1) {
        ret = 0; /* already contiguous */
        goto out_unlock;
    }
    if (!el.dense) {
        ret = -EOPNOTSUPP; /* interior holes: block-for-block copy wouldn't hold */
        goto out_unlock;
    }
    if (el.has_uninit && !cetrafs_defrag_ignore_uninit) {
        /*
         * A preallocated extent maps real blocks that have never been
         * written, and reads as zeros BECAUSE of the uninit flag -- the
         * blocks themselves still hold whatever the previous owner left
         * in them. This mover is a block-for-block copy that rebuilds
         * the prefix as one plain (initialized) extent, so it would
         * copy those bytes to the new run and publish them as the
         * file's data: fallocate a range, defrag, read back content
         * that was freed from somewhere else.
         *
         * Found by tests/kernel/churn_oracle.sh, which reported it as
         * "HOLE HOLDS DATA" -- punch a hole, fallocate over it, defrag,
         * and the punched block came back.
         *
         * Declining is the same answer the interior-hole case gets: the
         * file is left fragmented, which costs performance and nothing
         * else. Honouring the flag instead would mean splitting the
         * destination into init/uninit extents, which is a different
         * (and much larger) change than a mover that promises one run.
         */
        ret = -EOPNOTSUPP;
        goto out_unlock;
    }

    /* The span rides INSIDE the allocation -- bits set and span
     * published under one alloc_mutex hold -- because publish-after-
     * return left the run's first blocks stealable for a scrub cycle
     * (322 of them, in a loaded full-gate run). The negative control
     * passes NULL and publishes nothing, same observable as before. */
    ret = cetrafs_alloc_pick_run_resv(sb, nblocks, &dst_base,
                                      cetrafs_defrag_skip_resv ? NULL : &dst_span);
    if (ret)
        goto out_unlock;
    have_dst = true;
    inode_unlock(inode);

    while (moved < nblocks) {
        struct blk_plug plug;
        u64 step_end, b;
        u32 si, suffix_start;

        if (cetrafs_sb_defrag_draining(sb) || cetrafs_sb_is_fenced(sb)) {
            ret = -ECANCELED;
            goto out_free_tail;
        }

        inode_lock(inode);
        /* The step below frees the old physical blocks once the new run
         * is committed, and O_DIRECT bypasses the page cache -- so an
         * already-submitted DIO is aimed straight at those blocks and
         * inode_lock does not exclude it. Wait for it, as the truncate
         * and punch paths do. */
        inode_dio_wait(inode);

        /* Re-read and revalidate: same file (generation), same shape
         * (length + dense), still long enough. Anything else -- a
         * truncate, a hole punch, a spill that changed the layout, inode
         * reuse -- aborts cleanly; the committed prefix is already the
         * file's real data and the suffix still points at valid blocks. */
        ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
        if (ret || cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
            ret = ret ? ret : -ESTALE;
            inode_unlock(inode);
            goto out_free_tail;
        }
        ret = cetrafs_defrag_read_extents(inode, &raw, &el);
        if (ret || el.nblocks != nblocks || !el.dense) {
            ret = ret ? ret : -ECANCELED;
            inode_unlock(inode);
            goto out_free_tail;
        }

        /* Choose this step's end: advance by >= one whole original
         * extent, up to the soft block cap, always landing on an extent
         * boundary (so the committed tree never splits one). */
        {
            u64 off = 0;

            suffix_start = el.count; /* index of first suffix extent after this step */
            step_end = moved;
            for (si = 0; si < el.count; si++) {
                u32 len = cetrafs_extent_len(el.arr[si].ee_len);

                if (off + len <= moved) {
                    off += len; /* already behind the cursor */
                    continue;
                }
                /* this extent starts at or past 'moved' */
                step_end = off + len;
                off += len;
                if (step_end - moved >= CETRAFS_DEFRAG_STEP_BLOCKS) {
                    si++;
                    break;
                }
            }
            suffix_start = si; /* first extent fully past step_end */
        }

        /* Flush this step's page range so the writer's dirty pages reach
         * their CURRENT (old) blocks on disk, then copy old -> new.
         * Source reads are forced-fresh (cetrafs_bread_uncached): file
         * data lives in the inode page cache, a DIFFERENT address space
         * from sb_bread()'s block-device buffer cache, so a plain cached
         * read here can return a stale block-device buffer that never saw
         * the writer's just-flushed data -- the exact data-loss the
         * concurrent-writer test caught. The flush above makes the old
         * block on disk authoritative; the uncached read then gets it. */
        ret = filemap_write_and_wait_range(inode->i_mapping, (loff_t) moved << 12, (((loff_t) step_end) << 12) - 1);
        if (ret) {
            inode_unlock(inode);
            goto out_free_tail;
        }

        blk_start_plug(&plug);
        for (b = moved; b < step_end && !ret; b++) {
            u64 src = 0, o = 0;
            struct buffer_head *sbh, *dbh;
            u32 e;

            for (e = 0; e < el.count; e++) {
                u32 len = cetrafs_extent_len(el.arr[e].ee_len);

                if (b < o + len) {
                    src = cetrafs_extent_phys_from_hilo(el.arr[e].ee_start_hi, el.arr[e].ee_start_lo) + (b - o);
                    break;
                }
                o += len;
            }

            if (src == dst_base + b)
                continue; /* already in place */

            sbh = cetrafs_bread_uncached_retry(sb, src);
            dbh = sbh ? sb_getblk(sb, dst_base + b) : NULL;
            if (!sbh || !dbh) {
                brelse(sbh);
                ret = -EIO;
                break;
            }
            /* Via the helpers: cetrafs_bh_end_update() dirties before
             * unlocking, closing the window in which a forced-fresh
             * reader could take the lock on a clean, uptodate buffer and
             * re-read the destination's OLD content over the copy we
             * just made. */
            cetrafs_bh_begin_update(dbh);
            memcpy(dbh->b_data, sbh->b_data, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_end_update(dbh);
            write_dirty_buffer(dbh, REQ_SYNC);
            brelse(sbh);
            wait_on_buffer(dbh);
            if (!buffer_uptodate(dbh))
                ret = -EIO;
            brelse(dbh);
        }
        blk_finish_plug(&plug);
        if (ret) {
            inode_unlock(inode);
            goto out_free_tail;
        }

        /* Remember the original physical blocks of the [moved, step_end)
         * range so they can be freed after the commit makes the new run
         * authoritative. (Skip any that were already in place.) */
        {
            cetrafs_extent_t *suffix = &el.arr[suffix_start];
            u32 suffix_count = el.count - suffix_start;
            u64 freed_from = moved;

            ret = cetrafs_defrag_commit(inode, &raw, dst_base, step_end, nblocks, suffix, suffix_count);
            if (ret) {
                inode_unlock(inode);
                goto out_free_tail;
            }

            /* The commit just published [0, step_end) on the new run.
             * Advance the cursor BEFORE anything below can fail:
             * out_free_tail frees dst[moved, nblocks) on the promise
             * that [0, moved) is the file's real data, and an abort
             * between a commit and this line used to free 251 committed
             * blocks of an 8 MiB file -- which the allocator then handed
             * to other files (cross-file overlap, found by fsck after a
             * two-writer fill with auto-defrag). */
            moved = step_end;

            /* Drop the file's cached pages for the just-moved range: they
             * hold buffer_heads still mapped to the OLD blocks we're
             * about to free, so a subsequent read (or a racing reader's
             * writeback) through them would touch freed/reallocated
             * space. Clean here (we flushed above and hold inode_lock),
             * so this can't lose a dirty page; next access re-faults
             * against the new mapping and reads our synced new blocks. */
            ret = invalidate_inode_pages2_range(inode->i_mapping, freed_from, step_end - 1);
            if (cetrafs_defrag_fail_invalidate)
                ret = -EBUSY; /* TEST ONLY: a racing reader's page reference, on demand */
            if (ret) {
                /* A failure here is a transient reference (a racing
                 * reader) on a CLEAN page whose content equals the new
                 * blocks. Aborting is not an option: the commit is
                 * published, and a stale page left in the cache still
                 * maps the OLD blocks through its attached buffers, so a
                 * later write through it would land on freed (and by
                 * then reallocated) space. Force the pages out instead
                 * -- clean and flushed, so nothing is lost -- and carry
                 * on with the step. */
                unmap_mapping_range(inode->i_mapping, (loff_t) freed_from << 12, (loff_t) (step_end - freed_from) << 12,
                                    1);
                truncate_inode_pages_range(inode->i_mapping, (loff_t) freed_from << 12, ((loff_t) step_end << 12) - 1);
                pr_info_ratelimited("defrag: ino=%llu forced page drop for blocks [%llu, %llu)\n",
                                    (unsigned long long) inode->i_ino, (unsigned long long) freed_from,
                                    (unsigned long long) step_end);
                ret = 0;
            }

            /* The committed prefix now points at the new run; the old
             * physical blocks for [freed_from, step_end) are
             * unreferenced -- free them (per block, since they were
             * fragmented; foreign-ZG blocks queue automatically). */
            for (b = freed_from; b < step_end; b++) {
                u64 src = 0, o = 0;
                u32 e;

                for (e = 0; e < el.count; e++) {
                    u32 len = cetrafs_extent_len(el.arr[e].ee_len);

                    if (b < o + len) {
                        src = cetrafs_extent_phys_from_hilo(el.arr[e].ee_start_hi, el.arr[e].ee_start_lo) + (b - o);
                        break;
                    }
                    o += len;
                }
                if (src != dst_base + b)
                    cetrafs_free_data_block(sb, src);
            }
        }

        inode_unlock(inode);
        cond_resched();
    }

    /* Done: file lives contiguously at dst_base. Old tree meta (the
     * external leaf, and at depth 2 the interiors) was freed by each
     * cetrafs_defrag_commit() as it published the next tree, so there is
     * nothing left to free here.
     *
     * Carry the final block count into the IN-CORE inode: the commits
     * updated the on-disk record, but inode->i_blocks still holds the
     * pre-defrag value, and the VFS's writeback at close would otherwise
     * write that stale count straight back over the record (a depth-2
     * collapse frees meta blocks, so i_blocks must drop). 'raw' reflects
     * the last commit. (Latent for depth-1->0 collapse before depth 2;
     * harmless there only because i_blocks happened to match.) */
    inode->i_blocks = cetrafs_le64(raw.blocks);
    cetrafs_flush_dirty_free_counts(sb);

    stats.extents_after = CETRAFS_DIV_ROUND_UP(nblocks, (u64) CETRAFS_EXT_LEN_MASK);
    stats.blocks_moved = nblocks;
    ret = 0;
    goto out_done;

out_unlock:
    inode_unlock(inode);
    goto out_done;

out_free_tail:
    /* Free the never-committed tail of the destination run; the
     * committed prefix [0, moved) is the file's real data now. */
    if (have_dst && moved < nblocks) {
        ctrace("DEFRAGFREE-TAIL ino=%llu lba=%llu count=%llu\n", (unsigned long long) inode->i_ino,
               (unsigned long long) (dst_base + moved), (unsigned long long) (nblocks - moved));
        cetrafs_free_data_extent(sb, dst_base + moved, nblocks - moved);
    }
    cetrafs_flush_dirty_free_counts(sb);

out_done:
    /* After the tail free above: the freed remainder must become
     * allocatable again, and the committed prefix is referenced by the
     * file's own extents from here on. */
    cetrafs_resv_unpublish(sb, &dst_span);
    if (out_stats)
        *out_stats = stats;
    kvfree(el.arr);
    return ret;
}

/* ---- automatic background defrag ------------------------------------ */

struct cetrafs_defrag {
    struct workqueue_struct *wq;
};

struct cetrafs_defrag_req {
    struct work_struct work;
    struct super_block *sb;
    u64 ino;
};

static void cetrafs_defrag_worker(struct work_struct *work)
{
    struct cetrafs_defrag_req *req = container_of(work, struct cetrafs_defrag_req, work);
    struct super_block *sb = req->sb;
    struct inode *inode;
    int ret;

    if (cetrafs_sb_is_fenced(sb) || cetrafs_sb_defrag_draining(sb))
        goto out_free;

    inode = cetrafs_iget(sb, req->ino);
    if (IS_ERR(inode))
        goto out_free;

    /* Clear the dedup latch first: a close/append that lands while we
     * work can legitimately re-arm. */
    cetrafs_lock_defrag_unqueue(inode);

    if (S_ISREG(inode->i_mode) && inode->i_nlink > 0) {
        ret = cetrafs_lock_defrag_begin(inode);
        if (ret == 0) {
            struct cetrafs_defrag_stats stats = {0};

            ret = cetrafs_defrag_inode(inode, &stats);
            if (ret == 0 && stats.blocks_moved)
                pr_debug("auto-defrag: ino=%llu extents %llu -> %llu (%llu blocks moved)\n",
                         (unsigned long long) inode->i_ino, (unsigned long long) stats.extents_before,
                         (unsigned long long) stats.extents_after, (unsigned long long) stats.blocks_moved);
            else if (ret == -ECANCELED)
                pr_debug("auto-defrag: ino=%llu stopped early (file in use / unmount); left consistent\n",
                         (unsigned long long) inode->i_ino);
            /*
             * Say so when we DECLINE, too -- but at DEBUG. A decline is
             * a NORMAL outcome, not an anomaly: a sparse file is the
             * usual case for a VM image, and the trigger re-arms on
             * every later append to the same file, so even rate-limited
             * these lines recurred forever in a production dmesg (seen
             * in the field: ~20 lines in 11s for one inode). The trace
             * still answers "why is this image never defragmented?" --
             * it just has to be asked for, via dynamic debug (+p).
             */
            else if (ret == -EOPNOTSUPP)
                pr_debug("auto-defrag: ino=%llu declined: sparse, or fragmented past the collapse cap\n",
                         (unsigned long long) inode->i_ino);
            else if (ret == -ENOSPC)
                pr_debug(
                    "auto-defrag: ino=%llu declined: no contiguous run large enough in the "
                    "zone groups this node owns\n",
                    (unsigned long long) inode->i_ino);
            else if (ret == -ESTALE)
                pr_debug(
                    "auto-defrag: ino=%llu declined: the file changed under us (unlinked, or "
                    "its number reused)\n",
                    (unsigned long long) inode->i_ino);
            else if (ret)
                pr_warn("auto-defrag: ino=%llu failed: %d\n", (unsigned long long) inode->i_ino, ret);

            cetrafs_lock_defrag_end(inode);
            /*
             * A CANCELED move must hand the baton back. The mover's pin
             * made the writer's close skip its own janitor trigger (the
             * release defers the lock-clear to defrag_end and considers
             * nothing), and the cancel means the move did not finish the
             * job -- so if nothing re-queues here, a file whose only
             * close raced one in-flight nudge stays fragmented FOREVER.
             * A full-gate tape showed exactly that staffette: nudge ->
             * begin -> writer's close (pin set, trigger skipped) ->
             * -ECANCELED -> silence. Re-judge it now that the pin is
             * gone; consider()'s own thresholds filter, and a writer
             * that is still active just repeats this handoff until its
             * real last close takes the normal path.
             */
            if (ret == -ECANCELED) {
                cetrafs_inode_t rr;

                if (cetrafs_read_raw_inode_overlaid(sb, inode, &rr) == 0 &&
                    cetrafs_le16(rr.eh.eh_magic) == CETRAFS_EXT_MAGIC) {
                    u32 ext2 = cetrafs_tree_extent_count(inode, &rr);

                    if (ext2)
                        cetrafs_defrag_consider(inode, ext2,
                                                CETRAFS_DIV_ROUND_UP(cetrafs_le64(rr.size), CETRAFS_BLOCK_SIZE));
                }
            }
        } else {
            /* Could not take the file's lock: it is open for write
             * somewhere, or a peer holds it, or the inode was replaced.
             * Also silent until now, and the one most likely to be
             * asked about -- "why is this image never defragmented?" is
             * answered here. */
            pr_debug(
                "auto-defrag: ino=%llu declined: could not take the file lock (%d) -- in use "
                "here or held by a peer\n",
                (unsigned long long) inode->i_ino, ret);
        }
    }

    iput(inode);
out_free:
    kfree(req);
}

/*
 * Fragmentation index: 'extents' as a percentage of the minimum extent
 * count a file of 'nblocks' blocks could occupy. ideal =
 * ceil(nblocks / CETRAFS_EXT_LEN_MASK) (>= 1); a contiguous file (every
 * extent at the length cap) scores exactly 100 no matter how large or
 * how many block groups it spans -- which is why this, not raw extent
 * count or BG spread, is the trigger.
 */
unsigned int cetrafs_frag_index_pct(u64 nblocks, u32 extents)
{
    u64 ideal = CETRAFS_DIV_ROUND_UP(nblocks, (u64) CETRAFS_EXT_LEN_MASK);

    if (ideal == 0)
        ideal = 1;
    return (unsigned int) div64_u64((u64) extents * 100, ideal);
}

void cetrafs_defrag_consider(struct inode *inode, u32 extents, u64 nblocks)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_defrag *d = cetrafs_sb_get_defrag(sb);
    struct cetrafs_defrag_req *req;

    /* Both switches: the mount-wide one (nothing here may pin a file's
     * exclusive lock) and the janitor's own. The module param stays as
     * the cross-mount default. */
    if (!d || !cetrafs_auto_defrag || !cetrafs_sb_defrag_enabled(sb) || !cetrafs_sb_auto_defrag_enabled(sb) ||
        cetrafs_sb_is_fenced(sb) || cetrafs_sb_defrag_draining(sb))
        return;
    /* Regular files only. Directories reach the extent-append path too
     * now that dir.c grows through cetrafs_get_block(), and
     * both the worker and cetrafs_defrag_inode() would reject them --
     * but only after burning a queue slot and the dedup latch. */
    if (!S_ISREG(inode->i_mode))
        return;
    /* Both gates: an absolute extent floor (ignore trivially-small files
     * whose index looks high but whose gain is negligible) AND the real
     * fragmentation index. A big CONTIGUOUS file has many extents but
     * scores 100 -- correctly skipped. */
    if (extents < cetrafs_auto_defrag_min_extents)
        return;
    if (cetrafs_frag_index_pct(nblocks, extents) < cetrafs_auto_defrag_min_pct)
        return;
    if (!cetrafs_lock_defrag_try_queue(inode))
        return; /* already queued */

    req = kmalloc(sizeof(*req), GFP_NOFS);
    if (!req) {
        cetrafs_lock_defrag_unqueue(inode);
        return;
    }

    req->sb = sb;
    req->ino = inode->i_ino;
    INIT_WORK(&req->work, cetrafs_defrag_worker);
    queue_work(d->wq, &req->work);
}

int cetrafs_defrag_init(struct super_block *sb, struct cetrafs_defrag **out_d)
{
    struct cetrafs_defrag *d = kzalloc(sizeof(*d), GFP_KERNEL);

    (void) sb;
    if (!d)
        return -ENOMEM;

    /* Ordered (max_active = 1): one background move at a time per mount,
     * bounding the janitor's I/O footprint on the shared LUN. */
    d->wq = alloc_ordered_workqueue("cetrafs_defrag", 0);
    if (!d->wq) {
        kfree(d);
        return -ENOMEM;
    }

    *out_d = d;
    return 0;
}

void cetrafs_defrag_stop(struct cetrafs_defrag *d)
{
    if (!d)
        return;
    destroy_workqueue(d->wq); /* drains queued + running work first */
    kfree(d);
}
