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
 *   leaf_poke <image> setblock <ino> <entry> <new_block> -- rewrite one
 *       entry's LOGICAL start (ee_block), restamped: an alias on purpose
 *   leaf_poke <image> show <ino>                       -- one line per entry
 *   leaf_poke <image> growlen <ino> <entry> <n>        -- entry covers n more
 *       blocks, as a peer appending in place leaves it (restamped)
 *   leaf_poke <image> written <ino> <entry>            -- clear the entry's
 *       uninit flag, as a peer's conversion leaves it (restamped)
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
                "       %s <image> setphys <ino> <entry> <new_phys>\n"
                "       %s <image> setcount <ino> <n>\n"
                "       %s <image> show <ino>\n"
                "       %s <image> growlen <ino> <entry> <n>\n"
                "       %s <image> written <ino> <entry>\n",
                argv[0], argv[0], argv[0], argv[0], argv[0], argv[0]);
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
    pread_all(&rec, sizeof(rec), (off_t) cetrafs_u_ino_lba(fd, &sb, ino, NULL, NULL) * CETRAFS_BLOCK_SIZE /* v0x0007: one record per block */);

    if (cetrafs_le16(rec.eh.eh_depth) != 1) {
        fprintf(stderr, "ino %" PRIu64 " is not depth-1 (depth=%u)\n", ino, cetrafs_le16(rec.eh.eh_depth));
        return 1;
    }

    uint64_t leaf_lba = cetrafs_ei_child(&rec.et.idx[0]);

    if (strcmp(argv[2], "leaf") == 0) {
        printf("%" PRIu64 "\n", leaf_lba);
        return 0;
    }

    if (strcmp(argv[2], "setcount") == 0) {
        /* The leaf's entry count, restamped: integrity-perfect and past
         * what a leaf block holds. */
        uint8_t blk[CETRAFS_BLOCK_SIZE];
        cetrafs_extent_hdr_t *hdr = (cetrafs_extent_hdr_t *) blk;
        cetrafs_blk_tail_t *t = (cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);

        if (argc != 5) {
            fprintf(stderr, "setcount needs <n>\n");
            return 2;
        }
        pread_all(blk, sizeof(blk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);
        hdr->eh_entries = cetrafs_cpu_to_le16((uint16_t) strtoul(argv[4], NULL, 0));
        t->magic = cetrafs_cpu_to_le32(CETRAFS_LEAF_TAIL_MAGIC);
        t->crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF));
        pwrite_all(blk, sizeof(blk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);
        printf("leaf_poke: ino %" PRIu64 " leaf %" PRIu64 " entry count -> %s\n", ino, leaf_lba, argv[4]);
        return 0;
    }

    if (strcmp(argv[2], "show") == 0 || strcmp(argv[2], "growlen") == 0 || strcmp(argv[2], "written") == 0) {
        const int written = strcmp(argv[2], "written") == 0;
        uint8_t blk[CETRAFS_BLOCK_SIZE];
        cetrafs_extent_hdr_t *hdr = (cetrafs_extent_hdr_t *) blk;
        cetrafs_extent_t *leaves = (cetrafs_extent_t *) (blk + sizeof(*hdr));
        unsigned n, i;

        pread_all(blk, sizeof(blk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);
        n = cetrafs_le16(hdr->eh_entries);
        if (cetrafs_le16(hdr->eh_magic) != CETRAFS_EXT_MAGIC || n > CETRAFS_EXT_BLOCK_MAX_LEAVES) {
            fprintf(stderr, "leaf block %" PRIu64 " is not a valid leaf\n", leaf_lba);
            return 1;
        }
        if (argv[2][0] == 's') {
            for (i = 0; i < n; i++)
                printf("ent %u block=%" PRIu64 " phys=%" PRIu64 " len=%u uninit=%d\n", i,
                       cetrafs_ee_lblk(&leaves[i]),
                       cetrafs_ee_pblk(&leaves[i]),
                       (unsigned) cetrafs_ee_len(&leaves[i]), cetrafs_ee_uninit(&leaves[i]));
            return 0;
        }
        if (argc != (written ? 5 : 6)) {
            fprintf(stderr, "%s needs <entry>%s\n", argv[2], written ? "" : " <n>");
            return 2;
        }
        i = (unsigned) strtoul(argv[4], NULL, 0);
        if (i >= n) {
            fprintf(stderr, "entry %u out of range (entries=%u)\n", i, n);
            return 1;
        }
        if (written)
            cetrafs_ee_set_len(&leaves[i], cetrafs_ee_len(&leaves[i]), 0);
        else
            cetrafs_ee_set_len(&leaves[i], cetrafs_ee_len(&leaves[i]) + (uint32_t) strtoul(argv[5], NULL, 0),
                               cetrafs_ee_uninit(&leaves[i]));
        {
            cetrafs_blk_tail_t *t = (cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);

            t->magic = cetrafs_cpu_to_le32(CETRAFS_LEAF_TAIL_MAGIC);
            t->crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF));
        }
        pwrite_all(blk, sizeof(blk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);
        printf("leaf_poke: ino %" PRIu64 " leaf %" PRIu64 " entry %u len -> %u uninit -> %d\n", ino, leaf_lba, i,
               (unsigned) cetrafs_ee_len(&leaves[i]), cetrafs_ee_uninit(&leaves[i]));
        return 0;
    }

    if (strcmp(argv[2], "setphys") == 0 || strcmp(argv[2], "setblock") == 0) {
        const int set_block = strcmp(argv[2], "setblock") == 0;

        if (argc != 6) {
            fprintf(stderr, "%s needs <entry> <new_value>\n", argv[2]);
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

        if (set_block) {
            cetrafs_ee_set_lblk(&leaves[entry], new_phys);
        } else {
            cetrafs_ee_set_pblk(&leaves[entry], new_phys);
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
