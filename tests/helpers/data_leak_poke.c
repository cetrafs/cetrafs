// SPDX-License-Identifier: GPL-2.0-or-later
// data_leak_poke -- simulate leaked data blocks on a raw, UNMOUNTED cetrafs
// image: set `count` data-bitmap bits [first, first+count) in a Block Group
// and decrement the BG's and its owning ZG's free_data_blocks by count,
// restamping both checksums. This is exactly the on-disk state a DROPPED
// foreign free leaves -- blocks allocated (counted used, bit set) but
// referenced by no inode -- with the free counters kept consistent so fsck's
// only complaint is the leak itself. The background scrub reclaims these.
//
// usage: data_leak_poke <image> <bg_id> <first_data_block> <count>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stddef.h>
#include <fcntl.h>
#include "cetrafs.h"
#include "crc32c.h"

static void rd(int fd, void *b, size_t n, off_t o)
{ if (pread(fd, b, n, o) != (ssize_t) n) { perror("pread"); exit(2); } }
static void wr(int fd, const void *b, size_t n, off_t o)
{ if (pwrite(fd, b, n, o) != (ssize_t) n) { perror("pwrite"); exit(2); } }

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> <bg_id> <first_data_block> <count>\n", argv[0]);
        return 2;
    }
    uint32_t bg_id = (uint32_t) strtoul(argv[2], NULL, 0);
    uint64_t first = strtoull(argv[3], NULL, 0);
    uint64_t count = strtoull(argv[4], NULL, 0);
    int fd = open(argv[1], O_RDWR);

    if (fd < 0) { perror("open"); return 2; }

    cetrafs_superblock_t sb;
    rd(fd, &sb, sizeof(sb), 0);

    off_t bg_off = (off_t) (cetrafs_le64(sb.bg_table_start) + bg_id) * CETRAFS_BLOCK_SIZE;
    cetrafs_block_group_t bg;
    rd(fd, &bg, sizeof(bg), bg_off);

    /* Set the bits in the data bitmap (dense, LSB-first). */
    off_t bmap_off = (off_t) (cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_bmap)) * CETRAFS_BLOCK_SIZE;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t bit = first + i;
        unsigned char byte;
        off_t bo = bmap_off + (off_t) (bit / 8);
        rd(fd, &byte, 1, bo);
        byte |= (unsigned char) (1u << (bit % 8));
        wr(fd, &byte, 1, bo);
    }

    /* Decrement the BG free count to match ("allocated, then leaked"). */
    uint32_t owner_zg = cetrafs_le16(bg.owner_zg);
    bg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(bg.free_data_blocks) - count);
    bg.checksum = 0;
    bg.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum),
                                                    sizeof(cetrafs_le64(bg.checksum))));
    wr(fd, &bg, sizeof(bg), bg_off);

    /* Keep the owning ZG aggregate consistent too. */
    off_t zg_off = (off_t) (cetrafs_le64(sb.zg_table_start) + owner_zg) * CETRAFS_BLOCK_SIZE;
    cetrafs_zone_group_t zg;
    rd(fd, &zg, sizeof(zg), zg_off);
    zg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.free_data_blocks) - count);
    zg.hot_checksum = 0;
    zg.hot_checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct((const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF,
                                                                   CETRAFS_ZG_HOT_LEN,
                                                                   offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF,
                                                                   sizeof(cetrafs_le64(zg.hot_checksum))));
    wr(fd, &zg, sizeof(zg), zg_off);

    /* The ABSOLUTE first LBA as well as the data-region offset: a test
     * that has to name these blocks anywhere else (a pending-free queue
     * entry, say) needs the absolute one, and deriving it from fsck
     * output means piping a tool whose nonzero exit IS the finding. */
    printf("data_leak_poke: BG%u leaked %" PRIu64 " block(s) at data offset %" PRIu64 " lba %" PRIu64 "\n", bg_id,
           count, first, (uint64_t) (cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_region) + first));
    return 0;
}
