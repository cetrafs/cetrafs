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
    /* `index0` as a 5th argument: the record is at depth >= 1 and its
     * inline index 0's LEAF address is what moves (fsck_root_leaf_address.sh). */
    int index0 = argc == 5 && strcmp(argv[4], "index0") == 0;

    if (argc != 4 && !index0) {
        fprintf(stderr, "usage: %s <backing-file> <ino> <phys-lba|inode_table|sb_table|bg_seg_first|bg_seg_tail|bg_bitmap_last|device_end>\n", argv[0]);
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
    else if (strcmp(argv[3], "bg_seg_first") == 0 || strcmp(argv[3], "bg_seg_tail") == 0) {
        /* An appended Block Group table segment's header (a grown
         * volume): the FIRST one, which a second grow leaves in a hole
         * INSIDE the data area, or the TAIL one, in the current reserve
         * past bg_data_end. Live descriptors every node CASes. */
        uint64_t cur = cetrafs_le64(sb.bg_table_next);
        cetrafs_seg_hdr_t seg;

        if (!cur) {
            fprintf(stderr, "the volume has no appended BG table segment -- it was never grown\n");
            return 3;
        }
        target = cur;
        if (strcmp(argv[3], "bg_seg_tail") == 0) {
            for (int guard = 0; guard < 1024; guard++) {
                rd(fd, &seg, sizeof(seg), (off_t) cur * cetrafs_le32(sb.block_size));
                if (!cetrafs_le64(seg.next))
                    break;
                cur = cetrafs_le64(seg.next);
            }
            target = cur;
        }
    } else if (strcmp(argv[3], "bg_bitmap_last") == 0) {
        /* The LAST Block Group's data bitmap: inside the data box
         * [bg_regions_start, bg_data_end), between two data regions
         * (audit 2026-11-14 M-40). Read from the first table segment,
         * which holds every group of a never-grown volume. */
        uint32_t nbg = cetrafs_le32(sb.block_group_count);
        cetrafs_block_group_t bg;

        if (nbg < 2) {
            fprintf(stderr, "the volume has %u Block Group(s); the last one's bitmap needs a group before it\n", nbg);
            return 3;
        }
        rd(fd, &bg, sizeof(bg), (off_t) (cetrafs_le64(sb.bg_table_start) + nbg - 1) * cetrafs_le32(sb.block_size));
        target = cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_bmap);
    } else if (strcmp(argv[3], "device_end") == 0) {
        /* The last block of the device: past bg_data_end on a grown
         * volume, so no Block Group's data. */
        target = cetrafs_le64(sb.total_blocks) - 1;
    } else
        target = strtoull(argv[3], NULL, 0);

    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range\n", ino);
        return 2;
    }

    off_t rec_off = (off_t) cetrafs_u_ino_lba(fd, &sb, ino, NULL, NULL) * cetrafs_le32(sb.block_size);
    cetrafs_inode_t rec;

    rd(fd, &rec, sizeof(rec), rec_off);

    if (index0) {
        if (cetrafs_le16(rec.eh.eh_depth) == 0 || cetrafs_le16(rec.eh.eh_entries) == 0) {
            fprintf(stderr, "ino %" PRIu64 " has depth=%u entries=%u -- no inline index 0 to move\n", ino,
                    cetrafs_le16(rec.eh.eh_depth), cetrafs_le16(rec.eh.eh_entries));
            return 3;
        }
        cetrafs_ei_set_child(&rec.et.idx[0], target);
        cetrafs_inode_stamp_crcs_us(&rec);
        wr(fd, &rec, sizeof(rec), rec_off);
        printf("extent_phys_poke: ino %" PRIu64 " index0 leaf -> %" PRIu64 ", CRCs restamped\n", ino, target);
        return 0;
    }
    if (cetrafs_le16(rec.eh.eh_depth) != 0 || cetrafs_le16(rec.eh.eh_entries) == 0) {
        /* The caller wanted an inline extent moved and there is none:
         * say so rather than poking a slot that means nothing, which
         * would leave the suite asserting over a file whose blocks were
         * never redirected. */
        fprintf(stderr, "ino %" PRIu64 " has depth=%u entries=%u -- no inline extent 0 to move\n", ino,
                cetrafs_le16(rec.eh.eh_depth), cetrafs_le16(rec.eh.eh_entries));
        return 3;
    }

    uint64_t was = cetrafs_ee_pblk(&rec.et.leaf[0]);

    cetrafs_ee_set_pblk(&rec.et.leaf[0], target);
    cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005: echoes + both sector CRCs */
    wr(fd, &rec, sizeof(rec), rec_off);

    printf("extent_phys_poke: ino %" PRIu64 " extent0 phys %" PRIu64 " -> %" PRIu64 " (len %u), CRCs restamped\n", ino,
           was, target, cetrafs_ee_len(&rec.et.leaf[0]));
    return 0;
}
