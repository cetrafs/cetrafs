// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * extent_phys_poke.c -- test-only helper: point an inode's inline extent
 * 0 at an ARBITRARY physical block, restamping the record's checksums so
 * it stays integrity-valid.
 *
 * The class this reproduces is "valid CRC, impossible content" -- the
 * same one inode_block_poke's `extlen` makes for LENGTHS, for ADDRESSES
 * instead. A checksum says the bytes are the ones that were written; it
 * says nothing about whether the block they name is one a file may
 * occupy.
 *
 * `inode_table` is the interesting target rather than a number pulled
 * out of the air: it is the most destructive legal-looking address on
 * the volume. Block 0 would be caught by the superblock's own magic on
 * the next mount, and a wild 2^40 would be refused by the block layer
 * as a short read -- neither exercises what this is for, which is an
 * address that is perfectly readable and writable and simply not the
 * file's.
 *
 * Writes to the loop device's BACKING FILE, like every other poker here,
 * so the change is invisible to the mounted filesystem's buffer cache --
 * see the long note at the top of inode_block_poke.c.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include "cetrafs.h"
#include "crc32c.h"

static void rd(int fd, void *b, size_t n, off_t o)
{
    if (pread(fd, b, n, o) != (ssize_t) n) {
        perror("pread");
        exit(2);
    }
}

static void wr(int fd, const void *b, size_t n, off_t o)
{
    if (pwrite(fd, b, n, o) != (ssize_t) n) {
        perror("pwrite");
        exit(2);
    }
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <backing-file> <ino> <phys-lba|inode_table|sb_table>\n", argv[0]);
        fprintf(stderr, "       points inode <ino>'s inline extent 0 at that physical block\n");
        return 2;
    }

    int fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 2;
    }

    cetrafs_superblock_t sb;
    rd(fd, &sb, sizeof(sb), 0);

    uint64_t ino = strtoull(argv[2], NULL, 0);
    uint64_t target;

    if (strcmp(argv[3], "inode_table") == 0)
        target = cetrafs_le64(sb.inode_table_start);
    else if (strcmp(argv[3], "sb_table") == 0)
        target = cetrafs_le64(sb.zg_table_start);
    else
        target = strtoull(argv[3], NULL, 0);

    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range\n", ino);
        return 2;
    }

    off_t rec_off = (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * cetrafs_le32(sb.block_size);
    cetrafs_inode_t rec;

    rd(fd, &rec, sizeof(rec), rec_off);

    if (cetrafs_le16(rec.eh.eh_depth) != 0 || cetrafs_le16(rec.eh.eh_entries) == 0) {
        /* The caller wanted an inline extent moved and there is none:
         * say so rather than poking a slot that means nothing, which
         * would leave the suite asserting over a file whose blocks were
         * never redirected. */
        fprintf(stderr, "ino %" PRIu64 " has depth=%u entries=%u -- no inline extent 0 to move\n", ino,
                cetrafs_le16(rec.eh.eh_depth), cetrafs_le16(rec.eh.eh_entries));
        return 3;
    }

    uint64_t was = ((uint64_t) cetrafs_le16(rec.et.leaf[0].ee_start_hi) << 32) | cetrafs_le32(rec.et.leaf[0].ee_start_lo);

    rec.et.leaf[0].ee_start_lo = cetrafs_cpu_to_le32((uint32_t) (target & 0xffffffffu));
    rec.et.leaf[0].ee_start_hi = cetrafs_cpu_to_le16((uint16_t) (target >> 32));
    cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005: echoes + both sector CRCs */
    wr(fd, &rec, sizeof(rec), rec_off);

    printf("extent_phys_poke: ino %" PRIu64 " extent0 phys %" PRIu64 " -> %" PRIu64 " (len %u), CRCs restamped\n", ino,
           was, target, cetrafs_extent_len(rec.et.leaf[0].ee_len));
    return 0;
}
