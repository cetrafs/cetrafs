// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * node_poke.c -- test-only helper: set (or read back) a Node Registry
 * row's state/hb_seq/last_seen/node_uuid on a raw cetrafs image,
 * correctly recomputing its checksum so the kernel module accepts the
 * result.
 *
 * Exists solely so tests/mount_test.sh can simulate "a different node
 * registered here, but its heartbeat has gone stale" (timeout-based ZG/lock reclaim)
 * without hand-deriving cetrafs_node_entry_t's on-disk offsets -- same approach as
 * zg_poke.c/inode_lock_poke.c. Not part of the normal build; compiled
 * ad hoc by the test script.
 *
 * Usage:
 *   node_poke <image> <row> <state> <uuid_byte_hex> <last_seen_unix>  -- write
 *   node_poke <image> <row>                                           -- dump
 *
 * The dump form is read-only (no checksum rewrite) and prints
 * "state=X hb_seq=Y last_seen=Z" -- used to confirm this node's own row
 * actually gets a periodic heartbeat renewal (hb_seq/last_seen
 * advancing across a sleep) rather than being written once and never
 * touched again. Safe to call while mounted for the same reason as
 * inode_lock_poke.c's dump mode: the kernel writes this row through
 * sync_dirty_buffer(), so a direct read of the backing device always
 * sees the latest value.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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
    /* The 6-arg form also sets hb_interval_secs, so a test can pose as a
     * peer that beats more slowly than the observer's own window -- the
     * case that used to get a live node declared dead. */
    if (argc != 3 && argc != 4 && argc != 5 && argc != 6 && argc != 7) {
        fprintf(stderr,
                "usage: %s <image> <row> [<state> <uuid_byte_hex> <last_seen_unix>]\n"
                "       %s <image> <row> --bump-fence <n>   (simulate a peer revoking this row's lease)\n"
                "       %s <image> <row> --beat             (advance hb_seq, i.e. impersonate a live node)\n"
                "       %s <image> <row> --beat-keep-time   (same, but leave last_seen alone: a SKEWED live node)\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }

    const char *path = argv[1];
    uint32_t row = (uint32_t) strtoul(argv[2], NULL, 0);
    bool dump_only = (argc == 3);

    int fd = open(path, dump_only ? O_RDONLY : O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(fd, &sb, sizeof(sb), 0);

    if (row >= cetrafs_le32(sb.node_table_count)) {
        fprintf(stderr, "row %u out of range (node_table_count=%u)\n", row, sb.node_table_count);
        return 1;
    }

    off_t row_off = (off_t) (cetrafs_le64(sb.node_table_start) + row) * CETRAFS_BLOCK_SIZE /* v0x0007: one row per block */;

    cetrafs_node_entry_t ne;
    pread_all(fd, &ne, sizeof(ne), row_off);

    if (dump_only) {
        printf("state=%u hb_seq=%" PRIu64 " last_seen=%" PRIu64 " fence_epoch=%" PRIu64 " hb_interval=%u\n",
               ne.state, ne.hb_seq, ne.last_seen, ne.fence_epoch, ne.hb_interval_secs);
        close(fd);
        return 0;
    }

    /* --bump-fence: leave the row otherwise untouched and only advance
     * fence_epoch, exactly as a peer reclaiming something from this node
     * would (node.c's cetrafs_node_fence_peer). */
    /* --beat: advance this row's heartbeat counter the way a live node's
     * own tick would. Staleness is decided by watching hb_seq move, so
     * this is the only way a test can impersonate a node that is still
     * alive -- a timestamp no longer proves anything. */
    /* --beat-keep-time: advance hb_seq but leave last_seen exactly as it
     * is. This is a peer whose CLOCK disagrees with ours while it is
     * perfectly healthy -- the shape that used to get such a node
     * declared dead and its claims stolen. */
    if (argc == 4 && strcmp(argv[3], "--beat-keep-time") == 0) {
        ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
        ne.checksum = 0;
        ne.checksum = cetrafs_cpu_to_le64(crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(cetrafs_le64(ne.checksum))));
        pwrite_all(fd, &ne, sizeof(ne), row_off);
        close(fd);
        printf("node_poke: row %u hb_seq -> %" PRIu64 " (last_seen untouched)\n", row, ne.hb_seq);
        return 0;
    }

    if (argc == 4 && strcmp(argv[3], "--beat") == 0) {
        ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
        ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
        ne.checksum = 0;
        ne.checksum = cetrafs_cpu_to_le64(crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(cetrafs_le64(ne.checksum))));
        pwrite_all(fd, &ne, sizeof(ne), row_off);
        close(fd);
        printf("node_poke: row %u hb_seq -> %" PRIu64 "\n", row, ne.hb_seq);
        return 0;
    }

    /* --badsum: flip the row's checksum and NOTHING else. The fields
     * stay plausible, so only the reader's checksum verification can
     * catch it -- the same discrimination argument as inode_block_poke's
     * `corrupt` mode. Restoring is any ordinary write of the row (every
     * other mode restamps a correct checksum). */
    if (argc == 4 && strcmp(argv[3], "--badsum") == 0) {
        ne.checksum = cetrafs_cpu_to_le64(cetrafs_le64(ne.checksum) ^ 0xFFFFFFFFu);
        pwrite_all(fd, &ne, sizeof(ne), row_off);
        close(fd);
        printf("node_poke: row %u checksum invalidated\n", row);
        return 0;
    }

    if (argc == 5 && strcmp(argv[3], "--bump-fence") == 0) {
        ne.fence_epoch = cetrafs_cpu_to_le64(cetrafs_le64(ne.fence_epoch) + (strtoull(argv[4], NULL, 0)));
        ne.checksum = 0;
        ne.checksum = cetrafs_cpu_to_le64(crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(cetrafs_le64(ne.checksum))));
        pwrite_all(fd, &ne, sizeof(ne), row_off);
        close(fd);
        printf("node_poke: row %u fence_epoch -> %" PRIu64 "\n", row, ne.fence_epoch);
        return 0;
    }

    uint32_t state = (uint32_t) strtoul(argv[3], NULL, 0);
    uint8_t uuid_byte = (uint8_t) strtoul(argv[4], NULL, 16);
    uint64_t last_seen = strtoull(argv[5], NULL, 0);

    memset(&ne, 0, sizeof(ne));
    memset(ne.node_uuid, uuid_byte, sizeof(ne.node_uuid));
    ne.state = cetrafs_cpu_to_le32(state);
    ne.hb_seq = cetrafs_cpu_to_le64(1);
    ne.last_seen = cetrafs_cpu_to_le64(last_seen);
    if (argc == 7)
        ne.hb_interval_secs = cetrafs_cpu_to_le32((uint32_t) strtoul(argv[6], NULL, 0));
    ne.checksum = 0;
    ne.checksum = cetrafs_cpu_to_le64(crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(cetrafs_le64(ne.checksum))));

    pwrite_all(fd, &ne, sizeof(ne), row_off);
    close(fd);

    printf("node_poke: row=%u state=%u uuid_byte=%02x last_seen=%" PRIu64 " hb_interval=%u\n", row, state,
           uuid_byte, last_seen, ne.hb_interval_secs);
    return 0;
}
