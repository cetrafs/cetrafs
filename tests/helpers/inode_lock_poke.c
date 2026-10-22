// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * inode_lock_poke.c -- test-only helper: set (or read back) an inode's
 * lock_owner_node/lock_mode on a raw cetrafs image, correctly
 * recomputing the record checksums so the kernel module accepts the result.
 *
 * Exists solely so tests/mount_test.sh can simulate "this file is
 * already open for write on a different node" (the cross-node exclusive open lock)
 * without hand-deriving
 * cetrafs_inode_t's on-disk offsets -- same approach as zg_poke.c for
 * phase 10's ZG ownership gate. Not part of the normal build; compiled
 * ad hoc by the test script.
 *
 * Usage:
 *   inode_lock_poke <image> <ino> <owner_node_id> <lock_mode>   -- write
 *   inode_lock_poke <image> <ino> --ns <ns_lock_owner>           -- write
 *   inode_lock_poke <image> <ino>                               -- dump

 * The --ns form pokes the per-inode NAMESPACE lock (nslock.c) instead
 * of the open-file lock, so the suite can simulate a peer node holding
 * a directory mid-create.
 *
 * The dump form is read-only (no checksum rewrite) -- used to verify
 * this node's own local open/close refcounting (lock.c's
 * lock_writer_count) actually keeps the on-disk claim held until the
 * *last* local write-opener closes, not the first. Safe to call while
 * mounted: lock.c's open/release path writes the lock fields via
 * sync_dirty_buffer(), so a direct read of the backing device sees the
 * latest value immediately.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static void pread_all(int fd, void *buf, size_t len, off_t off)
{
    if (pread(fd, buf, len, off) != (ssize_t) len) {
        perror("pread");
        exit(1);
    }
}

static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    if (pwrite(fd, buf, len, off) != (ssize_t) len) {
        perror("pwrite");
        exit(1);
    }
}

int main(int argc, char **argv)
{
    /* --rec may arrive in either position: the ctest slave prepends
     * its fixed prefix before the caller's argument. */
    bool has_rec = false;
    for (int ai = 2; ai < argc; ai++)
        if (strcmp(argv[ai], "--rec") == 0)
            has_rec = true;

    if (argc != 3 && argc != 5 && !(argc == 4 && has_rec)) {
        fprintf(stderr,
                "usage: %s <image> <ino> [<owner_node_id> <lock_mode> | --ns <id> | --reader <node_id>]\n",
                argv[0]);
        return 2;
    }

    const char *path = argv[1];
    const char *ino_arg = argv[2];

    if (has_rec && strcmp(argv[2], "--rec") == 0)
        ino_arg = argv[3];
    uint64_t ino = strtoull(ino_arg, NULL, 0);
    /* --rec: dump the RECORD's own fields instead of the lock fields,
     * so a scenario can ask the DEVICE what a directory record says
     * rather than comparing two nodes' kernels against each other.
     * Separate from the plain dump because the kernel suites compare
     * that line byte for byte. */
    bool rec_dump = (argc == 4 && has_rec);
    bool dump_only = (argc == 3) || rec_dump;

    int fd = open(path, dump_only ? O_RDONLY : O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(fd, &sb, sizeof(sb), 0);

    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range (inodes_count=%u)\n", ino, sb.inodes_count);
        return 1;
    }

    /* Same byte-offset math as kmod/inode.c's cetrafs_read_raw_inode():
     * dense table, no per-record block alignment. On a flat image file
     * this collapses to one absolute offset -- no need to replicate the
     * kernel side's per-block straddle loop. */
    off_t ino_off = (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE /* v0x0007: one record per block */;

    cetrafs_inode_t in;
    pread_all(fd, &in, sizeof(in), ino_off);

    if (rec_dump) {
        printf("size=%" PRIu64 " nlink=%u dirent_seq=%" PRIu64 " generation=%" PRIu64 "\n",
               (uint64_t) cetrafs_le64(in.size), cetrafs_le32(in.nlink),
               (uint64_t) cetrafs_le64(in.dirent_seq), (uint64_t) cetrafs_le64(in.generation));
        close(fd);
        return 0;
    }

    if (dump_only) {
        /* The lock fields, in exactly the shape the kernel suites
         * compare against -- do not extend this line. A scenario that
         * needs the record's own fields asks for them with --rec
         * below. */
        printf("owner=%u mode=%u ns_owner=%u readers=0x%" PRIx64 "\n", in.lock_owner_node, in.lock_mode,
               cetrafs_le32(in.ns_lock_owner), (uint64_t) cetrafs_le64(in.read_open_nodes));
        close(fd);
        return 0;
    }

    bool ns_mode = (strcmp(argv[3], "--ns") == 0);
    bool reader_mode = (strcmp(argv[3], "--reader") == 0);
    uint32_t owner = 0, lock_mode = 0;

    if (reader_mode) {
        /* Simulate a PEER holding this file open for read: set its bit
         * in the presence mask. */
        in.read_open_nodes = cetrafs_cpu_to_le64(cetrafs_le64(in.read_open_nodes) | (1ULL << (strtoul(argv[4], NULL, 0) % 64)));
    } else if (ns_mode) {
        in.ns_lock_owner = cetrafs_cpu_to_le32((uint32_t) strtoul(argv[4], NULL, 0));
    } else {
        owner = (uint32_t) strtoul(argv[3], NULL, 0);
        lock_mode = (uint32_t) strtoul(argv[4], NULL, 0);
        in.lock_owner_node = cetrafs_cpu_to_le32(owner);
        in.lock_mode = cetrafs_cpu_to_le32(lock_mode);
    }
    cetrafs_inode_stamp_crcs_us(&in); /* v0x0005 */

    pwrite_all(fd, &in, sizeof(in), ino_off);
    close(fd);

    if (reader_mode)
        printf("inode_lock_poke: ino=%" PRIu64 " read_open_nodes -> 0x%" PRIx64 "\n", ino,
               (uint64_t) cetrafs_le64(in.read_open_nodes));
    else if (ns_mode)
        printf("inode_lock_poke: ino=%" PRIu64 " ns_lock_owner -> %u\n", ino, in.ns_lock_owner);
    else
        printf("inode_lock_poke: ino=%" PRIu64 " lock_owner_node -> %u, lock_mode -> %u\n", ino, owner, lock_mode);
    return 0;
}
