/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * extwalk.h -- the tools' traversal of an extent tree.
 *
 * The userspace counterpart of kmod/extwalk.c, with the same rules: every
 * child address is range-checked before it is read, every block must sit
 * exactly one level below its parent (so a block naming itself or an
 * ancestor cannot make the walk go round, rule 14), and the walk is
 * bounded by the record's depth. What the kernel does with a bad block --
 * refuse the whole walk -- a checker cannot afford: it has to say what is
 * wrong and, where it can, go on. So every block that cannot be walked is
 * handed to the caller's 'bad' hook, which reports it and decides.
 */
#ifndef CETRAFS_EXTWALK_H
#define CETRAFS_EXTWALK_H

#include <stdint.h>
#include <string.h>

#include "../include/cetrafs.h"

enum cetrafs_utw_bad {
    CETRAFS_UTW_RANGE, /* the address is outside the volume (blk NULL) */
    CETRAFS_UTW_TAIL,  /* the block failed its tail checksum */
    CETRAFS_UTW_DEPTH, /* not an extent block at the level its parent implies */
};

struct cetrafs_utw;
struct cetrafs_utw_ops {
    /* Read block 'lba' into blk (CETRAFS_BLOCK_SIZE bytes). */
    void (*read)(struct cetrafs_utw *w, uint64_t lba, uint8_t *blk);
    /* 0 when blk's tail verifies with 'magic'. */
    int (*tail)(const uint8_t *blk, uint32_t magic);
    /* A child at 'level' that cannot be walked. Nonzero: the caller has
     * accounted for it and the walk goes on without it; 0 stops the walk
     * (cetrafs_utw_walk() returns -1). [rlo, rhi) as for 'leaf'. */
    int (*bad)(struct cetrafs_utw *w, uint64_t lba, int level, enum cetrafs_utw_bad why, const uint8_t *blk,
               uint64_t rlo, uint64_t rhi);
    /* An external block that checked out, before its entries. */
    void (*node)(struct cetrafs_utw *w, uint64_t lba, int level);
    /* An index node with no entries (lba 0: the record's root). */
    void (*empty)(struct cetrafs_utw *w, uint64_t lba, int level);
    /* A leaf's entries (lba 0: the record's inline array), with the
     * narrowest logical range [rlo, rhi) the external index entries on its
     * path allow -- (0, 0) when none bounds it. Root slots never bound it. */
    void (*leaf)(struct cetrafs_utw *w, const cetrafs_extent_t *arr, uint32_t n, uint64_t lba, uint64_t rlo,
                 uint64_t rhi);
};

struct cetrafs_utw {
    const struct cetrafs_utw_ops *ops;
    uint64_t total_blocks; /* addresses at or past this are out of range */
    void *ctx;
};

/* [rlo, rhi) narrowed by one index entry's range (end 0: no bound). */
static inline void cetrafs_utw_narrow(const cetrafs_extent_idx_t *ie, uint64_t *rlo, uint64_t *rhi)
{
    if (!cetrafs_ei_end(ie))
        return;
    if (!*rhi || cetrafs_ei_lo(ie) > *rlo)
        *rlo = cetrafs_ei_lo(ie);
    if (!*rhi || cetrafs_ei_end(ie) < *rhi)
        *rhi = cetrafs_ei_end(ie);
}

static int cetrafs_utw_index(struct cetrafs_utw *w, const cetrafs_extent_idx_t *arr, uint32_t n, uint64_t self,
                             int level, uint64_t rlo, uint64_t rhi)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];

    if (!n && w->ops->empty)
        w->ops->empty(w, self, level);
    for (uint32_t i = 0; i < n; i++) {
        const cetrafs_extent_idx_t ie = arr[i]; /* arr may live in a parent's blk */
        const uint64_t lba = cetrafs_ei_child(&ie);
        const int clevel = level - 1;
        const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) blk;
        uint64_t clo = rlo, chi = rhi;

        /* The record's root slots never narrow: their ranges are not
         * maintained (a root entry is written "unknown", and a depth-1
         * root's range is never widened by an append), as the kernel's
         * walk never filters by them either. */
        if (self)
            cetrafs_utw_narrow(&ie, &clo, &chi);
        if (!lba || lba >= w->total_blocks) {
            if (!w->ops->bad(w, lba, clevel, CETRAFS_UTW_RANGE, NULL, clo, chi))
                return -1;
            continue;
        }
        w->ops->read(w, lba, blk);
        if (w->ops->tail(blk, clevel ? CETRAFS_INDEX_TAIL_MAGIC : CETRAFS_LEAF_TAIL_MAGIC) != 0) {
            if (!w->ops->bad(w, lba, clevel, CETRAFS_UTW_TAIL, blk, clo, chi))
                return -1;
            continue;
        }
        if (cetrafs_le16(h->eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(h->eh_depth) != clevel) {
            if (!w->ops->bad(w, lba, clevel, CETRAFS_UTW_DEPTH, blk, clo, chi))
                return -1;
            continue;
        }
        if (w->ops->node)
            w->ops->node(w, lba, clevel);
        if (clevel) {
            uint32_t cn = cetrafs_le16(h->eh_entries);

            if (cn > CETRAFS_EXT_BLOCK_MAX_IDX)
                cn = CETRAFS_EXT_BLOCK_MAX_IDX;
            if (cetrafs_utw_index(w, (const cetrafs_extent_idx_t *) (blk + sizeof(*h)), cn, lba, clevel, clo, chi))
                return -1;
        } else if (w->ops->leaf) {
            uint32_t cn = cetrafs_le16(h->eh_entries);

            if (cn > CETRAFS_EXT_BLOCK_MAX_LEAVES)
                cn = CETRAFS_EXT_BLOCK_MAX_LEAVES;
            w->ops->leaf(w, (const cetrafs_extent_t *) (blk + sizeof(*h)), cn, lba, clo, chi);
        }
    }
    return 0;
}

/*
 * Walk a record's extent tree. The caller has checked the root's magic,
 * depth (<= CETRAFS_EXT_MAX_DEPTH) and inline count; this clamps the
 * counts it indexes with whatever they say. 0 when the walk ran to the
 * end, -1 when a 'bad' hook stopped it.
 */
static inline int cetrafs_utw_walk(struct cetrafs_utw *w, const cetrafs_inode_t *in)
{
    uint32_t n = cetrafs_le16(in->eh.eh_entries);
    int depth = cetrafs_le16(in->eh.eh_depth);

    if (n > 4)
        n = 4;
    if (!depth) {
        if (w->ops->leaf)
            w->ops->leaf(w, in->et.leaf, n, 0, 0, 0);
        return 0;
    }
    return cetrafs_utw_index(w, in->et.idx, n, 0, depth, 0, 0);
}

#endif /* CETRAFS_EXTWALK_H */
