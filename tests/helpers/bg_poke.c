// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bg_poke.c -- test-only helper: set a Block Group's cached
 * free_data_blocks on a raw cetrafs image, correctly recomputing its
 * checksum so the kernel module accepts the result.
 *
 * Exists solely so tests/mount_test.sh can simulate "this BG is full"
 * without actually writing hundreds of MiB of real data to exhaust a
 * real Block Group (mkfs enforces a 512 MiB BG-size floor, far too slow
 * to fill for real in a test) -- see cetrafs_alloc_pick_bg()'s on-demand
 * extra-ZG-claim path (zonegroup.c) for what this exercises.
 * Same pattern as zg_poke.c/inode_lock_poke.c: reuses the real struct and
 * the real crc32c_struct() mkfs/fsck already use, so there's no risk of
 * the poke and the on-disk format drifting apart. Not part of the normal
 * build (no Makefile target); compiled ad hoc by the test script.
 *
 * Usage: bg_poke <image> <bg_id> <free_data_blocks>
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <stdbool.h>
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
    /* A 4th argument "sync-zg" also moves the owning Zone Group's
     * aggregate by the same delta, so the ZG<->sum(BG) cross-check stays
     * satisfied and the ONLY fault left on the image is the BG counter
     * disagreeing with its own bitmap. Without that, poking the BG alone
     * trips the ZG check first and a control asserting the new check
     * would be passing for the wrong reason. */
    /* A 5th argument "fill-bitmap" also sets every data bitmap bit, so
     * the Block Group is GENUINELY full rather than merely claiming to
     * be. Needed because a mount now reconciles a cached
     * count against its own bitmap, so a counter poked to 0 over an
     * empty bitmap is corrected straight back and a test simulating
     * "this BG is full" would silently stop simulating anything. */
    /* --dump prints the count and its ownership epoch; --bumpseq advances
     * reconcile_seq exactly as a stealing peer's reconcile would (v0x0004,
     * for bg_delta_vs_steal.sh: the kernel's delta-apply must then DROP
     * its stale delta instead of double counting the thief's recount). */
    int dump = (argc == 4 && strcmp(argv[3], "--dump") == 0);
    int bumpseq = (argc == 4 && strcmp(argv[3], "--bumpseq") == 0);

    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: %s <image> <bg_id> <free_data_blocks> [sync-zg|fill-bitmap]\n", argv[0]);
        fprintf(stderr, "       %s <image> <bg_id> --dump | --bumpseq\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    uint32_t bg_id = (uint32_t) strtoul(argv[2], NULL, 0);
    uint64_t free_blocks = (dump || bumpseq) ? 0 : (uint64_t) strtoull(argv[3], NULL, 0);

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(fd, &sb, sizeof(sb), 0);

    if (bg_id >= cetrafs_le32(sb.block_group_count)) {
        fprintf(stderr, "bg_id %u out of range (block_group_count=%u)\n", bg_id, sb.block_group_count);
        return 1;
    }

    bool fill_bitmap = (argc == 5 && strcmp(argv[4], "fill-bitmap") == 0);

    off_t bg_off = (off_t) (cetrafs_le64(sb.bg_table_start) + bg_id) * CETRAFS_BLOCK_SIZE;
    cetrafs_block_group_t bg;
    pread_all(fd, &bg, sizeof(bg), bg_off);

    if (dump) {
        printf("free_data_blocks=%llu reconcile_seq=%llu\n", (unsigned long long) cetrafs_le64(bg.free_data_blocks),
               (unsigned long long) cetrafs_le64(bg.reconcile_seq));
        close(fd);
        return 0;
    }

    if (bumpseq) {
        bg.reconcile_seq = cetrafs_cpu_to_le64(cetrafs_le64(bg.reconcile_seq) + 1);
        bg.checksum = 0;
        bg.checksum = cetrafs_cpu_to_le64(
            crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum), sizeof(cetrafs_le64(bg.checksum))));
        pwrite_all(fd, &bg, sizeof(bg), bg_off);
        close(fd);
        printf("bg_poke: BG%u reconcile_seq -> %llu (a thief's reconcile)\n", bg_id,
               (unsigned long long) cetrafs_le64(bg.reconcile_seq));
        return 0;
    }

    int64_t delta = (int64_t) free_blocks - (int64_t) cetrafs_le64(bg.free_data_blocks);
    uint32_t owner_zg = cetrafs_le16(bg.owner_zg);

    bg.free_data_blocks = cetrafs_cpu_to_le64(free_blocks);
    bg.checksum = 0;
    bg.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum), sizeof(cetrafs_le64(bg.checksum))));

    pwrite_all(fd, &bg, sizeof(bg), bg_off);

    if (fill_bitmap) {
        /* Mark every data block in use, so the bitmap agrees with a
         * free count of 0 and survives the mount-time reconcile. The
         * tail bits past data_block_count are set too: they are padding
         * in a region the allocator never walks past, and nothing reads
         * them. */
        uint64_t bmap_blocks = cetrafs_le32(bg.off_data_region) - cetrafs_le32(bg.off_data_bmap);
        off_t bmap_off = (off_t) (cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_bmap)) * CETRAFS_BLOCK_SIZE;
        uint8_t *ones = malloc(CETRAFS_BLOCK_SIZE);

        if (!ones) {
            perror("malloc");
            return 1;
        }
        memset(ones, 0xFF, CETRAFS_BLOCK_SIZE);
        for (uint64_t b = 0; b < bmap_blocks; b++)
            pwrite_all(fd, ones, CETRAFS_BLOCK_SIZE, bmap_off + (off_t) b * CETRAFS_BLOCK_SIZE);
        free(ones);
        printf("bg_poke: BG%u data bitmap filled (%llu block(s)) -- genuinely full\n", bg_id,
               (unsigned long long) bmap_blocks);
    }

    if (argc == 5 && strcmp(argv[4], "sync-zg") == 0) {
        off_t zg_off = (off_t) (cetrafs_le64(sb.zg_table_start) + owner_zg) * CETRAFS_BLOCK_SIZE;
        cetrafs_zone_group_t zg;

        pread_all(fd, &zg, sizeof(zg), zg_off);
        zg.free_data_blocks = cetrafs_cpu_to_le64((uint64_t) ((int64_t) cetrafs_le64(zg.free_data_blocks) + delta));
        /* free_data_blocks is a HOT field (v0x0009): restamp only the
         * hot checksum; the cold half is untouched. */
        zg.hot_checksum = 0;
        zg.hot_checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct((const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                                                   offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF,
                                                   sizeof(zg.hot_checksum)));
        pwrite_all(fd, &zg, sizeof(zg), zg_off);
        printf("bg_poke: ZG%u aggregate moved by %lld to stay consistent\n", owner_zg, (long long) delta);
    }

    close(fd);

    printf("bg_poke: BG%u free_data_blocks -> %llu\n", bg_id, (unsigned long long) free_blocks);
    return 0;
}
