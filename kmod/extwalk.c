// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * extwalk.c -- the one traversal of an extent tree.
 *
 * Every question asked of a whole tree -- what does this file own, which
 * blocks does it map, is this block one of its tree blocks, how many
 * extents does it hold -- is a walk from the record's root slots down to
 * the leaves. Each of them used to be its own loop, written for depth 0,
 * 1 and 2 by hand, and each one could disagree with the others about
 * which blocks it read, how it read them and what it did with a block it
 * could not read. cetrafs_tree_walk() is that loop, once:
 *
 *  - every external block is read through one policy for the whole walk
 *    (enum cetrafs_tw_read), its address checked as a data address
 *    (rule 19) and its counts checked where it is read;
 *  - every block must sit exactly one level below its parent: a leaf
 *    that says it is an index, or an index one level off, is refused
 *    rather than walked. That bounds the walk at the record's depth
 *    whatever the blocks claim (rule 14);
 *  - an index node's entries are filtered under ONE hold of its buffer
 *    lock and copied out, and that lock is released before any child is
 *    read: never two buffer locks at once;
 *  - a leaf's entries are handed to the caller under the leaf's buffer
 *    lock, the memory this node's tree writers edit in place;
 *  - an index node's children are read as one batch where the read
 *    policy can batch (P12).
 *
 * What this does NOT give is a snapshot of the whole tree: a writer can
 * move entries between two nodes while a walk is between them. Walks
 * whose answer must be complete (the scrub's reference set) detect an
 * overlapping move and walk again (cetrafs_tree_move_begin()).
 */
#include <linux/delay.h>

#include "kmod.h"

/* --- reading tree blocks -------------------------------------------------- */

/* TEST ONLY: a whole-tree walk reads its index and leaf blocks one at a
 * time, as before P12 -- the control of tests/kernel/tree_walk_readahead.sh
 * and tests/kernel/evict_walk_batched.sh. */
static bool cetrafs_flatten_prefetch_off;
cetrafs_test_param(flatten_prefetch_off, cetrafs_flatten_prefetch_off, bool, 0644);
MODULE_PARM_DESC(flatten_prefetch_off, "TEST ONLY: a tree walk reads its extent blocks one at a time");

/*
 * P12: the blocks a walk needs are read as ONE batch, whichever way the
 * walk reads them. A walk used to read each extent leaf in turn, one device
 * round trip apiece, and only a TRUSTED walk at depth 2 had any read-ahead
 * (sb_breadahead, one index block at a time). An UNTRUSTED walk -- an evict
 * of a closed file, a scrub, a reporter whose file a peer has open -- had
 * none, so an unlink of a fragmented file paid ~1000 serial reads before it
 * freed anything (audit 2026-11-14 P12). Every block the walk does not
 * already hold is submitted under one plug and waited for once.
 *
 * A block is accepted here exactly when the per-block reader would accept
 * it -- a trusted cached copy that is uptodate, or a fresh read whose tail
 * verifies -- and its counts check. Everything else (a refused address, a
 * torn or damaged block, a failed read) is left NULL, and the caller reads
 * that one block through cetrafs_read_tree_bh_for(), which retries, refuses
 * and reports exactly as before.
 */
static void cetrafs_tree_batch_fast(struct inode *inode, const sector_t *lbas, u32 n, u32 magic, bool trusted,
                                    struct buffer_head **bhs)
{
    struct super_block *sb = inode->i_sb;
    sector_t *nl = NULL;
    struct buffer_head **nb = NULL;
    u32 *na = NULL;
    u32 i, j, k = 0;

    for (i = 0; i < n; i++) {
        /* An address the reader would refuse, or cannot judge yet: the
         * per-block reader decides, so nothing here is read. */
        int rc = cetrafs_lba_run_check(sb, lbas[i], 1);

        /* -EAGAIN (cannot judge the layout yet) or a refusal: the per-block
         * reader decides, so nothing here is read. */
        if (rc == -EAGAIN || rc)
            return;
    }
    nl = kvmalloc_array(n, sizeof(*nl), GFP_NOFS);
    na = kvmalloc_array(n, sizeof(*na), GFP_NOFS);
    nb = kvcalloc(n, sizeof(*nb), GFP_NOFS);
    if (!nl || !na || !nb)
        goto out; /* not an error: every block goes through the per-block reader */

    for (i = 0; i < n; i++) {
        struct buffer_head *bh = trusted ? sb_getblk(sb, lbas[i]) : NULL;

        if (bh && buffer_uptodate(bh) && cetrafs_blk_struct_ok_magic(bh, magic)) {
            bhs[i] = bh;
            continue;
        }
        brelse(bh);
        nl[k] = lbas[i];
        na[k++] = i;
    }
    if (k && !cetrafs_bread_uncached_list(sb, nl, k, nb)) {
        for (j = 0; j < k; j++) {
            struct buffer_head *bh = nb[j];

            /* The per-block reader's test for a fresh read, plus the counts. */
            if (bh && cetrafs_blk_read_accepts(bh, magic) && cetrafs_blk_struct_ok_magic(bh, magic))
                bhs[na[j]] = bh;
            else
                brelse(bh);
        }
    }
out:
    kvfree(nb);
    kvfree(na);
    kvfree(nl);
}

/*
 * Reads lbas[0..n) into bhs[0..n): as one batch where the batch takes the
 * block, and one at a time through the tree reader for every block it did
 * not take. bhs[i] is NULL only where that reader failed; the caller
 * releases every non-NULL entry.
 */
static void cetrafs_tree_read_batch(struct inode *inode, const sector_t *lbas, u32 n, u32 magic, const char *what,
                                    bool trusted, struct buffer_head **bhs)
{
    u32 i;

    for (i = 0; i < n; i++)
        bhs[i] = NULL;
    if (n >= 2 && !READ_ONCE(cetrafs_flatten_prefetch_off))
        cetrafs_tree_batch_fast(inode, lbas, n, magic, trusted, bhs);
    for (i = 0; i < n; i++) {
        if (!bhs[i])
            bhs[i] = cetrafs_read_tree_bh_trust(inode, lbas[i], magic, what, trusted);
    }
}

/*
 * The scrub's tree read: no struct inode, so no trust rule -- cached on
 * its proposing pass, forced fresh and tail-checked (with the tear retry)
 * on its deciding one. The address is checked first either way (rule 19).
 */
struct buffer_head *cetrafs_scrub_tree_bread(struct super_block *sb, u64 lba, u32 magic, bool fresh)
{
    int attempt;

    if (!cetrafs_lba_run_is_data(sb, lba, 1))
        return NULL;
    if (!fresh)
        return cetrafs_bread_retry(sb, lba); /* pass 1 only proposes candidates */
    for (attempt = 0; attempt < CETRAFS_BLK_TAIL_READ_RETRIES; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, lba);

        if (bh) {
            bool ok;

            cetrafs_bh_read_lock(bh);
            ok = cetrafs_blk_tail_valid(bh, magic);
            cetrafs_bh_read_unlock(bh);
            if (ok)
                return bh;
            brelse(bh);
        }
        if (attempt + 1 < CETRAFS_BLK_TAIL_READ_RETRIES)
            cetrafs_tear_backoff(attempt); /* a peer's write in flight (X1) */
    }
    return NULL;
}

/* Read the n children of one index node, all at 'level'. */
static void cetrafs_tw_read(struct cetrafs_tw *w, const sector_t *lbas, u32 n, int level, struct buffer_head **bhs)
{
    u32 magic = level ? CETRAFS_INDEX_TAIL_MAGIC : CETRAFS_LEAF_TAIL_MAGIC;
    const char *what = level ? "extent index" : "extent leaf";
    u32 i;

    switch (w->read) {
    case CETRAFS_TW_READER:
        cetrafs_tree_read_batch(w->inode, lbas, n, magic, what, cetrafs_lock_read_cache_trusted(w->inode), bhs);
        return;
    case CETRAFS_TW_WRITER:
        cetrafs_tree_read_batch(w->inode, lbas, n, magic, what, cetrafs_lock_held_for_write_locally(w->inode), bhs);
        return;
    case CETRAFS_TW_CACHED:
    case CETRAFS_TW_FRESH:
        cetrafs_tree_read_batch(w->inode, lbas, n, magic, what, w->read == CETRAFS_TW_CACHED, bhs);
        return;
    case CETRAFS_TW_SCRUB:
    case CETRAFS_TW_SCRUB_FRESH:
        for (i = 0; i < n; i++)
            bhs[i] = cetrafs_scrub_tree_bread(w->sb, lbas[i], magic, w->read == CETRAFS_TW_SCRUB_FRESH);
        return;
    }
    for (i = 0; i < n; i++)
        bhs[i] = NULL;
}

/* --- the walk ------------------------------------------------------------- */

/* Tree blocks a walk met a second time and did not walk again (procfs). */
static atomic64_t cetrafs_tree_shared_skips = ATOMIC64_INIT(0);

u64 cetrafs_tree_shared_skip_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_shared_skips);
}

/* TEST ONLY, the scrub walk's knobs (tests/kernel/scrub_walk_torn.sh): a
 * pause between a leaf's read and the walk's buffer lock -- the window an
 * in-place edit has to start in -- and the control that walks leaves with
 * no lock at all. Applied to walks that ask for them (CETRAFS_TW_SCRUB_KNOBS). */
static unsigned int cetrafs_scrub_walk_pause_ms;
cetrafs_test_param(scrub_walk_pause_ms, cetrafs_scrub_walk_pause_ms, uint, 0644);
MODULE_PARM_DESC(scrub_walk_pause_ms, "TEST ONLY: pause in the scrub's leaf walk between the read and the lock");
static bool cetrafs_scrub_walk_unlocked;
cetrafs_test_param(scrub_walk_unlocked, cetrafs_scrub_walk_unlocked, bool, 0644);
MODULE_PARM_DESC(scrub_walk_unlocked, "TEST ONLY: the scrub's leaf walk reads the leaf without the buffer lock");

/* An index node's selected children, one chunk at a time. */
struct cetrafs_tw_chunk {
    u32 cap;
    cetrafs_extent_idx_t *ent;
    sector_t *lba;
    struct buffer_head **bh;
};

/* The on-stack fallback when the scratch cannot be allocated: the walk
 * then reads an index node a few children at a time instead of failing. */
#define CETRAFS_TW_SMALL 4

struct cetrafs_tw_small {
    cetrafs_extent_idx_t ent[CETRAFS_TW_SMALL];
    sector_t lba[CETRAFS_TW_SMALL];
    struct buffer_head *bh[CETRAFS_TW_SMALL];
};

static int cetrafs_tw_index(struct cetrafs_tw *w, struct cetrafs_tw_chunk *lv, struct buffer_head *nbh,
                            const cetrafs_extent_idx_t *inline_arr, u32 inline_n, int level);

/* One child block, read and released by the caller. */
static int cetrafs_tw_block(struct cetrafs_tw *w, struct cetrafs_tw_chunk *lv, struct buffer_head *bh, u64 lba,
                            int level)
{
    const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) bh->b_data;
    bool locked;
    int ret;

    /* Exactly one level below the parent, or the walk stops here: a block
     * that names itself, or an ancestor, as its child cannot then make the
     * walk go round, and nothing deeper than the record says is reached. */
    if (cetrafs_le16(h->eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(h->eh_depth) != level) {
        pr_err_ratelimited("extent %s block %llu: depth %u where %d was expected -- refusing it (fsck)\n",
                           level ? "index" : "leaf", (unsigned long long) lba, cetrafs_le16(h->eh_depth), level);
        return -EIO;
    }
    w->nodes++;
    if (w->ops->node) {
        ret = w->ops->node(w, bh, lba, level);
        if (ret)
            return ret;
    }
    if (level)
        return cetrafs_tw_index(w, lv, bh, NULL, 0, level);
    if (!w->ops->leaf)
        return 0;
    if (unlikely(w->flags & CETRAFS_TW_SCRUB_KNOBS) && READ_ONCE(cetrafs_scrub_walk_pause_ms))
        msleep(READ_ONCE(cetrafs_scrub_walk_pause_ms)); /* TEST ONLY: see the parameter */
    /* Read ONCE: flipped between the lock and the unlock, two reads
     * would unbalance the buffer lock. */
    locked = !(w->flags & CETRAFS_TW_SCRUB_KNOBS) || likely(!READ_ONCE(cetrafs_scrub_walk_unlocked));
    if (locked)
        cetrafs_bh_read_lock(bh);
    ret = w->ops->leaf(w, (const cetrafs_extent_t *) (bh->b_data + sizeof(*h)),
                       min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES), lba);
    if (locked)
        cetrafs_bh_read_unlock(bh);
    return ret;
}

/*
 * One index node at 'level': the record's root slots (inline_arr, no
 * lock) or an external block (nbh, under its buffer lock while entries
 * are taken). lv[level - 1] is this level's chunk.
 */
static int cetrafs_tw_index(struct cetrafs_tw *w, struct cetrafs_tw_chunk *lv, struct buffer_head *nbh,
                            const cetrafs_extent_idx_t *inline_arr, u32 inline_n, int level)
{
    struct cetrafs_tw_chunk *c = &lv[level - 1];
    const cetrafs_extent_idx_t *arr = nbh ? (const cetrafs_extent_idx_t *) (nbh->b_data + sizeof(cetrafs_extent_hdr_t))
                                          : inline_arr;
    u32 pos = 0, n, k, i;
    int ret = 0;

    for (;;) {
        k = 0;
        if (nbh)
            cetrafs_bh_read_lock(nbh);
        n = nbh ? min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) nbh->b_data)->eh_entries),
                        CETRAFS_EXT_BLOCK_MAX_IDX)
                : inline_n;
        while (pos < n && k < c->cap) {
            /* The record's root slots are never asked: their ranges are
             * not maintained (a root entry is written "unknown", and a
             * depth-1 root's range is never widened by an append), so a
             * filter on them could skip a subtree that holds the block. */
            int v = w->ops->want && nbh ? w->ops->want(w, &arr[pos], level - 1) : CETRAFS_TW_DESCEND;

            pos++;
            if (v < 0 || v == CETRAFS_TW_STOP) {
                ret = v;
                break;
            }
            if (v == CETRAFS_TW_SKIP)
                continue;
            c->ent[k] = arr[pos - 1];
            c->lba[k] = cetrafs_ei_child(&c->ent[k]);
            k++;
        }
        if (nbh)
            cetrafs_bh_read_unlock(nbh);
        if (ret)
            return ret; /* stopped while choosing: nothing was read */

        /* A block this walk has already been through is not walked again
         * (cetrafs_tree_walk()). */
        if (w->seen) {
            u32 kept = 0;

            for (i = 0; i < k; i++) {
                int e = xa_insert(w->seen, (unsigned long) c->lba[i], xa_mk_value(1), GFP_NOFS);

                if (e == -EBUSY) {
                    atomic64_inc(&cetrafs_tree_shared_skips);
                    pr_warn_ratelimited("extent tree of ino=%llu names block %llu twice -- walking it once (fsck if "
                                        "it persists)\n",
                                        w->inode ? (unsigned long long) w->inode->i_ino : 0ULL,
                                        (unsigned long long) c->lba[i]);
                    continue;
                }
                c->ent[kept] = c->ent[i];
                c->lba[kept++] = c->lba[i];
            }
            k = kept;
        }

        /* Outside every lock: the per-child hook, which may act on the
         * child or answer for it without a read. A child it answers for
         * is dropped from the read below. */
        if (w->ops->child) {
            u32 kept = 0;

            for (i = 0; i < k; i++) {
                int v = w->ops->child(w, &c->ent[i], level - 1);

                if (v < 0 || v == CETRAFS_TW_STOP)
                    return v;
                if (v != CETRAFS_TW_SKIP) {
                    c->ent[kept] = c->ent[i];
                    c->lba[kept++] = c->lba[i];
                }
            }
            k = kept;
        }
        if (k)
            cetrafs_tw_read(w, c->lba, k, level - 1, c->bh);
        for (i = 0; i < k; i++) {
            struct buffer_head *bh = c->bh[i];
            int rd = bh ? 0 : -EIO;

            c->bh[i] = NULL;
            cond_resched(); /* an index node is up to 254 subtrees (rule 14) */
            if (ret) {
                brelse(bh); /* a stop or an error ahead of this child */
                continue;
            }
            if (bh) {
                ret = cetrafs_tw_block(w, lv, bh, c->lba[i], level - 1);
                brelse(bh);
            } else if (w->flags & CETRAFS_TW_SKIP_UNREADABLE) {
                w->unknown = true;
            } else {
                ret = -EIO;
            }
            /* After the child's whole subtree, with its read's result. */
            if (w->ops->done) {
                int d = w->ops->done(w, c->lba[i], level - 1, rd);

                if (!ret)
                    ret = d;
            }
        }
        if (ret || pos >= n)
            return ret;
    }
}

/* TEST ONLY: the control of tests/kernel/tree_shared_child.sh. */
static bool cetrafs_tree_walk_no_dedup;
cetrafs_test_param(tree_walk_no_dedup, cetrafs_tree_walk_no_dedup, bool, 0644);
MODULE_PARM_DESC(tree_walk_no_dedup, "TEST ONLY: a tree walk walks a block its tree names twice once per name");

/*
 * Walk 'raw's extent tree. Returns 0 when the walk ran to the end,
 * CETRAFS_TW_STOP when a hook stopped it, or a negative errno: the first
 * hook's, or -EIO for a root that is not an extent root, a depth past the
 * format's and any block that could not be read or is not what its parent
 * says (unless CETRAFS_TW_SKIP_UNREADABLE, which skips an unreadable
 * subtree and sets w->unknown). Never -ENOMEM.
 */
int cetrafs_tree_walk(struct cetrafs_tw *w, const cetrafs_inode_t *raw)
{
    struct cetrafs_tw_chunk lv[CETRAFS_EXT_MAX_DEPTH];
    struct cetrafs_tw_small small[CETRAFS_EXT_MAX_DEPTH];
    struct xarray seen;
    void *scratch = NULL;
    u16 depth;
    int i, ret;

    w->unknown = false;
    w->nodes = 0;
    w->seen = NULL;
    if (!w->sb)
        w->sb = w->inode->i_sb;
    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;
    depth = cetrafs_le16(raw->eh.eh_depth);
    if (depth > CETRAFS_EXT_MAX_DEPTH)
        return -EIO;
    if (!depth)
        return w->ops->leaf ? w->ops->leaf(w, raw->et.leaf,
                                           min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)), 0)
                            : 0;
    /* Depth 1 is one external leaf, named by root slot 0: every reader of
     * a depth-1 tree reads that slot and no other. A record claiming more
     * is damaged, and walking slots nobody else reads would make this
     * walk disagree with the lookup about what the file holds. */
    if (depth == 1 && cetrafs_le16(raw->eh.eh_entries) > 1)
        return -EIO;

    /* A whole index node per level, so a node is taken under one lock
     * hold and its children read as one batch; four at a time if that
     * much cannot be had. */
    if (!(w->flags & CETRAFS_TW_ONE))
        scratch = kvmalloc_array(depth, CETRAFS_EXT_BLOCK_MAX_IDX *
                                            (sizeof(cetrafs_extent_idx_t) + sizeof(sector_t) + sizeof(struct buffer_head *)),
                                 GFP_NOFS);
    for (i = 0; i < depth; i++) {
        if (scratch) {
            u8 *p = (u8 *) scratch +
                    (size_t) i * CETRAFS_EXT_BLOCK_MAX_IDX *
                        (sizeof(cetrafs_extent_idx_t) + sizeof(sector_t) + sizeof(struct buffer_head *));

            lv[i].cap = CETRAFS_EXT_BLOCK_MAX_IDX;
            lv[i].ent = (cetrafs_extent_idx_t *) p;
            lv[i].lba = (sector_t *) (p + CETRAFS_EXT_BLOCK_MAX_IDX * sizeof(cetrafs_extent_idx_t));
            lv[i].bh = (struct buffer_head **) (p + CETRAFS_EXT_BLOCK_MAX_IDX *
                                                        (sizeof(cetrafs_extent_idx_t) + sizeof(sector_t)));
        } else {
            lv[i].cap = (w->flags & CETRAFS_TW_ONE) ? 1 : CETRAFS_TW_SMALL;
            lv[i].ent = small[i].ent;
            lv[i].lba = small[i].lba;
            lv[i].bh = small[i].bh;
        }
    }
    /*
     * Every block once. No healthy tree names a block twice, but nothing
     * on the disk stops one from doing it, and interiors that share their
     * children let three blocks describe the format's whole 65.5M extents
     * -- every walk then did 65.5M extents' work, and a flatten copied
     * them (audit 2026-11-15 F-62). Skipped, not refused: a walk is not a
     * snapshot, and one that crosses a writer moving entries between two
     * nodes can meet a block twice for a moment. Walking it once is the
     * right answer for every walk -- a set of blocks to keep, to free or to
     * report never wants a member twice. Depth 1 has one child.
     */
    if (depth >= 2 && !READ_ONCE(cetrafs_tree_walk_no_dedup)) {
        xa_init(&seen);
        w->seen = &seen;
    }
    ret = cetrafs_tw_index(w, lv, NULL, raw->et.idx, min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx)),
                           depth);
    if (w->seen) {
        xa_destroy(&seen);
        w->seen = NULL;
    }
    kvfree(scratch);
    return ret;
}

void cetrafs_tpath_put(struct cetrafs_tpath *p)
{
    int l;

    for (l = 0; l < CETRAFS_EXT_MAX_DEPTH; l++) {
        brelse(p->bh[l]);
        p->bh[l] = NULL;
    }
}

/*
 * The tree's last path: from the record down each node's LAST entry to
 * the level-'upto' node (0: the last leaf, where an append lands).
 * Depth-generic, with the walk's rules: each block exactly one level
 * below its parent, its count taken under the buffer lock and clamped.
 * p->bh[l] holds the path's node at each level from 'upto' up (the
 * caller cetrafs_tpath_put()s it), p->n[l] its count, p->n[depth] the
 * record's, p->slot[l] its entry's index in its parent (the last). -EIO for a block that could not be read; -EUCLEAN for a
 * tree not deeper than 'upto', an empty interior or a block out of place.
 */
int cetrafs_tree_last_path(struct inode *inode, const cetrafs_inode_t *raw, int upto, bool reader,
                           struct cetrafs_tpath *p)
{
    int depth = cetrafs_le16(raw->eh.eh_depth), level;
    u32 n = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx));
    u64 lba;

    memset(p, 0, sizeof(*p));
    p->depth = depth;
    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC || depth <= upto || upto < 0 ||
        depth > CETRAFS_EXT_MAX_DEPTH || !n || (depth == 1 && n > 1))
        return -EUCLEAN;
    p->n[depth] = n;
    lba = cetrafs_ei_child(&raw->et.idx[n - 1]);
    for (level = depth - 1; level >= upto; level--) {
        p->slot[level] = p->n[level + 1] - 1;
        struct buffer_head *bh = cetrafs_read_tree_bh_for(inode, lba,
                                                          level ? CETRAFS_INDEX_TAIL_MAGIC : CETRAFS_LEAF_TAIL_MAGIC,
                                                          level ? "extent index" : "extent leaf", reader);
        const cetrafs_extent_hdr_t *h;
        u32 cap = level ? CETRAFS_EXT_BLOCK_MAX_IDX : CETRAFS_EXT_BLOCK_MAX_LEAVES;

        if (!bh) {
            cetrafs_tpath_put(p);
            return -EIO;
        }
        p->bh[level] = bh;
        h = (const cetrafs_extent_hdr_t *) bh->b_data;
        if (cetrafs_le16(h->eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(h->eh_depth) != level)
            goto fail;
        cetrafs_bh_read_lock(bh);
        n = min_t(u32, cetrafs_le16(h->eh_entries), cap);
        if (level && n)
            lba = cetrafs_ei_child((const cetrafs_extent_idx_t *) (bh->b_data + sizeof(*h)) + n - 1);
        cetrafs_bh_read_unlock(bh);
        p->n[level] = n;
        if (level > upto && !n)
            goto fail;
    }
    return 0;
fail:
    cetrafs_tpath_put(p);
    return -EUCLEAN;
}

/* The level-'upto' node of the last path (cetrafs_tree_last_path()), and
 * the counts on the way (counts[l] for l from 'upto' to the depth). */
struct buffer_head *cetrafs_tree_last_node(struct inode *inode, const cetrafs_inode_t *raw, int upto, bool reader,
                                           u32 *counts)
{
    struct cetrafs_tpath p;
    struct buffer_head *bh;
    int l;

    if (cetrafs_tree_last_path(inode, raw, upto, reader, &p))
        return NULL;
    if (counts)
        for (l = upto; l <= p.depth; l++)
            counts[l] = p.n[l];
    bh = p.bh[upto];
    p.bh[upto] = NULL;
    cetrafs_tpath_put(&p);
    return bh;
}
