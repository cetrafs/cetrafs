// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * zg_poke.c -- test-only helper: set a Zone Group's owner_node_id on a
 * raw cetrafs image, correctly recomputing its checksum so fsck/the
 * kernel module accept the result.
 *
 * Exists solely so tests/mount_test.sh can simulate "this ZG is already
 * claimed by a different node" (the no-CAW mount-refusal gate) without
 * hand-deriving cetrafs_zone_group_t's on-disk offsets --
 * it just uses the real struct and the real crc32c_struct() mkfs/fsck
 * already use, so there's no risk of the poke and the format drifting
 * apart. Not part of the normal build (no Makefile target); compiled
 * ad hoc by the test script.
 *
 * Usage: zg_poke <image> <zg_id> <owner_node_id>
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static void pread_all(int fd, void *buf, size_t len, off_t off)
{
    if (pread(fd, buf, len, off) != (ssize_t) len) {
        perror("pread");
        exit(1);
    }
}

static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    if (pwrite(fd, buf, len, off) != (ssize_t) len) {
        perror("pwrite");
        exit(1);
    }
}

int main(int argc, char **argv)
{
    /* Three args reads the record, four writes it. The read-back mode
     * is what lets a test assert what the owner IS, rather than only
     * what it was set to -- see tests/kernel/zg_counter_vs_ownership.sh,
     * which needs to know whether an unrelated write reverted it. */
    if (argc != 3 && argc != 4 && argc != 5) {
        fprintf(stderr, "usage: %s <image> <zg_id> [<owner_node_id>]\n", argv[0]);
        fprintf(stderr, "       %s <image> <zg_id> free <blocks>   (set the aggregate)\n", argv[0]);
        fprintf(stderr, "       %s <image> <zg_id> badsum           (invalidate the hot checksum)\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    uint32_t zg_id = (uint32_t) strtoul(argv[2], NULL, 0);
    bool free_mode = (argc == 5 && !strcmp(argv[3], "free"));
    bool badsum_mode = (argc == 4 && !strcmp(argv[3], "badsum"));
    bool write_mode = (argc == 4) || free_mode;
    uint16_t owner = (argc == 4) ? (uint16_t) strtoul(argv[3], NULL, 0) : 0;
    uint64_t set_free = free_mode ? strtoull(argv[4], NULL, 0) : 0;

    int fd = open(path, write_mode ? O_RDWR : O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(fd, &sb, sizeof(sb), 0);

    if (zg_id >= cetrafs_le32(sb.zone_group_count)) {
        fprintf(stderr, "zg_id %u out of range (zone_group_count=%u)\n", zg_id, sb.zone_group_count);
        return 1;
    }

    off_t zg_off = (off_t) (cetrafs_le64(sb.zg_table_start) + zg_id) * CETRAFS_BLOCK_SIZE;
    cetrafs_zone_group_t zg;
    pread_all(fd, &zg, sizeof(zg), zg_off);

    if (!write_mode) {
        printf("owner_node_id=%u free_data_blocks=%llu\n", (unsigned) cetrafs_le16(zg.owner_node_id),
               (unsigned long long) cetrafs_le64(zg.free_data_blocks));
        close(fd);
        return 0;
    }

    if (badsum_mode) {
        /* Flip the hot checksum and nothing else: the record's fields
         * stay plausible, so only the reader's verification can catch
         * it. Any ordinary write mode below restores it. */
        zg.hot_checksum = cetrafs_cpu_to_le64(cetrafs_le64(zg.hot_checksum) ^ 0xFFFFFFFFFFFFFFFFull);
        pwrite_all(fd, &zg, sizeof(zg), zg_off);
        close(fd);
        printf("zg_poke: ZG%u hot checksum invalidated\n", zg_id);
        return 0;
    }

    if (free_mode)
        zg.free_data_blocks = cetrafs_cpu_to_le64(set_free);
    else
        zg.owner_node_id = cetrafs_cpu_to_le16(owner);
    /* v0x0009: owner_node_id is a HOT field -- restamp the hot checksum
     * only (the cold half is untouched and its checksum still valid). */
    zg.hot_checksum = 0;
    zg.hot_checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct((const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                                               offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF,
                                               sizeof(zg.hot_checksum)));

    pwrite_all(fd, &zg, sizeof(zg), zg_off);
    close(fd);

    if (free_mode)
        printf("zg_poke: ZG%u free_data_blocks -> %llu\n", zg_id, (unsigned long long) set_free);
    else
        printf("zg_poke: ZG%u owner_node_id -> %u\n", zg_id, owner);
    return 0;
}
