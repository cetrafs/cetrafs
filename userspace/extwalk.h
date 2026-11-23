/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * extwalk.h -- the tools' traversal of an extent tree.
 *
 * The userspace counterpart of kmod/extwalk.c, with the same rules: every
 * child address is range-checked before it is read, every block must sit
 * exactly one level below its parent (so a block naming itself or an
 * ancestor cannot make the walk go round, rule 14), and the walk is
 * bounded by the record's depth. And, as the kernel's, it walks each block
 * once: index entries that name one child many times -- no healthy tree
 * does, nothing on the disk prevents it -- otherwise multiply the walk
 * below them, three blocks describing 65.5M extents (audit 2026-11-22
 * N-9). A block met again is handed to the 'shared' hook instead.
 * What the kernel does with a bad block --
 * refuse the whole walk -- a checker cannot afford: it has to say what is
 * wrong and, where it can, go on. So every block that cannot be walked is
 * handed to the caller's 'bad' hook, which reports it and decides.
 */
#ifndef CETRAFS_EXTWALK_H
#define CETRAFS_EXTWALK_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cetrafs.h"

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
    /* A block this walk has already been through, named again: not read
     * or walked again. Optional. */
    void (*shared)(struct cetrafs_utw *w, uint64_t lba, int level);
};

/* The blocks one walk has been through: open addressing, 0 is empty (no
 * tree block is at 0 -- the range check refuses it first). */
struct cetrafs_utw_seen {
    uint64_t *slot;
    size_t cap, n;
};

struct cetrafs_utw {
    const struct cetrafs_utw_ops *ops;
    uint64_t total_blocks; /* addresses at or past this are out of range */
    void *ctx;
    /* Set by cetrafs_utw_walk() for the walk's duration. */
    struct cetrafs_utw_seen *seen;
    uint64_t reads; /* blocks read by the last walk */
};

/* TEST ONLY: every name walked, as before N-9 (CETRAFS_FSCK_TEST_WALK_NO_DEDUP). */
static inline int cetrafs_utw_no_dedup(void)
{
    const char *v = getenv("CETRAFS_FSCK_TEST_WALK_NO_DEDUP");

    return v && *v && *v != '0';
}

static inline uint64_t cetrafs_utw_hash(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return x;
}

/* 1 when lba was new to this walk (and is now recorded), 0 when seen. */
static inline int cetrafs_utw_first_visit(struct cetrafs_utw_seen *s, uint64_t lba)
{
    size_t i;

    if (!s)
        return 1;
    if (2 * (s->n + 1) > s->cap) {
        size_t ncap = s->cap ? 2 * s->cap : 64;
        uint64_t *ns = (uint64_t *) calloc(ncap, sizeof(*ns));

        if (!ns) {
            fprintf(stderr, "out of memory walking an extent tree\n");
            exit(3);
        }
        for (i = 0; i < s->cap; i++) {
            size_t j;

            if (!s->slot[i])
                continue;
            for (j = cetrafs_utw_hash(s->slot[i]) & (ncap - 1); ns[j]; j = (j + 1) & (ncap - 1))
                ;
            ns[j] = s->slot[i];
        }
        free(s->slot);
        s->slot = ns;
        s->cap = ncap;
    }
    for (i = cetrafs_utw_hash(lba) & (s->cap - 1); s->slot[i]; i = (i + 1) & (s->cap - 1))
        if (s->slot[i] == lba)
            return 0;
    s->slot[i] = lba;
    s->n++;
    return 1;
}

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
        if (!cetrafs_utw_first_visit(w->seen, lba)) {
            if (w->ops->shared)
                w->ops->shared(w, lba, clevel);
            continue;
        }
        w->ops->read(w, lba, blk);
        w->reads++;
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
    struct cetrafs_utw_seen seen = {NULL, 0, 0};
    int ret;

    w->reads = 0;
    if (n > 4)
        n = 4;
    if (!depth) {
        if (w->ops->leaf)
            w->ops->leaf(w, in->et.leaf, n, 0, 0, 0);
        return 0;
    }
    w->seen = cetrafs_utw_no_dedup() ? NULL : &seen;
    ret = cetrafs_utw_index(w, in->et.idx, n, 0, depth, 0, 0);
    w->seen = NULL;
    free(seen.slot);
    return ret;
}

#endif /* CETRAFS_EXTWALK_H */
