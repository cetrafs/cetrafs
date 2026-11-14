// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * pending_poke.c -- test-only helper for the per-ZG pending-free queues
 * (version 0x0006): append an entry to a ZG's queue on a
 * raw image, dump a queue's live entries, or print an inode's first
 * extent (so a test can learn a real allocated block's LBA to queue a
 * free for). Same pattern as the other tests/*_poke.c helpers: reuses
 * include/cetrafs.h directly so the poke can't drift from the on-disk
 * format, compiled ad hoc by tests/mount_test.sh, never part of the
 * normal build.
 *
 * Usage:
 *   pending_poke <image> add <zg_id> <lba> <count>
 *   pending_poke <image> dump <zg_id>          -- prints "lba count" lines
 *   pending_poke <image> dumpgen <zg_id>       -- prints "lba count free_gen" lines
 *   pending_poke <image> extent <ino>          -- prints "lba len" of extent 0
 *
 * An entry is stamped (format 0x000A) with its Block Group's current
 * free_gen, read from the descriptor -- what a live appender writes --
 * unless PENDING_POKE_STAMP names another value (a stale copy).
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"

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

/* The free_gen to stamp an entry for lba with: PENDING_POKE_STAMP if set,
 * else the descriptor's of the group holding lba (first table segment:
 * the test volumes are never grown), else 0. */
static uint64_t stamp_for(const cetrafs_superblock_t *sb, uint64_t lba)
{
    const char *env = getenv("PENDING_POKE_STAMP");
    uint32_t n = cetrafs_le64(sb->bg_table_first_count) ? (uint32_t) cetrafs_le64(sb->bg_table_first_count)
                                                         : cetrafs_le32(sb->block_group_count);

    if (env && *env)
        return strtoull(env, NULL, 0);
    for (uint32_t b = 0; b < n; b++) {
        cetrafs_block_group_t bg;

        pread_all(&bg, sizeof(bg), (off_t) (cetrafs_le64(sb->bg_table_start) + b) * CETRAFS_BLOCK_SIZE);
        if (lba >= cetrafs_le64(bg.start_block) && lba < cetrafs_le64(bg.start_block) + cetrafs_le64(bg.length_blocks))
            return cetrafs_le64(bg.free_gen);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s <image> add <zg_id> <lba> <count> [<free_gen stamp>]\n"
                "       %s <image> put <zg_id> <block> <slot> <lba> <count>   (at that queue block/slot exactly)\n"
                "       %s <image> dump <zg_id>\n"
                "       %s <image> extent <ino>\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }

    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(&sb, sizeof(sb), 0);

    if (strcmp(argv[2], "extent") == 0) {
        uint64_t ino = strtoull(argv[3], NULL, 0);
        cetrafs_inode_t rec;

        pread_all(&rec, sizeof(rec),
                  (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE /* v0x0007: one record per block */);
        if (cetrafs_le16(rec.eh.eh_depth) != 0 || cetrafs_le16(rec.eh.eh_entries) < 1) {
            fprintf(stderr, "ino %" PRIu64 " has no inline extent 0 (depth=%u entries=%u)\n", ino, rec.eh.eh_depth,
                    rec.eh.eh_entries);
            return 1;
        }
        printf("%llu %u\n",
               (unsigned long long) cetrafs_extent_phys_from_hilo(rec.et.leaf[0].ee_start_hi,
                                                                  rec.et.leaf[0].ee_start_lo),
               cetrafs_extent_len(rec.et.leaf[0].ee_len));
        return 0;
    }

    uint32_t zg_id = (uint32_t) strtoul(argv[3], NULL, 0);

    if (zg_id >= cetrafs_le32(sb.zone_group_count)) {
        fprintf(stderr, "zg_id %u out of range (zone_group_count=%u)\n", zg_id, sb.zone_group_count);
        return 1;
    }

    uint64_t qstart = cetrafs_le64(sb.pending_free_start) + (uint64_t) zg_id * cetrafs_le32(sb.pending_free_blocks_per_zg);
    unsigned per_block = CETRAFS_BLOCK_SIZE / sizeof(cetrafs_pending_free_t);

    if (strcmp(argv[2], "dump") == 0 || strcmp(argv[2], "dumpgen") == 0) {
        int gen = strcmp(argv[2], "dumpgen") == 0;

        for (uint32_t qb = 0; qb < cetrafs_le32(sb.pending_free_blocks_per_zg); qb++) {
            cetrafs_pending_free_t ents[CETRAFS_BLOCK_SIZE / sizeof(cetrafs_pending_free_t)];

            pread_all(ents, sizeof(ents), (off_t) (qstart + qb) * CETRAFS_BLOCK_SIZE);
            for (unsigned e = 0; e < per_block; e++) {
                if (!ents[e].lba)
                    continue;
                if (gen)
                    printf("%llu %u %llu\n", (unsigned long long) cetrafs_le64(ents[e].lba),
                           cetrafs_le32(ents[e].count), (unsigned long long) cetrafs_le64(ents[e].free_gen));
                else
                    printf("%llu %u\n", (unsigned long long) cetrafs_le64(ents[e].lba), cetrafs_le32(ents[e].count));
            }
        }
        return 0;
    }

    if (strcmp(argv[2], "add") == 0) {
        if (argc != 6 && argc != 7) {
            fprintf(stderr, "add needs <lba> <count> [<stamp>]\n");
            return 2;
        }
        uint64_t lba = strtoull(argv[4], NULL, 0);
        uint32_t count = (uint32_t) strtoul(argv[5], NULL, 0);
        /* An explicit stamp: a copy queued under an earlier free_gen. */
        int have_stamp = argc == 7;
        uint64_t stamp = have_stamp ? strtoull(argv[6], NULL, 0) : 0;

        for (uint32_t qb = 0; qb < cetrafs_le32(sb.pending_free_blocks_per_zg); qb++) {
            cetrafs_pending_free_t ents[CETRAFS_BLOCK_SIZE / sizeof(cetrafs_pending_free_t)];
            off_t off = (off_t) (qstart + qb) * CETRAFS_BLOCK_SIZE;

            pread_all(ents, sizeof(ents), off);
            for (unsigned e = 0; e < per_block; e++) {
                if (ents[e].lba)
                    continue;
                ents[e].lba = cetrafs_cpu_to_le64(lba);
                ents[e].count = cetrafs_cpu_to_le32(count);
                ents[e].magic = cetrafs_cpu_to_le32(CETRAFS_PENDING_FREE_MAGIC);
                ents[e].free_gen = cetrafs_cpu_to_le64(have_stamp ? stamp : stamp_for(&sb, lba));
                ents[e].pad = 0;
                pwrite_all(ents, sizeof(ents), off);
                printf("pending_poke: ZG%u queued free [%" PRIu64 " +%u)\n", zg_id, lba, count);
                return 0;
            }
        }
        fprintf(stderr, "ZG%u queue is full\n", zg_id);
        return 1;
    }

    /* put: an entry at an exact place -- past an empty run, or in a
     * chosen CAS region -- which 'add' (first free slot) cannot make. */
    if (strcmp(argv[2], "put") == 0) {
        if (argc != 8) {
            fprintf(stderr, "put needs <block> <slot> <lba> <count>\n");
            return 2;
        }
        uint32_t qb = (uint32_t) strtoul(argv[4], NULL, 0);
        unsigned slot = (unsigned) strtoul(argv[5], NULL, 0);
        uint64_t lba = strtoull(argv[6], NULL, 0);
        uint32_t count = (uint32_t) strtoul(argv[7], NULL, 0);
        cetrafs_pending_free_t ents[CETRAFS_BLOCK_SIZE / sizeof(cetrafs_pending_free_t)];
        off_t off = (off_t) (qstart + qb) * CETRAFS_BLOCK_SIZE;

        if (qb >= cetrafs_le32(sb.pending_free_blocks_per_zg) || slot >= per_block) {
            fprintf(stderr, "block %u slot %u is outside ZG%u's queue\n", qb, slot, zg_id);
            return 1;
        }
        pread_all(ents, sizeof(ents), off);
        ents[slot].lba = cetrafs_cpu_to_le64(lba);
        ents[slot].count = cetrafs_cpu_to_le32(count);
        ents[slot].magic = cetrafs_cpu_to_le32(CETRAFS_PENDING_FREE_MAGIC);
        ents[slot].free_gen = cetrafs_cpu_to_le64(stamp_for(&sb, lba));
        ents[slot].pad = 0;
        pwrite_all(ents, sizeof(ents), off);
        printf("pending_poke: ZG%u block %u slot %u holds free [%" PRIu64 " +%u)\n", zg_id, qb, slot, lba, count);
        return 0;
    }

    fprintf(stderr, "unknown mode '%s'\n", argv[2]);
    return 2;
}
