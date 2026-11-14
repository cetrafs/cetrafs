// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bgflags_poke -- test-only: read or set a Block Group's flags word
 * (CETRAFS_BG_FLAG_DISCARDED, CETRAFS_BG_FLAG_DISCARD_PENDING) on a raw,
 * UNMOUNTED cetrafs image, restamping the descriptor's checksum so the
 * record stays valid.
 *
 * usage: bgflags_poke <image> <bg_id>            print the flags
 *        bgflags_poke <image> <bg_id> <flags>    set them
 *
 * Descriptors sit one per block at bg_table_start + bg_id, the layout
 * fsck reads for a volume that has not been grown.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    cetrafs_block_group_t bg;
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    uint64_t id;
    off_t off;
    int fd;

    if (argc != 3 && argc != 4) {
        fprintf(stderr, "usage: %s <image> <bg_id> [flags]\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], argc == 4 ? O_RDWR : O_RDONLY);
    if (fd < 0 || pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb)) {
        perror("open/read superblock");
        return 2;
    }
    id = strtoull(argv[2], NULL, 0);
    if (id >= cetrafs_le32(sb.block_group_count)) {
        fprintf(stderr, "bg %" PRIu64 " out of range\n", id);
        return 2;
    }
    off = (off_t) (cetrafs_le64(sb.bg_table_start) + id) * CETRAFS_BLOCK_SIZE;
    if (pread(fd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("pread");
        return 2;
    }
    memcpy(&bg, blk, sizeof(bg));
    if (argc == 3) {
        printf("flags=0x%04x\n", (unsigned) cetrafs_le16(bg.flags));
        close(fd);
        return 0;
    }
    bg.flags = cetrafs_cpu_to_le16((uint16_t) strtoul(argv[3], NULL, 0));
    bg.checksum = 0;
    bg.checksum = cetrafs_cpu_to_le64(
        crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum), sizeof(bg.checksum)));
    memcpy(blk, &bg, sizeof(bg));
    if (pwrite(fd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("pwrite");
        return 2;
    }
    close(fd);
    return 0;
}
