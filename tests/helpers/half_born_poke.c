// SPDX-License-Identifier: GPL-2.0-or-later
// half_born_poke -- stage a create that stopped after its birth claim
// on a raw, UNMOUNTED cetrafs image: set inode #ino's bit and write its
// slot as a HALF-BORN record -- the namespace sector checksummed, naming
// no file, claimed by <owner> at <incarnation>; the file sector zeros.
// That is what a birth claim over a never-written slot leaves when its
// node stops before the record write.
//
// usage: half_born_poke <image> <ino> <owner_node_id> <incarnation>
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
    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> <ino> <owner_node_id> <incarnation>\n", argv[0]);
        return 2;
    }
    uint64_t ino = strtoull(argv[2], NULL, 0);
    uint32_t owner = (uint32_t) strtoul(argv[3], NULL, 0);
    uint32_t inc = (uint32_t) strtoul(argv[4], NULL, 0);
    int fd = open(argv[1], O_RDWR);
    cetrafs_superblock_t sb;

    if (fd < 0) {
        perror("open");
        return 2;
    }
    rd(fd, &sb, sizeof(sb), 0);
    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range\n", ino);
        return 2;
    }

    uint64_t bit = ino - 1;
    off_t boff = (off_t) cetrafs_le64(sb.inode_bmap_start) * CETRAFS_BLOCK_SIZE + (off_t) (bit / 8);
    unsigned char byte;
    rd(fd, &byte, 1, boff);
    byte |= (unsigned char) (1u << (bit % 8));
    wr(fd, &byte, 1, boff);

    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_inode_t in;
    memset(blk, 0, sizeof(blk));
    memset(&in, 0, sizeof(in));
    in.ino = cetrafs_cpu_to_le64(ino);
    in.ns_lock_owner = cetrafs_cpu_to_le32(owner);
    in.ns_lock_incarnation = cetrafs_cpu_to_le32(inc);
    in.dirent_seq = cetrafs_cpu_to_le64(1);
    in.ns_checksum = cetrafs_cpu_to_le64(0);
    in.ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns_us(&in));
    memcpy(blk, &in, CETRAFS_INODE_NS_BYTES); /* the file sector stays zeros */
    wr(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
    if (fsync(fd) != 0) {
        perror("fsync");
        return 2;
    }
    close(fd);
    printf("ino=%" PRIu64 " half-born, claimed by node %u incarnation %u\n", ino, owner, inc);
    return 0;
}
