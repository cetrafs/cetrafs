// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * corrupt_poke.c -- test-only helper that INJECTS corruption, so fsck's
 * content passes can be shown to actually detect it.
 *
 * A checker that has never been seen to fail proves nothing; these are
 * the negative controls for fsck.cetra's extent-overlap and
 * bitmap-vs-reachability passes.
 *
 * Usage:
 *   corrupt_poke <image> bitset <bg_id> <bit>   -- mark a data block used
 *   corrupt_poke <image> bitclr <bg_id> <bit>   -- mark a data block free
 *   corrupt_poke <image> extent <ino> <phys>    -- repoint an inode's
 *                                                  first extent at <phys>
 *   corrupt_poke <image> dirent <dir_ino> <name> -- erase a directory
 *                                                  entry, leaving its
 *                                                  inode allocated but
 *                                                  unreachable (the
 *                                                  on-disk signature of
 *                                                  a lost dirent)
 *   corrupt_poke <image> repoint <dir_ino> <name> <new_target>
 *                                               -- make an entry name a
 *                                                  different inode
 * The data bitmap carries no checksum of its own, so bitset/bitclr need
 * no fixups; the extent mode restamps the inode checksum.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static void rd(int fd, void *b, size_t n, off_t o)
{
    if (pread(fd, b, n, o) != (ssize_t) n) {
        perror("pread");
        exit(1);
    }
}
static void wr(int fd, const void *b, size_t n, off_t o)
{
    if (pwrite(fd, b, n, o) != (ssize_t) n) {
        perror("pwrite");
        exit(1);
    }
}

int main(int argc, char **argv)
{
    {
        int six = (strcmp(argv[2], "repoint") == 0 || strcmp(argv[2], "filetype") == 0);
        if (argc < 5 || (six && argc != 6) || (!six && argc != 5)) {
            fprintf(stderr,
                    "usage: %s <image> bitset|bitclr <bg_id> <bit>\n"
                    "       %s <image> extent <ino> <phys>\n"
                    "       %s <image> dirent <dir_ino> <name>\n"
                    "       %s <image> repoint <dir_ino> <name> <new_target>\n"
                    "       %s <image> filetype <dir_ino> <name> <ft>\n",
                    argv[0], argv[0], argv[0], argv[0], argv[0]);
            return 2;
        }
    }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    cetrafs_superblock_t sb;
    rd(fd, &sb, sizeof(sb), 0);

    if (!strcmp(argv[2], "extent")) {
        uint64_t ino = strtoull(argv[3], NULL, 0), phys = strtoull(argv[4], NULL, 0);
        off_t off = (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE;
        cetrafs_inode_t in;

        rd(fd, &in, sizeof(in), off);
        in.et.leaf[0].ee_start_lo = cetrafs_cpu_to_le32((uint32_t) (phys & 0xFFFFFFFFu));
        in.et.leaf[0].ee_start_hi = cetrafs_cpu_to_le16((uint16_t) (phys >> 32));
        cetrafs_inode_stamp_crcs_us(&in); /* v0x0005 */
        wr(fd, &in, sizeof(in), off);
        printf("corrupt_poke: inode %" PRIu64 " extent[0] -> block %" PRIu64 "\n", ino, phys);
        close(fd);
        return 0;
    }

    /* repoint <dir_ino> <name> <new_target>: leave the entry in place but
     * make it name a different inode. Used to break '..' without
     * touching anything else -- the exact shape a rename that forgot to
     * fix up a moved directory's parent pointer would leave. */
    if (!strcmp(argv[2], "repoint")) {
        uint64_t dino = strtoull(argv[3], NULL, 0);
        const char *name = argv[4];
        uint64_t newt = strtoull(argv[5], NULL, 0);
        cetrafs_inode_t in;
        cetrafs_extent_t ext[4];
        uint32_t n;

        rd(fd, &in, sizeof(in), (off_t) (cetrafs_le64(sb.inode_table_start) + dino - 1) * CETRAFS_BLOCK_SIZE);
        if (in.eh.eh_depth != 0) {
            fprintf(stderr, "repoint mode only handles depth-0 directories\n");
            return 1;
        }
        n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);
        memcpy(ext, in.et.leaf, n * sizeof(ext[0]));

        for (uint32_t e = 0; e < n; ++e) {
            uint64_t phys = ((uint64_t) cetrafs_le16(ext[e].ee_start_hi) << 32) | cetrafs_le32(ext[e].ee_start_lo);
            uint64_t len = cetrafs_le32(ext[e].ee_len) & CETRAFS_EXT_LEN_MASK;

            for (uint64_t k = 0; k < len; ++k) {
                uint8_t db[CETRAFS_BLOCK_SIZE];
                cetrafs_dirent_t *de;
                off_t off = (off_t) (phys + k) * CETRAFS_BLOCK_SIZE;

                rd(fd, db, sizeof(db), off);
                de = (cetrafs_dirent_t *) db;
                for (unsigned sl = 0; sl < CETRAFS_DIRENTS_PER_BLOCK; ++sl) {
                    cetrafs_dirent_tail_t t;

                    if (!cetrafs_le64(de[sl].inode) || cetrafs_le16(de[sl].name_len) != strlen(name) ||
                        memcmp(de[sl].name, name, cetrafs_le16(de[sl].name_len)))
                        continue;
                    printf("corrupt_poke: repointing '%s' in inode %" PRIu64 " from %" PRIu64 " to %" PRIu64 "\n", name,
                           dino, (uint64_t) cetrafs_le64(de[sl].inode), newt);
                    de[sl].inode = cetrafs_cpu_to_le64((uint32_t) newt);
                    t.magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
                    t.crc = cetrafs_cpu_to_le32(crc32c_update(0, db, CETRAFS_DIRENT_TAIL_OFF));
                    memcpy(db + CETRAFS_DIRENT_TAIL_OFF, &t, sizeof(t));
                    wr(fd, db, sizeof(db), off);
                    close(fd);
                    return 0;
                }
            }
        }
        fprintf(stderr, "dirent '%s' not found in inode %" PRIu64 "\n", name, dino);
        return 1;
    }

    /* filetype <dir_ino> <name> <ft>: set a dirent's file_type byte to <ft>
     * and restamp the tail -- simulates the d_type copy disagreeing with the
     * target inode's actual mode (the WARN fsck emits for it). */
    if (!strcmp(argv[2], "filetype")) {
        uint64_t dino = strtoull(argv[3], NULL, 0);
        const char *name = argv[4];
        unsigned ft = (unsigned) strtoul(argv[5], NULL, 0);
        cetrafs_inode_t in;
        cetrafs_extent_t ext[4];
        uint32_t n;

        rd(fd, &in, sizeof(in), (off_t) (cetrafs_le64(sb.inode_table_start) + dino - 1) * CETRAFS_BLOCK_SIZE);
        if (in.eh.eh_depth != 0) {
            fprintf(stderr, "filetype mode only handles depth-0 directories\n");
            return 1;
        }
        n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);
        memcpy(ext, in.et.leaf, n * sizeof(ext[0]));

        for (uint32_t e = 0; e < n; ++e) {
            uint64_t phys = ((uint64_t) cetrafs_le16(ext[e].ee_start_hi) << 32) | cetrafs_le32(ext[e].ee_start_lo);
            uint64_t len = cetrafs_le32(ext[e].ee_len) & CETRAFS_EXT_LEN_MASK;

            for (uint64_t k = 0; k < len; ++k) {
                uint8_t db[CETRAFS_BLOCK_SIZE];
                cetrafs_dirent_t *de;
                off_t off = (off_t) (phys + k) * CETRAFS_BLOCK_SIZE;

                rd(fd, db, sizeof(db), off);
                de = (cetrafs_dirent_t *) db;
                for (unsigned sl = 0; sl < CETRAFS_DIRENTS_PER_BLOCK; ++sl) {
                    cetrafs_dirent_tail_t t;

                    if (!cetrafs_le64(de[sl].inode) || cetrafs_le16(de[sl].name_len) != strlen(name) ||
                        memcmp(de[sl].name, name, cetrafs_le16(de[sl].name_len)))
                        continue;
                    printf("corrupt_poke: '%s' in inode %" PRIu64 " file_type %u -> %u\n", name, dino,
                           (unsigned) de[sl].file_type, ft);
                    de[sl].file_type = (uint8_t) ft;
                    t.magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
                    t.crc = cetrafs_cpu_to_le32(crc32c_update(0, db, CETRAFS_DIRENT_TAIL_OFF));
                    memcpy(db + CETRAFS_DIRENT_TAIL_OFF, &t, sizeof(t));
                    wr(fd, db, sizeof(db), off);
                    close(fd);
                    return 0;
                }
            }
        }
        fprintf(stderr, "dirent '%s' not found in inode %" PRIu64 "\n", name, dino);
        return 1;
    }

    if (!strcmp(argv[2], "dirent")) {
        uint64_t dino = strtoull(argv[3], NULL, 0);
        const char *name = argv[4];
        cetrafs_inode_t in;
        cetrafs_extent_t ext[4];
        uint32_t n;

        rd(fd, &in, sizeof(in), (off_t) (cetrafs_le64(sb.inode_table_start) + dino - 1) * CETRAFS_BLOCK_SIZE);
        if (in.eh.eh_depth != 0) {
            fprintf(stderr, "dirent mode only handles depth-0 directories\n");
            return 1;
        }
        n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);
        memcpy(ext, in.et.leaf, n * sizeof(ext[0]));

        for (uint32_t e = 0; e < n; ++e) {
            uint64_t phys = ((uint64_t) cetrafs_le16(ext[e].ee_start_hi) << 32) | cetrafs_le32(ext[e].ee_start_lo);
            uint64_t len = cetrafs_le32(ext[e].ee_len) & CETRAFS_EXT_LEN_MASK;

            for (uint64_t k = 0; k < len; ++k) {
                uint8_t db[CETRAFS_BLOCK_SIZE];
                cetrafs_dirent_t *de;
                off_t off = (off_t) (phys + k) * CETRAFS_BLOCK_SIZE;

                rd(fd, db, sizeof(db), off);
                de = (cetrafs_dirent_t *) db;
                for (unsigned s = 0; s < CETRAFS_DIRENTS_PER_BLOCK; ++s) {
                    if (!cetrafs_le64(de[s].inode) || cetrafs_le16(de[s].name_len) != strlen(name) ||
                        memcmp(de[s].name, name, cetrafs_le16(de[s].name_len)))
                        continue;
                    printf("corrupt_poke: erasing dirent '%s' (inode %" PRIu64 ") from block %" PRIu64 "\n", name,
                           (uint64_t) cetrafs_le64(de[s].inode), phys + k);
                    memset(&de[s], 0, sizeof(de[s]));
                    /* restamp the tail so the block still parses -- the
                     * point is an UNREACHABLE inode, not a torn block */
                    {
                        cetrafs_dirent_tail_t t;
                        t.magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
                        t.crc = cetrafs_cpu_to_le32(crc32c_update(0, db, CETRAFS_DIRENT_TAIL_OFF));
                        memcpy(db + CETRAFS_DIRENT_TAIL_OFF, &t, sizeof(t));
                    }
                    wr(fd, db, sizeof(db), off);
                    close(fd);
                    return 0;
                }
            }
        }
        fprintf(stderr, "dirent '%s' not found in inode %" PRIu64 "\n", name, dino);
        return 1;
    }

    uint32_t bg_id = (uint32_t) strtoul(argv[3], NULL, 0);
    uint64_t bit = strtoull(argv[4], NULL, 0);
    cetrafs_block_group_t bg;
    uint8_t blk[CETRAFS_BLOCK_SIZE];

    rd(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb.bg_table_start) + bg_id) * CETRAFS_BLOCK_SIZE);
    memcpy(&bg, blk, sizeof(bg));

    off_t bmap = (off_t) (cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_bmap)) * CETRAFS_BLOCK_SIZE + (off_t) (bit / 8);
    uint8_t byte;
    rd(fd, &byte, 1, bmap);
    if (!strcmp(argv[2], "bitset"))
        byte |= (uint8_t) (1u << (bit % 8));
    else
        byte &= (uint8_t) ~(1u << (bit % 8));
    wr(fd, &byte, 1, bmap);
    printf("corrupt_poke: BG%u data bitmap bit %" PRIu64 " -> %s\n", bg_id, bit, argv[2] + 3);
    close(fd);
    return 0;
}
