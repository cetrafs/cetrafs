// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bg_map.c -- test-only helper: dump the Zone Group <-> Block Group
 * ownership mapping from a raw cetrafs image, from BOTH sides.
 *
 * The mapping is currently stored twice: each Zone Group records a
 * contiguous range of Block Groups (first_bg_id + bg_count, in its cold
 * half), and each Block Group records its owning Zone Group
 * (owner_zg). Nothing has ever checked that the two agree, because
 * nothing could read them side by side.
 *
 * That matters now because the range representation is being removed
 * (docs/internal/BG-OWNERSHIP-DESIGN.md): per-Block-Group ownership is
 * what lets a grow touch nothing that already exists, and what lets a
 * node hand back empty Block Groups instead of hoarding them. The
 * migration is only safe if the behaviour that must survive it is
 * pinned down first, and this is the instrument that pins it.
 *
 * Reuses the real structs and the real crc32c_struct(), like every
 * other poke helper here, so the dump cannot drift from the format.
 *
 * Usage: bg_map <image>
 *
 * Output, one record per line, stable and sorted so a test can diff it:
 *   counts <zone_group_count> <block_group_count>
 *   zg <id> first_bg=<n> bg_count=<n> owner_node=<n>
 *   bg <id> owner_zg=<n> start=<lba> free=<n>/<n>
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

static void die(const char *m)
{
    fprintf(stderr, "bg_map: %s\n", m);
    exit(1);
}

static void read_at(int fd, void *buf, size_t len, off_t off)
{
    ssize_t r = pread(fd, buf, len, off);

    if (r != (ssize_t) len)
        die("short read");
}

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    int fd;
    uint32_t z, zg_count, bg_count;
    uint64_t b;

    if (argc != 2) {
        fprintf(stderr, "usage: %s <image>\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDONLY);
    if (fd < 0)
        die("open");
    read_at(fd, &sb, sizeof(sb), 0);
    if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC)
        die("not a cetrafs image");

    zg_count = cetrafs_le32(sb.zone_group_count);
    bg_count = cetrafs_le32(sb.block_group_count);
    printf("counts %u %u\n", zg_count, bg_count);

    for (z = 0; z < zg_count; z++) {
        cetrafs_zone_group_t zg;

        read_at(fd, &zg, sizeof(zg), (off_t) (cetrafs_le64(sb.zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
        /* No member list to print: a Zone Group no longer records which
         * Block Groups belong to it. The bg lines below carry the
         * mapping, from the only place it now lives. */
        printf("zg %u owner_node=%u free=%" PRIu64 "\n", z, cetrafs_le16(zg.owner_node_id),
               (uint64_t) cetrafs_le64(zg.free_data_blocks));
    }

    for (b = 0; b < bg_count; b++) {
        cetrafs_block_group_t bg;

        read_at(fd, &bg, sizeof(bg), (off_t) (cetrafs_le64(sb.bg_table_start) + b) * CETRAFS_BLOCK_SIZE);
        printf("bg %" PRIu64 " owner_zg=%u start=%" PRIu64 " free=%" PRIu64 "/%" PRIu64 "\n", b,
               cetrafs_le16(bg.owner_zg), (uint64_t) cetrafs_le64(bg.start_block),
               (uint64_t) cetrafs_le64(bg.free_data_blocks), (uint64_t) cetrafs_le64(bg.data_block_count));
    }

    close(fd);
    return 0;
}
