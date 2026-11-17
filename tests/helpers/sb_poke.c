// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * sb_poke.c -- test-only helper: dump, or patch one field of, a cetrafs
 * superblock on a raw image, recomputing the CRC32C so the result is a
 * structurally VALID superblock that happens to say something wrong.
 *
 * That is the whole point. Every field the module reads out of block 0
 * is protected by a checksum, and a checksum only proves the bytes are
 * the bytes that were written -- it says nothing about whether the
 * region map they describe is sane. A superblock whose inode_table_start
 * points at the Zone Group table is perfectly well-formed, and every
 * file creation then blind-writes an inode record over a ZG record.
 * So the test has to produce exactly that: valid CRC, wrong value.
 *
 * Usage: sb_poke <image>                  dump the layout fields
 *        sb_poke <image> <field> <value>  set one field, re-checksum
 *
 * Fields are the struct's own names (see the table below).
 */
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

/* width: 8 for __le64, 4 for __le32, 2 for __le16 */
static const struct {
    const char *name;
    size_t off;
    int width;
} FIELDS[] = {
    {"version", offsetof(cetrafs_superblock_t, version), 2},
    {"sb_bytes", offsetof(cetrafs_superblock_t, sb_bytes), 2},
    {"total_blocks", offsetof(cetrafs_superblock_t, total_blocks), 8},
    {"zone_group_count", offsetof(cetrafs_superblock_t, zone_group_count), 4},
    {"block_group_count", offsetof(cetrafs_superblock_t, block_group_count), 4},
    {"zg_table_start", offsetof(cetrafs_superblock_t, zg_table_start), 8},
    {"bg_table_start", offsetof(cetrafs_superblock_t, bg_table_start), 8},
    {"inode_bmap_start", offsetof(cetrafs_superblock_t, inode_bmap_start), 8},
    {"inode_bmap_blocks", offsetof(cetrafs_superblock_t, inode_bmap_blocks), 8},
    {"inode_table_start", offsetof(cetrafs_superblock_t, inode_table_start), 8},
    {"inode_table_blocks", offsetof(cetrafs_superblock_t, inode_table_blocks), 8},
    {"bg_regions_start", offsetof(cetrafs_superblock_t, bg_regions_start), 8},
    {"bg_size_blocks", offsetof(cetrafs_superblock_t, bg_size_blocks), 8},
    {"inodes_count", offsetof(cetrafs_superblock_t, inodes_count), 4},
    {"inode_size", offsetof(cetrafs_superblock_t, inode_size), 4},
    {"root_ino", offsetof(cetrafs_superblock_t, root_ino), 8},
    {"node_table_start", offsetof(cetrafs_superblock_t, node_table_start), 8},
    {"node_table_blocks", offsetof(cetrafs_superblock_t, node_table_blocks), 8},
    {"node_table_count", offsetof(cetrafs_superblock_t, node_table_count), 4},
    {"node_entry_size", offsetof(cetrafs_superblock_t, node_entry_size), 4},
    {"node_journal_start", offsetof(cetrafs_superblock_t, node_journal_start), 8},
    {"node_journal_blocks", offsetof(cetrafs_superblock_t, node_journal_blocks), 4},
    {"pending_free_start", offsetof(cetrafs_superblock_t, pending_free_start), 8},
    {"pending_free_blocks_per_zg", offsetof(cetrafs_superblock_t, pending_free_blocks_per_zg), 4},
    {"features_compat", offsetof(cetrafs_superblock_t, features_compat), 8},
    {"features_incompat", offsetof(cetrafs_superblock_t, features_incompat), 8},
    {"features_ro_compat", offsetof(cetrafs_superblock_t, features_ro_compat), 8},
    /* Grow (extendfs): all four read 0 on a volume that has never been
     * grown, which is what tests/image/mkfs_partial_size.sh asserts. */
    {"layout_gen", offsetof(cetrafs_superblock_t, layout_gen), 8},
    {"tail_reserve_start", offsetof(cetrafs_superblock_t, tail_reserve_start), 8},
    {"tail_reserve_blocks", offsetof(cetrafs_superblock_t, tail_reserve_blocks), 8},
    {"orphan_blocks", offsetof(cetrafs_superblock_t, orphan_blocks), 8},
    {"bg_data_end", offsetof(cetrafs_superblock_t, bg_data_end), 8},
    /* The BG table chain. Neither field was reachable from any helper,
     * so no test could build a hostile chain -- which is part of why
     * the chain walk went unexercised for so long. */
    {"bg_table_next", offsetof(cetrafs_superblock_t, bg_table_next), 8},
    {"bg_table_first_count", offsetof(cetrafs_superblock_t, bg_table_first_count), 8},
    {"fsck_needed_since", offsetof(cetrafs_superblock_t, fsck_needed_since), 8},
    {"fsck_needed_node", offsetof(cetrafs_superblock_t, fsck_needed_node), 4},
    {"data_align_blocks", offsetof(cetrafs_superblock_t, data_align_blocks), 4},
};

static uint64_t field_get(const cetrafs_superblock_t *sb, int i)
{
    const uint8_t *p = (const uint8_t *) sb + FIELDS[i].off;

    switch (FIELDS[i].width) {
    case 2: {
        uint16_t v;
        memcpy(&v, p, 2);
        return cetrafs_le16(v);
    }
    case 4: {
        uint32_t v;
        memcpy(&v, p, 4);
        return cetrafs_le32(v);
    }
    default: {
        uint64_t v;
        memcpy(&v, p, 8);
        return cetrafs_le64(v);
    }
    }
}

static void field_set(cetrafs_superblock_t *sb, int i, uint64_t val)
{
    uint8_t *p = (uint8_t *) sb + FIELDS[i].off;

    switch (FIELDS[i].width) {
    case 2: {
        __le16 v = cetrafs_cpu_to_le16((uint16_t) val);
        memcpy(p, &v, 2);
        break;
    }
    case 4: {
        __le32 v = cetrafs_cpu_to_le32((uint32_t) val);
        memcpy(p, &v, 4);
        break;
    }
    default: {
        __le64 v = cetrafs_cpu_to_le64(val);
        memcpy(p, &v, 8);
        break;
    }
    }
}

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    const char *path;
    int fd, i, which = -1;
    int nfields = (int) (sizeof(FIELDS) / sizeof(FIELDS[0]));

    if (argc != 2 && argc != 4) {
        fprintf(stderr, "usage: %s <image>                  (dump)\n", argv[0]);
        fprintf(stderr, "       %s <image> <field> <value>  (set, re-checksum)\n", argv[0]);
        fprintf(stderr, "fields:");
        for (i = 0; i < nfields; i++)
            fprintf(stderr, " %s", FIELDS[i].name);
        fprintf(stderr, "\n");
        return 2;
    }

    path = argv[1];
    fd = open(path, argc == 4 ? O_RDWR : O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    if (pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb)) {
        perror("pread");
        return 1;
    }
    if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC) {
        fprintf(stderr, "sb_poke: not a cetrafs superblock\n");
        return 1;
    }

    if (argc == 2) {
        for (i = 0; i < nfields; i++)
            printf("%s=%" PRIu64 "\n", FIELDS[i].name, field_get(&sb, i));
        printf("uuid=");
        for (i = 0; i < sizeof(sb.uuid); i++)
            printf("%02x", sb.uuid[i]);
        printf("\n");
        return 0;
    }

    for (i = 0; i < nfields; i++)
        if (!strcmp(FIELDS[i].name, argv[2]))
            which = i;
    if (which < 0) {
        fprintf(stderr, "sb_poke: unknown field '%s'\n", argv[2]);
        return 2;
    }

    field_set(&sb, which, strtoull(argv[3], NULL, 0));
    sb.checksum = 0;
    sb.checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum),
                                                   sizeof(sb.checksum)));
    if (pwrite(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb)) {
        perror("pwrite");
        return 1;
    }
    /*
     * The volume's superblock is block 0 AND its copy (A-7): a layout
     * edit to block 0 alone leaves a copy describing another layout,
     * which fsck rightly reports, and every suite that moves a region to
     * see what fsck says about THAT read the copy's error instead. The
     * copy follows, if one is there that verifies; the status fields
     * (fsck_needed_*) are block 0's alone, as in the kernel.
     * SB_POKE_PRIMARY_ONLY=1 leaves the copy as it was.
     */
    if (strncmp(FIELDS[which].name, "fsck_needed_", 12) && !getenv("SB_POKE_PRIMARY_ONLY")) {
        cetrafs_superblock_t copy;
        const off_t at = (off_t) CETRAFS_SB_REPLICA_NR * CETRAFS_BLOCK_SIZE;

        if (pread(fd, &copy, sizeof(copy), at) == (ssize_t) sizeof(copy) &&
            cetrafs_le32(copy.magic) == CETRAFS_MAGIC &&
            (uint32_t) cetrafs_le64(copy.checksum) ==
                crc32c_struct(&copy, sizeof(copy), offsetof(cetrafs_superblock_t, checksum), sizeof(copy.checksum))) {
            copy = sb;
            copy.fsck_needed_since = cetrafs_cpu_to_le64(0);
            copy.fsck_needed_node = cetrafs_cpu_to_le32(0);
            copy.fsck_needed_pad = cetrafs_cpu_to_le32(0);
            copy.checksum = 0;
            copy.checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct(
                &copy, sizeof(copy), offsetof(cetrafs_superblock_t, checksum), sizeof(copy.checksum)));
            if (pwrite(fd, &copy, sizeof(copy), at) != (ssize_t) sizeof(copy)) {
                perror("pwrite (copy)");
                return 1;
            }
        }
    }
    if (fsync(fd) < 0) {
        perror("fsync");
        return 1;
    }
    printf("%s=%" PRIu64 " (checksum recomputed)\n", FIELDS[which].name, field_get(&sb, which));
    return 0;
}
