// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Check, corrupt or restamp the v0x000F tail checksum of an inode's
 * external extent-leaf block or its xattr block.
 *
 * A single kernel cannot TEAR a 4 KiB write -- reader and writer share
 * one buffer cache and serialise on the buffer lock -- so a loop-device
 * test cannot produce the state the tail exists to catch. What it can
 * do is produce the same OBSERVABLE: a block whose tail does not match
 * its contents. "restamp" exists so the control can show the file is
 * otherwise intact, i.e. that only the tail was ever wrong.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static int fd;

static void rd(void *b, size_t n, off_t o)
{
    if (pread(fd, b, n, o) != (ssize_t) n) {
        perror("pread");
        exit(1);
    }
}

static void wr(const void *b, size_t n, off_t o)
{
    if (pwrite(fd, b, n, o) != (ssize_t) n) {
        perror("pwrite");
        exit(1);
    }
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> leaf|xattr <ino> check|corrupt|restamp\n", argv[0]);
        return 2;
    }
    const char *kind = argv[2];
    uint64_t ino = strtoull(argv[3], NULL, 0);
    const char *act = argv[4];
    int is_leaf = !strcmp(kind, "leaf");

    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    rd(&sb, sizeof(sb), 0);

    uint8_t rec[CETRAFS_BLOCK_SIZE];
    rd(rec, sizeof(rec), (off_t) (cetrafs_le64(sb.inode_table_start) + (ino - 1)) * CETRAFS_BLOCK_SIZE);
    cetrafs_inode_t in;
    memcpy(&in, rec, sizeof(in));

    uint64_t lba;
    uint32_t magic;
    if (is_leaf) {
        if (cetrafs_le16(in.eh.eh_depth) != 1) {
            fprintf(stderr, "inode %" PRIu64 " is depth %u, not 1 -- it has no external leaf\n", ino, in.eh.eh_depth);
            return 1;
        }
        lba = ((uint64_t) cetrafs_le16(in.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[0].ei_leaf_lo);
        magic = CETRAFS_LEAF_TAIL_MAGIC;
    } else {
        if (!in.xattr_block) {
            fprintf(stderr, "inode %" PRIu64 " has no xattr block\n", ino);
            return 1;
        }
        lba = cetrafs_le64(in.xattr_block);
        magic = CETRAFS_XATTR_TAIL_MAGIC;
    }

    uint8_t blk[CETRAFS_BLOCK_SIZE];
    rd(blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
    cetrafs_blk_tail_t *t = (cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);
    uint32_t want = crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF);

    if (!strcmp(act, "check")) {
        int ok = (cetrafs_le32(t->magic) == magic && cetrafs_le32(t->crc) == want);
        printf("blk_tail_poke: %s block %" PRIu64 " magic=0x%08X crc=0x%08X want=0x%08X -> %s\n", kind, lba, t->magic,
               t->crc, want, ok ? "valid" : "INVALID");
        return ok ? 0 : 1;
    }
    if (!strcmp(act, "corrupt")) {
        t->crc = ~t->crc; /* magic intact: this is a TORN image, not a wrong block kind */
        wr(blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
        printf("blk_tail_poke: %s block %" PRIu64 " crc broken\n", kind, lba);
        return 0;
    }
    if (!strcmp(act, "restamp")) {
        t->magic = cetrafs_cpu_to_le32(magic);
        t->crc = cetrafs_cpu_to_le32(want);
        wr(blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
        printf("blk_tail_poke: %s block %" PRIu64 " restamped\n", kind, lba);
        return 0;
    }
    fprintf(stderr, "unknown action %s\n", act);
    return 2;
}
