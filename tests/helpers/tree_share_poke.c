// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * tree_share_poke.c -- test-only: give an inode a depth-3 extent tree
 * whose interior blocks SHARE their children, so a handful of blocks
 * describe far more extents than they hold.
 *
 * Usage:
 *   tree_share_poke <image> <ino> <i2_lba> <i1_lba> <leaf_lba> <k> <phys>
 *
 * Writes, restamped and with valid tails:
 *   leaf_lba: a leaf of CETRAFS_EXT_BLOCK_MAX_LEAVES one-block extents,
 *             logical 0..n-1, every one at <phys>;
 *   i1_lba:   an interior (depth 1) of CETRAFS_EXT_BLOCK_MAX_IDX entries,
 *             every one naming leaf_lba;
 *   i2_lba:   an interior (depth 2) of <k> entries, every one naming i1_lba;
 * and points the inode's record at i2_lba (depth 3, one root slot). The
 * walk then meets k * MAX_IDX * MAX_LEAVES extents. Every block passes
 * the per-block checks (magic, counts, tail, exact levels): only a
 * ceiling on the walk's total can stop it.
 *
 * Writes to the backing file; the caller works on an unmounted image.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static int fd;

static void pread_all(void *buf, size_t len, off_t off)
{
    if (pread(fd, buf, len, off) != (ssize_t) len) {
        perror("pread");
        exit(1);
    }
}

static void pwrite_all(const void *buf, size_t len, off_t off)
{
    if (pwrite(fd, buf, len, off) != (ssize_t) len) {
        perror("pwrite");
        exit(1);
    }
}

static void put_block(uint8_t *blk, uint64_t lba, uint32_t tail_magic)
{
    cetrafs_blk_tail_t *t = (cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);

    t->magic = cetrafs_cpu_to_le32(tail_magic);
    t->crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF));
    pwrite_all(blk, CETRAFS_BLOCK_SIZE, (off_t) lba * CETRAFS_BLOCK_SIZE);
}

static void put_index(uint64_t lba, unsigned depth, unsigned n, uint64_t child, uint64_t span, uint32_t gen)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    cetrafs_extent_hdr_t *h = (cetrafs_extent_hdr_t *) blk;
    cetrafs_extent_idx_t *ix = (cetrafs_extent_idx_t *) (blk + sizeof(*h));
    unsigned i;

    h->eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    h->eh_entries = cetrafs_cpu_to_le16((uint16_t) n);
    h->eh_max = cetrafs_cpu_to_le16((uint16_t) CETRAFS_EXT_BLOCK_MAX_IDX);
    h->eh_depth = cetrafs_cpu_to_le16((uint16_t) depth);
    h->eh_generation = cetrafs_cpu_to_le32(gen);
    for (i = 0; i < n; i++) {
        cetrafs_ei_set_range(&ix[i], 0, span);
        cetrafs_ei_set_child(&ix[i], child);
    }
    put_block(blk, lba, CETRAFS_INDEX_TAIL_MAGIC);
}

int main(int argc, char **argv)
{
    uint64_t ino, i2, i1, leaf, phys, k, n = CETRAFS_EXT_BLOCK_MAX_LEAVES, rec_lba;
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    cetrafs_extent_hdr_t *h = (cetrafs_extent_hdr_t *) blk;
    cetrafs_extent_t *ex = (cetrafs_extent_t *) (blk + sizeof(*h));
    cetrafs_superblock_t sb;
    cetrafs_inode_t rec;
    unsigned i;

    if (argc != 8) {
        fprintf(stderr, "usage: %s <image> <ino> <i2_lba> <i1_lba> <leaf_lba> <k> <phys>\n", argv[0]);
        return 2;
    }
    ino = strtoull(argv[2], NULL, 0);
    i2 = strtoull(argv[3], NULL, 0);
    i1 = strtoull(argv[4], NULL, 0);
    leaf = strtoull(argv[5], NULL, 0);
    k = strtoull(argv[6], NULL, 0);
    phys = strtoull(argv[7], NULL, 0);
    if (!k || k > CETRAFS_EXT_BLOCK_MAX_IDX) {
        fprintf(stderr, "k must be 1..%u\n", (unsigned) CETRAFS_EXT_BLOCK_MAX_IDX);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    pread_all(&sb, sizeof(sb), 0);
    rec_lba = cetrafs_u_ino_lba(fd, &sb, ino, NULL, NULL);
    if (!rec_lba) {
        fprintf(stderr, "ino %" PRIu64 " has no slot\n", ino);
        return 1;
    }

    h->eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    h->eh_entries = cetrafs_cpu_to_le16((uint16_t) n);
    h->eh_max = cetrafs_cpu_to_le16((uint16_t) CETRAFS_EXT_BLOCK_MAX_LEAVES);
    h->eh_generation = cetrafs_cpu_to_le32(0x5a5a0001u);
    for (i = 0; i < n; i++)
        cetrafs_ee_init(&ex[i], i, 1, 0, phys);
    put_block(blk, leaf, CETRAFS_LEAF_TAIL_MAGIC);
    put_index(i1, 1, CETRAFS_EXT_BLOCK_MAX_IDX, leaf, n, 0x5a5a0002u);
    put_index(i2, 2, (unsigned) k, i1, n, 0x5a5a0003u);

    pread_all(&rec, sizeof(rec), (off_t) rec_lba * CETRAFS_BLOCK_SIZE);
    memset(&rec.et, 0, sizeof(rec.et));
    rec.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    rec.eh.eh_entries = cetrafs_cpu_to_le16(1);
    rec.eh.eh_max = cetrafs_cpu_to_le16(4);
    rec.eh.eh_depth = cetrafs_cpu_to_le16(3);
    cetrafs_ei_set_range(&rec.et.idx[0], 0, n);
    cetrafs_ei_set_child(&rec.et.idx[0], i2);
    cetrafs_inode_stamp_crcs_us(&rec);
    pwrite_all(&rec, sizeof(rec), (off_t) rec_lba * CETRAFS_BLOCK_SIZE);
    printf("tree_share_poke: ino %" PRIu64 " -> depth 3, %" PRIu64 " extents through %" PRIu64 "/%" PRIu64
           "/%" PRIu64 "\n",
           ino, k * CETRAFS_EXT_BLOCK_MAX_IDX * n, i2, i1, leaf);
    return 0;
}
