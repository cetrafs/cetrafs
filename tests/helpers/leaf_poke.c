// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * leaf_poke.c -- test-only helper for a depth-1 (spilled) file's external
 * extent-leaf block: print where it lives, or rewrite one leaf entry's
 * physical start directly on the loop device's *backing file* -- i.e.
 * invisibly to a live mount's buffer cache, simulating a different
 * node's rewrite of the extent map (a reader
 * node whose cached leaf has gone stale). Same pattern as the other
 * tests/*_poke.c helpers; compiled ad hoc by tests/mount_test.sh.
 *
 * Usage:
 *   leaf_poke <image> leaf <ino>                       -- print leaf LBA
 *   leaf_poke <image> setphys <ino> <entry> <new_phys> -- rewrite one entry
 *
 * Leaf blocks carry no checksum (cetrafs_extent_hdr_t + packed
 * cetrafs_extent_t array only), so no restamping is needed.
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

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s <image> leaf <ino>\n"
                "       %s <image> setphys <ino> <entry> <new_phys>\n",
                argv[0], argv[0]);
        return 2;
    }

    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(&sb, sizeof(sb), 0);

    uint64_t ino = strtoull(argv[3], NULL, 0);
    cetrafs_inode_t rec;
    pread_all(&rec, sizeof(rec), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE /* v0x0007: one record per block */);

    if (cetrafs_le16(rec.eh.eh_depth) != 1) {
        fprintf(stderr, "ino %" PRIu64 " is not depth-1 (depth=%u)\n", ino, rec.eh.eh_depth);
        return 1;
    }

    uint64_t leaf_lba = cetrafs_extent_phys_from_hilo(rec.et.idx[0].ei_leaf_hi, rec.et.idx[0].ei_leaf_lo);

    if (strcmp(argv[2], "leaf") == 0) {
        printf("%" PRIu64 "\n", leaf_lba);
        return 0;
    }

    if (strcmp(argv[2], "setphys") == 0) {
        if (argc != 6) {
            fprintf(stderr, "setphys needs <entry> <new_phys>\n");
            return 2;
        }
        unsigned entry = (unsigned) strtoul(argv[4], NULL, 0);
        uint64_t new_phys = strtoull(argv[5], NULL, 0);

        uint8_t blk[CETRAFS_BLOCK_SIZE];
        pread_all(blk, sizeof(blk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);

        cetrafs_extent_hdr_t *hdr = (cetrafs_extent_hdr_t *) blk;
        cetrafs_extent_t *leaves = (cetrafs_extent_t *) (blk + sizeof(*hdr));

        if (cetrafs_le16(hdr->eh_magic) != CETRAFS_EXT_MAGIC || entry >= cetrafs_le16(hdr->eh_entries)) {
            fprintf(stderr, "leaf block invalid or entry %u out of range (entries=%u)\n", entry, hdr->eh_entries);
            return 1;
        }

        {
            __le16 hi;
            __le32 lo;
            cetrafs_extent_phys_to_hilo(new_phys, &hi, &lo);
            leaves[entry].ee_start_hi = hi;
            leaves[entry].ee_start_lo = lo;
        }
        /* Restamp the v0x000F tail. Without this the kernel rejects the
         * block as a torn read and the suite tests the checksum instead
         * of the staleness it is about -- a poke that leaves a
         * structure invalid stops simulating a peer and starts
         * simulating corruption. */
        {
            cetrafs_blk_tail_t *t = (cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);

            t->magic = cetrafs_cpu_to_le32(CETRAFS_LEAF_TAIL_MAGIC);
            t->crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF));
        }
        pwrite_all(blk, sizeof(blk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);

        printf("leaf_poke: ino %" PRIu64 " leaf@%" PRIu64 " entry %u phys -> %" PRIu64 "\n", ino, leaf_lba, entry,
               new_phys);
        return 0;
    }

    fprintf(stderr, "unknown mode '%s'\n", argv[2]);
    return 2;
}
