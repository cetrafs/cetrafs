// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dirent_field_poke -- test-only: set one field of one dirent in a dirent
 * block on a raw, UNMOUNTED cetrafs image, restamping the block's tail
 * CRC so the block stays checksum-valid.
 *
 * usage: dirent_field_poke <image> <block> <slot> <name_len|file_type|inode> <value>
 *
 * inode 0 unnames the entry, as an unlink that never reached the target's
 * record would leave it.
 *
 * The class this reproduces is "valid CRC, impossible content": a block
 * every reader accepts by its checksum and structure check, whose entry
 * still says something no writer would have written (a file type past
 * CETRAFS_FT_SOCK). fsck's walk does not look at file types, so such a
 * block is read as sound; only the coherence test used before writing
 * into a block sees it.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

int main(int argc, char **argv)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_dirent_t *de = (cetrafs_dirent_t *) blk;
    cetrafs_dirent_tail_t tail;
    unsigned long slot, value;
    off_t off;
    int fd;

    if (argc != 6) {
        fprintf(stderr, "usage: %s <image> <block> <slot> <name_len|file_type|inode> <value>\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    off = (off_t) strtoull(argv[2], NULL, 0) * CETRAFS_BLOCK_SIZE;
    slot = strtoul(argv[3], NULL, 0);
    value = strtoul(argv[5], NULL, 0);
    if (slot >= CETRAFS_DIRENTS_PER_BLOCK) {
        fprintf(stderr, "slot %lu out of range\n", slot);
        return 2;
    }
    if (pread(fd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("pread");
        return 2;
    }
    if (!strcmp(argv[4], "name_len"))
        de[slot].name_len = cetrafs_cpu_to_le16((uint16_t) value);
    else if (!strcmp(argv[4], "file_type"))
        de[slot].file_type = (uint8_t) value;
    else if (!strcmp(argv[4], "inode"))
        de[slot].inode = cetrafs_cpu_to_le64((uint64_t) value);
    else {
        fprintf(stderr, "unknown field %s\n", argv[4]);
        return 2;
    }
    memcpy(&tail, blk + CETRAFS_DIRENT_TAIL_OFF, sizeof(tail));
    tail.crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_DIRENT_TAIL_OFF));
    memcpy(blk + CETRAFS_DIRENT_TAIL_OFF, &tail, sizeof(tail));
    if (pwrite(fd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("pwrite");
        return 2;
    }
    close(fd);
    return 0;
}
