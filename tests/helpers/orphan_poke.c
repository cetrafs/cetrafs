// SPDX-License-Identifier: GPL-2.0-or-later
// orphan_poke -- fabricate an ORPHAN INODE on a raw, UNMOUNTED cetrafs
// image: set inode #ino's bit in the global inode bitmap and write a
// minimal regular-file record for it with the given nlink and
// read_open_nodes mask (correctly checksummed, no extents, no dirent).
//
// nlink=0, mask=0 is exactly the on-disk state a cross-node delete leaves
// when the deleting node could not free the inode (a peer held it open) and
// the peer's own eviction could not know the file had died: allocated,
// deleted, referenced by nothing. The background scrub must reclaim it.
// nlink=0 with a nonzero mask is the same inode while the peer still READS
// it -- the scrub must spare that one.
//
// usage: orphan_poke <image> <ino> <nlink> <read_open_nodes_mask>
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
        fprintf(stderr, "usage: %s <image> <ino> <nlink> <read_open_nodes_mask>\n", argv[0]);
        return 2;
    }
    uint64_t ino = strtoull(argv[2], NULL, 0);
    uint32_t nlink = (uint32_t) strtoul(argv[3], NULL, 0);
    uint64_t mask = strtoull(argv[4], NULL, 0);
    int fd = open(argv[1], O_RDWR);

    if (fd < 0) { perror("open"); return 2; }

    cetrafs_superblock_t sb;
    rd(fd, &sb, sizeof(sb), 0);
    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range\n", ino);
        return 2;
    }

    /* Set the inode bitmap bit (dense, LSB-first; bit = ino-1). */
    uint64_t bit = ino - 1;
    off_t boff = (off_t) cetrafs_le64(sb.inode_bmap_start) * CETRAFS_BLOCK_SIZE + (off_t) (bit / 8);
    unsigned char byte;
    rd(fd, &byte, 1, boff);
    if (byte & (1u << (bit % 8))) {
        fprintf(stderr, "ino %" PRIu64 " is already allocated -- pick a free one\n", ino);
        return 2;
    }
    byte |= (unsigned char) (1u << (bit % 8));
    wr(fd, &byte, 1, boff);

    /* A minimal regular-file record: no extents, no xattrs, no locks. */
    cetrafs_inode_t in;
    memset(&in, 0, sizeof(in));
    in.ino = cetrafs_cpu_to_le64(ino);
    in.mode = cetrafs_cpu_to_le32(0100644);
    in.nlink = cetrafs_cpu_to_le32(nlink);
    in.generation = cetrafs_cpu_to_le64(0x0DDBA11ULL + ino);
    in.read_open_nodes = cetrafs_cpu_to_le64(mask);
    in.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    cetrafs_inode_stamp_crcs_us(&in); /* v0x0005: echoes + both sector CRCs */

    uint8_t blk[CETRAFS_BLOCK_SIZE];
    memset(blk, 0, sizeof(blk));
    memcpy(blk, &in, sizeof(in));
    wr(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);

    printf("orphan_poke: ino=%" PRIu64 " nlink=%u read_open_nodes=0x%" PRIx64 " planted\n", ino, nlink, mask);
    close(fd);
    return 0;
}
