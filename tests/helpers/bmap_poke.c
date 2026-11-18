// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bmap_poke.c -- test-only helper: read, set or clear one bit of an
 * on-disk bitmap (the inode bitmap, or a Block Group's data bitmap).
 *
 * Every bitmap is 512-byte sectors of CETRAFS_BMAP_SECTOR_BITS bits, each
 * ending in a trailer with its own CRC (include/cetrafs.h), so a bit is
 * NOT at byte bit/8 of the bitmap, and a byte poked there leaves a sector
 * whose checksum fails. This is the one place a suite reaches a bitmap
 * bit; it maps the bit with the format's own helpers and restamps the
 * sector after a change -- unless 'raw' is given, which leaves the
 * checksum as it was, a fault for a test to inject.
 *
 * Usage: bmap_poke <image> <bitmap_start_lba> <bit>              print 0|1
 *        bmap_poke <image> <bitmap_start_lba> <bit> <0|1> [raw]  set it
 *        bmap_poke <image> <bitmap_start_lba> count <first> <n>  set bits in the run
 *        bmap_poke <image> <bitmap_start_lba> clear0 <first> <n> first clear bit
 *                                                                in the run, or -1
 * The inode bitmap's bit for inode N is N - 1 from inode_bmap_start
 * (the table's first segment); a data block's is its offset in its
 * Block Group's data region, from the group's off_data_bmap.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

/* Bit 'bit' of the bitmap at 'start': its block read once per block. */
static int bit_at(int fd, uint64_t start, uint64_t bit)
{
    static uint8_t blk[CETRAFS_BLOCK_SIZE];
    static uint64_t have = UINT64_MAX;
    const uint64_t lba = start + cetrafs_bmap_blk(bit);
    const uint64_t off = cetrafs_bmap_off(bit);

    if (lba != have) {
        if (pread(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE) != (ssize_t) sizeof(blk)) {
            perror("pread");
            exit(1);
        }
        have = lba;
    }
    return (blk[off / 8] >> (off % 8)) & 1;
}

int main(int argc, char **argv)
{
    uint64_t start, bit, first, n, i, set = 0;
    int fd, old;

    if (argc == 6 && (!strcmp(argv[3], "count") || !strcmp(argv[3], "clear0"))) {
        start = strtoull(argv[2], NULL, 0);
        first = strtoull(argv[4], NULL, 0);
        n = strtoull(argv[5], NULL, 0);
        fd = open(argv[1], O_RDONLY);
        if (fd < 0) {
            perror(argv[1]);
            return 1;
        }
        for (i = first; i < first + n; i++) {
            if (!strcmp(argv[3], "clear0") && !bit_at(fd, start, i)) {
                printf("%" PRIu64 "\n", i);
                return 0;
            }
            set += (uint64_t) bit_at(fd, start, i);
        }
        if (!strcmp(argv[3], "clear0"))
            printf("-1\n");
        else
            printf("%" PRIu64 "\n", set);
        return 0;
    }
    if (argc < 4 || argc > 6 || (argc == 6 && strcmp(argv[5], "raw"))) {
        fprintf(stderr, "usage: %s <image> <bitmap_start_lba> <bit> [<0|1> [raw]] | count|clear0 <first> <n>\n", argv[0]);
        return 2;
    }
    start = strtoull(argv[2], NULL, 0);
    bit = strtoull(argv[3], NULL, 0);
    fd = open(argv[1], argc >= 5 ? O_RDWR : O_RDONLY);
    if (fd < 0) {
        perror(argv[1]);
        return 1;
    }
    if (argc == 4) {
        printf("%d\n", bit_at(fd, start, bit));
        return 0;
    }
    old = cetrafs_bmap_poke_us(fd, start, bit, atoi(argv[4]) != 0, argc == 6);
    if (old < 0 || fsync(fd) != 0) {
        perror("bitmap");
        return 1;
    }
    close(fd);
    return 0;
}
