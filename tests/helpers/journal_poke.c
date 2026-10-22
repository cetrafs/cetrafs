// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * journal_poke.c -- test-only helper: write a valid (correctly
 * checksummed) journal entry directly into one NODE's per-node journal
 * area on a raw cetrafs image, and set that node's journal flag block to
 * DIRTY so the kernel's replay actually scans it.
 *
 * Rewritten for the per-node journal redesign
 * -- journals used to be per-ZG. The reason this helper exists at all is
 * unchanged: the kernel consumes every entry within its own operation
 * (and parks the flag clean at unmount), so an ordinary touch+umount
 * never leaves a dangling entry behind for the replay test to recover --
 * the "crashed between journal commit and target write" state has to be
 * constructed directly, the same way zg_poke.c/bg_poke.c construct
 * theirs.
 *
 * Usage: journal_poke <image> <node_id> <slot> <target_lba> <payload_file>
 *            [--guard-current | --guard-stale | --fresh]
 * <payload_file> must be exactly CETRAFS_BLOCK_SIZE bytes.
 *
 * The optional last argument sets the entry's replay-guard fields
 * (cetrafs_journal_header_t.flags / prev_checksum); with none of them the
 * entry is written the way a module predating the guard wrote it (flags
 * == 0), which replay still applies unverified -- that is the rolling-
 * upgrade path, and journal.sh covers it.
 *   --guard-current  F_GUARDED, prev_checksum = CRC of target_lba as it
 *                    reads RIGHT NOW. Replay must APPLY it.
 *   --guard-stale    F_GUARDED, prev_checksum = a value the target
 *                    cannot hold. Stands for "another node rewrote this
 *                    block after the entry was written"; replay must
 *                    REFUSE it.
 *   --fresh          F_FRESH: the target was a newly allocated block.
 *                    Replay must SKIP it.
 *
 * Two extra modes against the node's flag block (for the
 * journal_attach_wait suite -- a live foreign replay claim on OUR OWN
 * area cannot be produced by any single-node sequence of mounts):
 *   journal_poke <image> <node_id> --dump            -- print state/replay_owner
 *   journal_poke <image> <node_id> --claim <owner|release> -- force the flag: DIRTY+owner, or CLEAN+none
 */
#include <fcntl.h>
#include <inttypes.h>
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
    int dump = (argc == 4 && !strcmp(argv[3], "--dump"));
    int claim = (argc == 5 && !strcmp(argv[3], "--claim"));
    const char *guard = (argc == 7) ? argv[6] : NULL;

    if (argc != 6 && argc != 7 && !dump && !claim) {
        fprintf(stderr,
                "usage: %s <image> <node_id> <slot> <target_lba> <payload_file> "
                "[--guard-current|--guard-stale|--fresh]\n"
                "       %s <image> <node_id> --dump\n"
                "       %s <image> <node_id> --claim <replay_owner|release>\n",
                argv[0], argv[0], argv[0]);
        return 2;
    }
    if (guard && strcmp(guard, "--guard-current") && strcmp(guard, "--guard-stale") && strcmp(guard, "--fresh")) {
        fprintf(stderr, "unknown guard mode '%s'\n", guard);
        return 2;
    }

    const char *path = argv[1];
    uint32_t node_id = (uint32_t) strtoul(argv[2], NULL, 0);
    uint64_t slot = (dump || claim) ? 0 : strtoull(argv[3], NULL, 0);
    uint64_t target_lba = (dump || claim) ? 0 : strtoull(argv[4], NULL, 0);
    const char *payload_path = (dump || claim) ? NULL : argv[5];

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(fd, &sb, sizeof(sb), 0);

    if (node_id >= cetrafs_le32(sb.node_table_count)) {
        fprintf(stderr, "node_id %u out of range (node_table_count=%u)\n", node_id, sb.node_table_count);
        return 1;
    }
    if (!cetrafs_le64(sb.node_journal_start) || cetrafs_le32(sb.node_journal_blocks) < 3) {
        fprintf(stderr, "image has no per-node journal (mkfs -J 0?)\n");
        return 1;
    }

    uint64_t area_start = cetrafs_le64(sb.node_journal_start) + (uint64_t) node_id * cetrafs_le32(sb.node_journal_blocks);
    uint64_t slots = (cetrafs_le32(sb.node_journal_blocks) - 1) / 2;

    if (dump) {
        cetrafs_node_journal_hdr_t flag;
        pread_all(fd, &flag, sizeof(flag), (off_t) area_start * CETRAFS_BLOCK_SIZE);
        close(fd);
        printf("state=%u replay_owner=%u claimed=%" PRIu64 "\n", cetrafs_le32(flag.state),
               cetrafs_le32(flag.replay_owner), (uint64_t) cetrafs_le64(flag.replay_claimed));
        return 0;
    }

    if (claim) {
        cetrafs_node_journal_hdr_t flag;
        memset(&flag, 0, sizeof(flag));
        flag.magic = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_MAGIC);
        if (!strcmp(argv[4], "release")) {
            flag.state = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_CLEAN);
            flag.replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        } else {
            flag.state = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_DIRTY);
            flag.replay_owner = cetrafs_cpu_to_le32((uint32_t) strtoul(argv[4], NULL, 0));
            flag.replay_claimed = cetrafs_cpu_to_le64(1); /* nonzero, forensics only */
        }
        pwrite_all(fd, &flag, sizeof(flag), (off_t) area_start * CETRAFS_BLOCK_SIZE);
        close(fd);
        printf("journal_poke: node %u area flag set (state=%u replay_owner=%u)\n", node_id,
               cetrafs_le32(flag.state), cetrafs_le32(flag.replay_owner));
        return 0;
    }

    if (slot >= slots) {
        fprintf(stderr, "slot %" PRIu64 " out of range (node has %" PRIu64 " slots)\n", slot, slots);
        return 1;
    }

    int pf = open(payload_path, O_RDONLY);
    if (pf < 0) {
        perror("open payload");
        return 1;
    }
    uint8_t payload[CETRAFS_BLOCK_SIZE];
    if (read(pf, payload, sizeof(payload)) != (ssize_t) sizeof(payload)) {
        fprintf(stderr, "payload file must be exactly %d bytes\n", CETRAFS_BLOCK_SIZE);
        return 1;
    }
    close(pf);

    uint64_t header_lba = area_start + 1 + slot * 2;
    uint64_t payload_lba = header_lba + 1;

    pwrite_all(fd, payload, sizeof(payload), (off_t) payload_lba * CETRAFS_BLOCK_SIZE);

    cetrafs_journal_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = cetrafs_cpu_to_le32(CETRAFS_JOURNAL_MAGIC);
    hdr.txn_id = cetrafs_cpu_to_le64(1);
    hdr.target_lba = cetrafs_cpu_to_le64(target_lba);
    hdr.payload_checksum = cetrafs_cpu_to_le32(crc32c_update(0, payload, sizeof(payload)));
    if (guard && !strcmp(guard, "--fresh")) {
        hdr.flags = cetrafs_cpu_to_le32(CETRAFS_JRNL_F_FRESH);
    } else if (guard) {
        uint8_t cur[CETRAFS_BLOCK_SIZE];
        uint32_t prev;

        pread_all(fd, cur, sizeof(cur), (off_t) target_lba * CETRAFS_BLOCK_SIZE);
        prev = crc32c_update(0, cur, sizeof(cur));
        if (!strcmp(guard, "--guard-stale"))
            prev = ~prev; /* a value the target provably does not hold */
        hdr.flags = cetrafs_cpu_to_le32(CETRAFS_JRNL_F_GUARDED);
        hdr.prev_checksum = cetrafs_cpu_to_le32(prev);
    }
    hdr.header_checksum = 0;
    hdr.header_checksum =
        cetrafs_cpu_to_le32(crc32c_struct(&hdr, sizeof(hdr), offsetof(cetrafs_journal_header_t, header_checksum), sizeof(hdr.header_checksum)));

    pwrite_all(fd, &hdr, sizeof(hdr), (off_t) header_lba * CETRAFS_BLOCK_SIZE);

    /* Set the node's own flag block to DIRTY -- without it, replay's
     * fast path would skip this area entirely. */
    cetrafs_node_journal_hdr_t flag;
    memset(&flag, 0, sizeof(flag));
    flag.magic = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_MAGIC);
    flag.state = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_DIRTY);
    pwrite_all(fd, &flag, sizeof(flag), (off_t) area_start * CETRAFS_BLOCK_SIZE);

    close(fd);

    printf("journal_poke: node %u slot %" PRIu64 " -> target_lba=%" PRIu64 ", flags=0x%x, flag forced DIRTY\n",
           node_id, slot, target_lba, cetrafs_le32(hdr.flags));
    /* Printed so a caller can corrupt the payload without re-deriving
     * the journal geometry itself. */
    printf("header_lba=%" PRIu64 " payload_lba=%" PRIu64 "\n", header_lba, header_lba + 1);
    return 0;
}
