// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * iseg_chain_poke.c -- test-only: write a chain of <n> one-inode table
 * segments, three blocks each (header, empty bitmap, zero record), from
 * <lba> on, numbered from <first_id> (zero-based: the inodes before it).
 * Every header verifies; the caller links the chain (sb_poke
 * inode_seg_next, inode_first_count, inodes_count). The cheapest way an
 * image can make a mount walk thousands of segments.
 *
 * usage: iseg_chain_poke <image> <lba> <n> <first_id>
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static void put(int fd, const void *blk, uint64_t lba)
{
    if (pwrite(fd, blk, CETRAFS_BLOCK_SIZE, (off_t) lba * CETRAFS_BLOCK_SIZE) != CETRAFS_BLOCK_SIZE) {
        perror("pwrite");
        exit(1);
    }
}

int main(int argc, char **argv)
{
    uint8_t hdr[CETRAFS_BLOCK_SIZE], bmap[CETRAFS_BLOCK_SIZE] = {0}, rec[CETRAFS_BLOCK_SIZE] = {0};
    uint64_t lba, n, first, i;
    int fd;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> <lba> <n> <first_id>\n", argv[0]);
        return 2;
    }
    lba = strtoull(argv[2], NULL, 0);
    n = strtoull(argv[3], NULL, 0);
    first = strtoull(argv[4], NULL, 0);
    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    cetrafs_bmap_stamp_us(bmap, 1);
    for (i = 0; i < n; i++) {
        cetrafs_seg_hdr_t seg;
        const uint64_t at = lba + 3 * i;

        memset(&seg, 0, sizeof(seg));
        seg.magic = cetrafs_cpu_to_le32(CETRAFS_INOSEG_MAGIC);
        seg.count = cetrafs_cpu_to_le32(1);
        seg.first_id = cetrafs_cpu_to_le32((uint32_t) (first + i));
        seg.next = cetrafs_cpu_to_le64(i + 1 < n ? at + 3 : 0);
        seg.checksum = cetrafs_cpu_to_le64(
            (uint64_t) crc32c_struct(&seg, sizeof(seg), offsetof(cetrafs_seg_hdr_t, checksum), sizeof(seg.checksum)));
        memset(hdr, 0, sizeof(hdr));
        memcpy(hdr, &seg, sizeof(seg));
        put(fd, hdr, at);
        put(fd, bmap, at + 1);
        put(fd, rec, at + 2);
    }
    printf("iseg_chain_poke: %" PRIu64 " segments at %" PRIu64 ".. for inodes %" PRIu64 "..\n", n, lba, first + 1);
    return 0;
}
