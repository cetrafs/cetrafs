// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Break one checksummed structure's CONTENT without touching its stored
 * checksum, so fsck's verification of that structure is the only thing
 * that can notice.
 *
 * The opposite of sb_poke.c, which re-checksums on purpose (it exists
 * to produce "valid CRC, wrong value"). Here the value stays plausible
 * and the CRC goes stale, which is what a torn write or a bad sector
 * actually leaves behind.
 *
 * Every checksum in this format is CRC32C over the structure with its
 * own checksum field zeroed, so flipping any covered byte is enough --
 * no recomputation needed, which is the whole point.
 *
 *   csum_poke <image> sb
 *   csum_poke <image> zg-hot|zg-cold <zg_id>
 *   csum_poke <image> bg-desc|bg-hdr <bg_id>
 *   csum_poke <image> node <row>
 *   csum_poke <image> inode <ino>
 *   csum_poke <image> dirent-tail <ino>     (the inode's first data block)
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"

static int fd;

static void rd(void *b, size_t n, off_t o)
{
    if (pread(fd, b, n, o) != (ssize_t) n) {
        perror("pread");
        exit(1);
    }
}

static void wr(const void *b, size_t n, off_t o)
{
    if (pwrite(fd, b, n, o) != (ssize_t) n) {
        perror("pwrite");
        exit(1);
    }
}

/* Flip one bit at `off`. A bit, not a byte written to a constant: a
 * constant could coincide with what was already there and change
 * nothing, which would make the control silently prove nothing. */
static void flip(off_t off)
{
    uint8_t b;

    rd(&b, 1, off);
    b ^= 0x40;
    wr(&b, 1, off);
    printf("csum_poke: flipped a bit at offset %lld\n", (long long) off);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <image> sb|zg-hot|zg-cold|bg-desc|bg-hdr|node|inode|dirent-tail [id]\n", argv[0]);
        return 2;
    }
    const char *what = argv[2];
    uint64_t id = (argc > 3) ? strtoull(argv[3], NULL, 0) : 0;

    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    rd(&sb, sizeof(sb), 0);

    /*
     * Always a PADDING byte where one exists. Poking a meaningful field
     * trips an earlier, more specific check first -- flipping
     * total_blocks got "device smaller than metadata", flipping a BG's
     * data_block_count got "BG0 layout mismatch" -- so the checksum
     * verification is never the thing under test. Padding is covered by
     * the CRC and read by nothing, which isolates it exactly.
     */
    if (!strcmp(what, "sb")) {
        flip(offsetof(cetrafs_superblock_t, reserved));
    } else if (!strcmp(what, "zg-hot")) {
        flip((off_t) (cetrafs_le64(sb.zg_table_start) + id) * CETRAFS_BLOCK_SIZE + offsetof(cetrafs_zone_group_t, free_data_blocks));
    } else if (!strcmp(what, "zg-cold")) {
        flip((off_t) (cetrafs_le64(sb.zg_table_start) + id) * CETRAFS_BLOCK_SIZE + offsetof(cetrafs_zone_group_t, cold_pad));
    } else if (!strcmp(what, "bg-desc")) {
        flip((off_t) (cetrafs_le64(sb.bg_table_start) + id) * CETRAFS_BLOCK_SIZE + offsetof(cetrafs_block_group_t, pad));
    } else if (!strcmp(what, "bg-hdr")) {
        cetrafs_block_group_t bg;

        rd(&bg, sizeof(bg), (off_t) (cetrafs_le64(sb.bg_table_start) + id) * CETRAFS_BLOCK_SIZE);
        flip((off_t) (cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_bg_header)) * CETRAFS_BLOCK_SIZE +
             offsetof(cetrafs_bg_header_t, pad));
    } else if (!strcmp(what, "node")) {
        flip((off_t) (cetrafs_le64(sb.node_table_start) + id) * CETRAFS_BLOCK_SIZE + offsetof(cetrafs_node_entry_t, reserved));
    } else if (!strcmp(what, "inode")) {
        flip((off_t) (cetrafs_le64(sb.inode_table_start) + (id - 1)) * CETRAFS_BLOCK_SIZE + offsetof(cetrafs_inode_t, flags_reserved)); /* v0x0005: a covered-but-meaningless byte in the ns sector */
    } else if (!strcmp(what, "dirent-tail")) {
        cetrafs_inode_t in;
        uint64_t lba;

        rd(&in, sizeof(in), (off_t) (cetrafs_le64(sb.inode_table_start) + (id - 1)) * CETRAFS_BLOCK_SIZE);
        if (in.eh.eh_depth != 0 || in.eh.eh_entries == 0) {
            fprintf(stderr, "inode %" PRIu64 " is not a simple depth-0 directory\n", id);
            return 1;
        }
        lba = ((uint64_t) cetrafs_le16(in.et.leaf[0].ee_start_hi) << 32) | cetrafs_le32(in.et.leaf[0].ee_start_lo);
        flip((off_t) lba * CETRAFS_BLOCK_SIZE); /* first dirent byte: the tail CRC covers it */
    } else {
        fprintf(stderr, "unknown target '%s'\n", what);
        return 2;
    }
    close(fd);
    return 0;
}
