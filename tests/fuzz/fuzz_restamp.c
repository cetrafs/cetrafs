// SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary
/*
 * fuzz_restamp -- the stage-2 fuzzer's field-aware restamper.
 *
 * Stage-1 (fuzz.py's blind mutator + sb_restamp) reaches the geometry
 * code behind the SUPERBLOCK checksum, but a blind mutation of any
 * DEEPER structure (a ZG/BG/inode/Node-Registry record, or a dirent /
 * extent-leaf / xattr block tail) just dies at that structure's own
 * checksum before its parser ever runs. This tool is the counterpart of
 * sb_restamp for every other checksummed structure: given a structure's
 * location, it recomputes its checksum(s) over whatever (possibly
 * mutated) bytes are there now, so a hostile-but-checksum-VALID record
 * reaches the parser behind it -- exactly what a real attacker does.
 *
 * Reuses include/cetrafs.h + userspace/crc32c.h so the format knowledge
 * (field offsets, checksum spans, tail layout) lives in exactly one
 * place (same pattern as sb_restamp.c and the tests/helpers/*_poke.c).
 *
 * Usage:
 *   fuzz_restamp <image> info                 -- print geometry (key=val)
 *   fuzz_restamp <image> stamp <type> <off>   -- restamp one structure
 *
 * <type> is sb|zg|bg|bgh|inode|node|tail. <off> is the structure's byte
 * offset in the image (block-aligned for everything except 'node', whose
 * rows are densely packed). 'tail' recomputes the block's trailing CRC
 * and preserves whatever tail magic is there (so the content, not the
 * magic, is what gets fuzzed).
 */
#define _GNU_SOURCE
#include <endian.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static int read_at(int fd, void *buf, size_t n, off_t off)
{
    return pread(fd, buf, n, off) == (ssize_t) n ? 0 : -1;
}
static int write_at(int fd, const void *buf, size_t n, off_t off)
{
    return pwrite(fd, buf, n, off) == (ssize_t) n ? 0 : -1;
}

/* store a 32-bit CRC into an __le64 checksum field at buf+csum_off */
static void put_csum64(uint8_t *buf, size_t csum_off, uint32_t crc)
{
    uint64_t v = htole64((uint64_t) crc);
    memcpy(buf + csum_off, &v, sizeof(v));
}

static int do_info(int fd)
{
    cetrafs_superblock_t sb;
    if (read_at(fd, &sb, sizeof(sb), 0))
        return 1;
#define U32(f) ((unsigned long long) le32toh(sb.f))
#define U64(f) ((unsigned long long) le64toh(sb.f))
    printf("total_blocks=%llu\n", U64(total_blocks));
    printf("zg_table_start=%llu\n", U64(zg_table_start));
    printf("zone_group_count=%llu\n", U32(zone_group_count));
    printf("bg_table_start=%llu\n", U64(bg_table_start));
    printf("block_group_count=%llu\n", U32(block_group_count));
    printf("inode_table_start=%llu\n", U64(inode_table_start));
    printf("inodes_count=%llu\n", U32(inodes_count));
    printf("node_table_start=%llu\n", U64(node_table_start));
    printf("node_table_count=%llu\n", U32(node_table_count));
    printf("node_entry_size=%llu\n", U64(node_entry_size)); /* __le32 field; widen is fine */
    printf("bg_regions_start=%llu\n", U64(bg_regions_start));
    printf("node_journal_start=%llu\n", U64(node_journal_start));
    printf("node_journal_blocks=%llu\n", U32(node_journal_blocks));
#undef U32
#undef U64
    return 0;
}

static int stamp_sb(int fd, off_t off)
{
    cetrafs_superblock_t sb;
    if (read_at(fd, &sb, sizeof(sb), off))
        return 1;
    uint8_t *b = (uint8_t *) &sb;
    uint32_t crc = crc32c_struct(b, sizeof(sb), offsetof(cetrafs_superblock_t, checksum),
                                 sizeof(sb.checksum));
    put_csum64(b, offsetof(cetrafs_superblock_t, checksum), crc);
    return write_at(fd, &sb, sizeof(sb), off);
}

static int stamp_zg(int fd, off_t off)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    if (read_at(fd, blk, sizeof(blk), off))
        return 1;
    /* hot sector: CRC over [0, HOT_LEN) with hot_checksum zeroed */
    uint32_t hc = crc32c_struct(blk, CETRAFS_ZG_HOT_LEN,
                                offsetof(cetrafs_zone_group_t, hot_checksum),
                                sizeof(((cetrafs_zone_group_t *) 0)->hot_checksum));
    put_csum64(blk, offsetof(cetrafs_zone_group_t, hot_checksum), hc);
    /* cold region: CRC over [HOT_LEN, BLOCK) with cold_checksum zeroed */
    uint32_t cc = crc32c_struct(blk + CETRAFS_ZG_COLD_OFF, CETRAFS_ZG_COLD_LEN,
                                offsetof(cetrafs_zone_group_t, cold_checksum) - CETRAFS_ZG_COLD_OFF,
                                sizeof(((cetrafs_zone_group_t *) 0)->cold_checksum));
    put_csum64(blk, offsetof(cetrafs_zone_group_t, cold_checksum), cc);
    return write_at(fd, blk, sizeof(blk), off);
}

/* BG descriptor and BG header: CRC over the whole 4096-byte block with
 * the checksum field zeroed (matches cetrafs_bg_crc_verify). */
static int stamp_block_csum(int fd, off_t off, size_t csum_off)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    if (read_at(fd, blk, sizeof(blk), off))
        return 1;
    uint32_t crc = crc32c_struct(blk, CETRAFS_BLOCK_SIZE, csum_off, sizeof(uint64_t));
    put_csum64(blk, csum_off, crc);
    return write_at(fd, blk, sizeof(blk), off);
}

static int stamp_inode(int fd, off_t off)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    if (read_at(fd, blk, sizeof(blk), off))
        return 1;
    /* v0x0005 two-sector record: echoes + per-sector CRCs. */
    cetrafs_inode_stamp_crcs_us((cetrafs_inode_t *) blk);
    return write_at(fd, blk, sizeof(blk), off);
}

static int stamp_node(int fd, off_t off)
{
    cetrafs_node_entry_t ne;
    if (read_at(fd, &ne, sizeof(ne), off))
        return 1;
    uint8_t *b = (uint8_t *) &ne;
    uint32_t crc = crc32c_struct(b, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum),
                                 sizeof(ne.checksum));
    put_csum64(b, offsetof(cetrafs_node_entry_t, checksum), crc);
    return write_at(fd, &ne, sizeof(ne), off);
}

/* A journal slot: a header block followed by its payload block. The kernel
 * validates payload_checksum = ~crc32c(~0, payload, BLOCK) and header_checksum
 * = crc32c over the header block with that field zeroed, so a mutated entry is
 * replayed only if both are recomputed. This is what lets mount replay reach
 * journal.c's redo with hostile target_lba / payload. */
static int stamp_journal(int fd, off_t header_off)
{
    uint8_t hblk[CETRAFS_BLOCK_SIZE], pblk[CETRAFS_BLOCK_SIZE];
    if (read_at(fd, hblk, sizeof(hblk), header_off) ||
        read_at(fd, pblk, sizeof(pblk), header_off + CETRAFS_BLOCK_SIZE))
        return 1;
    uint32_t pc = crc32c_update(0, pblk, CETRAFS_BLOCK_SIZE);
    uint32_t le_pc = htole32(pc);
    memcpy(hblk + offsetof(cetrafs_journal_header_t, payload_checksum), &le_pc, 4);
    uint32_t hc = crc32c_struct(hblk, sizeof(cetrafs_journal_header_t),
                                offsetof(cetrafs_journal_header_t, header_checksum), 4);
    uint32_t le_hc = htole32(hc);
    memcpy(hblk + offsetof(cetrafs_journal_header_t, header_checksum), &le_hc, 4);
    return write_at(fd, hblk, sizeof(hblk), header_off);
}


static void set_extent(cetrafs_extent_t *e, uint32_t block, uint32_t len, uint64_t phys)
{
    e->ee_block = htole32(block);
    __le16 hi;
    __le32 lo;
    e->ee_len = cetrafs_extent_pack_len(len, 0);
    cetrafs_extent_phys_to_hilo(phys, &hi, &lo);
    e->ee_start_hi = hi;
    e->ee_start_lo = lo;
    e->ee_pad = 0;
}

/* Structure-aware extent-tree crafter (the fuzzer's "next stage"): writes an
 * inode a VALID extent header but adversarial, internally-consistent extent
 * CONTENTS -- overlaps, huge-but-in-field lengths, metadata/out-of-range
 * targets, zero lengths, duplicate logical blocks, (depth 1) a crafted leaf
 * block with a valid LEAF tail, and (depth 2) a crafted interior IBLK whose
 * index entries point at real hostile leaves, at the superblock, or past the
 * device -- the only variants that reach the interior level tree_flatten
 * walks. These coupled hostile trees are what single-field flips cannot
 * build, and they drive get_block lookup/append, truncate, punch, fiemap and
 * SEEK against a tree that passes every header and tail check. Restamps the
 * inode and every crafted index/leaf block's tail. */
static int craft_tree(int fd, off_t inode_off, unsigned variant)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_superblock_t sb;
    if (read_at(fd, blk, sizeof(blk), inode_off) || read_at(fd, &sb, sizeof(sb), 0))
        return 1;
    cetrafs_inode_t *in = (cetrafs_inode_t *) blk;
    uint64_t tot = le64toh(sb.total_blocks);
    uint64_t bgts = le64toh(sb.bg_table_start);
    uint64_t data0 = 1;
    cetrafs_block_group_t bg0;
    if (bgts && read_at(fd, &bg0, sizeof(bg0), (off_t) bgts * CETRAFS_BLOCK_SIZE) == 0)
        data0 = le64toh(bg0.start_block) + le32toh(bg0.off_data_region);

    memset(&in->eh, 0, sizeof(in->eh));
    memset(&in->et, 0, sizeof(in->et));
    in->eh.eh_magic = htole16(CETRAFS_EXT_MAGIC);
    in->eh.eh_max = htole16(4);

    unsigned v = variant % 12;
    if (v < 6) {
        cetrafs_extent_t *L = in->et.leaf;
        in->eh.eh_depth = 0;
        switch (v) {
        case 0: /* every extent points at the superblock (block 0) */
            set_extent(&L[0], 0, 1, 0); set_extent(&L[1], 1, 1, 0);
            set_extent(&L[2], 2, 1, 0); set_extent(&L[3], 3, 1, 0);
            in->eh.eh_entries = htole16(4); break;
        case 1: /* two extents sharing one physical run (self-overlap) */
            set_extent(&L[0], 0, 4, data0); set_extent(&L[1], 4, 4, data0);
            in->eh.eh_entries = htole16(2); break;
        case 2: /* one maximal (2^31-1) length */
            set_extent(&L[0], 0, CETRAFS_EXT_LEN_MASK, data0);
            in->eh.eh_entries = htole16(1); break;
        case 3: /* zero-length extents */
            set_extent(&L[0], 0, 0, data0); set_extent(&L[1], 1, 0, data0);
            in->eh.eh_entries = htole16(2); break;
        case 4: /* physical target far past the device */
            set_extent(&L[0], 0, 1, tot + 1000000ULL);
            in->eh.eh_entries = htole16(1); break;
        case 5: /* duplicate logical block across extents */
            set_extent(&L[0], 0, 1, data0); set_extent(&L[1], 0, 1, data0 + 1);
            set_extent(&L[2], 0, 1, data0 + 2);
            in->eh.eh_entries = htole16(3); break;
        }
    } else if (v < 8) {
        /* depth 1: idx[0] -> a crafted leaf block (hostile array, valid tail) */
        uint64_t leaf_lba = data0 + 1;
        uint8_t lblk[CETRAFS_BLOCK_SIZE];
        cetrafs_extent_hdr_t *lh = (cetrafs_extent_hdr_t *) lblk;
        cetrafs_extent_t *LE = (cetrafs_extent_t *) (lblk + sizeof(*lh));
        cetrafs_blk_tail_t *lt = (cetrafs_blk_tail_t *) (lblk + CETRAFS_BLK_TAIL_OFF);
        int i;

        in->eh.eh_depth = htole16(1);
        in->eh.eh_entries = htole16(1);
        __le16 ihi;
        __le32 ilo;
        in->et.idx[0].ei_block = 0;
        cetrafs_extent_phys_to_hilo(leaf_lba, &ihi, &ilo);
        in->et.idx[0].ei_leaf_hi = ihi;
        in->et.idx[0].ei_leaf_lo = ilo;

        memset(lblk, 0, sizeof(lblk));
        lh->eh_magic = htole16(CETRAFS_EXT_MAGIC);
        lh->eh_depth = 0;
        lh->eh_max = htole16(CETRAFS_EXT_BLOCK_MAX_LEAVES);
        if (v == 6) { /* leaf full of overlapping extents */
            for (i = 0; i < 8; i++)
                set_extent(&LE[i], (uint32_t) i, 4, data0);
            lh->eh_entries = htole16(8);
        } else { /* v == 7: maximal length + out-of-range target */
            set_extent(&LE[0], 0, CETRAFS_EXT_LEN_MASK, data0);
            set_extent(&LE[1], 100, 1, tot + 50000ULL);
            lh->eh_entries = htole16(2);
        }
        lt->magic = htole32(CETRAFS_LEAF_TAIL_MAGIC);
        lt->crc = htole32(crc32c_update(0, lblk, CETRAFS_BLK_TAIL_OFF));
        if (write_at(fd, lblk, sizeof(lblk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE))
            return 1;
    } else {
        /* depth 2: idx[0] -> interior index block (IBLK) -> leaf(s) (LBLK),
         * every block's tail valid so the whole depth-2 tree PARSES while its
         * contents are hostile. The only variant class that reaches the
         * interior level -- tree_flatten walking root->interior->leaf,
         * get_block/truncate across it -- which depths 0-1 never touch. */
        uint64_t interior_lba = data0 + 1;
        uint64_t leaf0_lba = data0 + 2, leaf1_lba = data0 + 3;
        uint8_t iblk[CETRAFS_BLOCK_SIZE];
        cetrafs_extent_hdr_t *ih = (cetrafs_extent_hdr_t *) iblk;
        cetrafs_extent_idx_t *IE = (cetrafs_extent_idx_t *) (iblk + sizeof(*ih));
        cetrafs_blk_tail_t *it = (cetrafs_blk_tail_t *) (iblk + CETRAFS_BLK_TAIL_OFF);
        unsigned dv = v - 8; /* 0..3 */
        __le16 hi;
        __le32 lo;

        in->eh.eh_depth = htole16(2);
        in->eh.eh_entries = htole16(1);
        in->et.idx[0].ei_block = 0;
        cetrafs_extent_phys_to_hilo(interior_lba, &hi, &lo);
        in->et.idx[0].ei_leaf_hi = hi;
        in->et.idx[0].ei_leaf_lo = lo;

        memset(iblk, 0, sizeof(iblk));
        ih->eh_magic = htole16(CETRAFS_EXT_MAGIC);
        ih->eh_depth = htole16(1);
        ih->eh_max = htole16(CETRAFS_EXT_BLOCK_MAX_IDX);

        if (dv == 1) {
            /* interior points its leaf at block 0 (the superblock): the leaf
             * read lands on the SB, which is not a valid LEAF block, so the
             * kernel must reject rather than parse it. */
            IE[0].ei_block = 0;
            cetrafs_extent_phys_to_hilo(0, &hi, &lo);
            IE[0].ei_leaf_hi = hi;
            IE[0].ei_leaf_lo = lo;
            ih->eh_entries = htole16(1);
        } else if (dv == 2) {
            /* interior points its leaf past the end of the device */
            IE[0].ei_block = 0;
            cetrafs_extent_phys_to_hilo(tot + 70000ULL, &hi, &lo);
            IE[0].ei_leaf_hi = hi;
            IE[0].ei_leaf_lo = lo;
            ih->eh_entries = htole16(1);
        } else {
            /* dv 0 and 3: real leaf block(s) carrying hostile extent arrays */
            uint8_t lblk[CETRAFS_BLOCK_SIZE];
            cetrafs_extent_hdr_t *lh = (cetrafs_extent_hdr_t *) lblk;
            cetrafs_extent_t *LE = (cetrafs_extent_t *) (lblk + sizeof(*lh));
            cetrafs_blk_tail_t *lt = (cetrafs_blk_tail_t *) (lblk + CETRAFS_BLK_TAIL_OFF);

            memset(lblk, 0, sizeof(lblk));
            lh->eh_magic = htole16(CETRAFS_EXT_MAGIC);
            lh->eh_depth = 0;
            lh->eh_max = htole16(CETRAFS_EXT_BLOCK_MAX_LEAVES);
            set_extent(&LE[0], 0, 4, data0);
            set_extent(&LE[1], 2, 4, data0); /* overlaps LE[0] */
            lh->eh_entries = htole16(2);
            lt->magic = htole32(CETRAFS_LEAF_TAIL_MAGIC);
            lt->crc = htole32(crc32c_update(0, lblk, CETRAFS_BLK_TAIL_OFF));
            if (write_at(fd, lblk, sizeof(lblk), (off_t) leaf0_lba * CETRAFS_BLOCK_SIZE))
                return 1;
            IE[0].ei_block = 0;
            cetrafs_extent_phys_to_hilo(leaf0_lba, &hi, &lo);
            IE[0].ei_leaf_hi = hi;
            IE[0].ei_leaf_lo = lo;

            if (dv == 3) {
                /* a second leaf covering an overlapping logical range, reached
                 * through a second (duplicate ei_block) interior entry -- a
                 * cross-leaf overlap the flatten must survive */
                memset(lblk, 0, sizeof(lblk));
                lh->eh_magic = htole16(CETRAFS_EXT_MAGIC);
                lh->eh_depth = 0;
                lh->eh_max = htole16(CETRAFS_EXT_BLOCK_MAX_LEAVES);
                set_extent(&LE[0], 0, CETRAFS_EXT_LEN_MASK, data0); /* maximal */
                lh->eh_entries = htole16(1);
                lt->magic = htole32(CETRAFS_LEAF_TAIL_MAGIC);
                lt->crc = htole32(crc32c_update(0, lblk, CETRAFS_BLK_TAIL_OFF));
                if (write_at(fd, lblk, sizeof(lblk), (off_t) leaf1_lba * CETRAFS_BLOCK_SIZE))
                    return 1;
                IE[1].ei_block = 0;
                cetrafs_extent_phys_to_hilo(leaf1_lba, &hi, &lo);
                IE[1].ei_leaf_hi = hi;
                IE[1].ei_leaf_lo = lo;
                ih->eh_entries = htole16(2);
            } else {
                ih->eh_entries = htole16(1);
            }
        }
        it->magic = htole32(CETRAFS_INDEX_TAIL_MAGIC);
        it->crc = htole32(crc32c_update(0, iblk, CETRAFS_BLK_TAIL_OFF));
        if (write_at(fd, iblk, sizeof(iblk), (off_t) interior_lba * CETRAFS_BLOCK_SIZE))
            return 1;
    }
    if (write_at(fd, blk, sizeof(blk), inode_off))
        return 1;
    return stamp_inode(fd, inode_off);
}

/* Plant a replayable journal entry in node 0's area: flag block DIRTY (so
 * mount scans it) + slot 0 a valid entry whose payload is a copy of its own
 * target block, so a CLEAN (unmutated) replay is a no-op. Prints the slot-0
 * header byte offset. The fuzzer re-plants after each pristine copy, then a
 * mutation of the slot + `stamp journal` makes replay apply hostile data. */
static int plant_journal(int fd)
{
    cetrafs_superblock_t sb;
    if (read_at(fd, &sb, sizeof(sb), 0))
        return 1;
    uint64_t njs = le64toh(sb.node_journal_start);
    uint64_t njb = le32toh(sb.node_journal_blocks);
    uint64_t bgts = le64toh(sb.bg_table_start);
    if (!njs || njb < 1 + CETRAFS_JOURNAL_SLOT_BLOCKS || !bgts)
        return 1; /* -J 0 volume: nothing to plant into */

    /* first usable data block, from BG0's descriptor */
    cetrafs_block_group_t bg0;
    if (read_at(fd, &bg0, sizeof(bg0), (off_t) bgts * CETRAFS_BLOCK_SIZE))
        return 1;
    uint64_t first_data = le64toh(bg0.start_block) + le32toh(bg0.off_data_region);

    /* flag block: DIRTY, so mount's replay scans the slots */
    cetrafs_node_journal_hdr_t flag;
    memset(&flag, 0, sizeof(flag));
    flag.magic = htole32(CETRAFS_NODE_JOURNAL_MAGIC);
    flag.state = htole32(CETRAFS_NODE_JOURNAL_DIRTY);
    flag.replay_owner = htole32(CETRAFS_NODE_ID_NONE);
    if (write_at(fd, &flag, sizeof(flag), (off_t) njs * CETRAFS_BLOCK_SIZE))
        return 1;

    off_t header_off = (off_t) (njs + 1) * CETRAFS_BLOCK_SIZE;
    /* payload = a copy of the target block, so an unmutated replay is a no-op */
    uint8_t pblk[CETRAFS_BLOCK_SIZE];
    if (read_at(fd, pblk, sizeof(pblk), (off_t) first_data * CETRAFS_BLOCK_SIZE) ||
        write_at(fd, pblk, sizeof(pblk), header_off + CETRAFS_BLOCK_SIZE))
        return 1;

    uint8_t hblk[CETRAFS_BLOCK_SIZE];
    memset(hblk, 0, sizeof(hblk));
    cetrafs_journal_header_t *h = (cetrafs_journal_header_t *) hblk;
    h->magic = htole32(CETRAFS_JOURNAL_MAGIC);
    h->txn_id = htole64(1);
    h->target_lba = htole64(first_data);
    if (write_at(fd, hblk, sizeof(hblk), header_off))
        return 1;
    if (stamp_journal(fd, header_off)) /* fills payload_checksum + header_checksum */
        return 1;
    printf("journal_header_off=%lld\n", (long long) header_off);
    return 0;
}

/* dirent / leaf / interior / xattr block: trailing {magic, crc} tail, crc
 * over the block's first CETRAFS_BLK_TAIL_OFF bytes. Both tail structs
 * share the layout (magic then crc, 8 bytes, at BLOCK-8); recompute crc,
 * leave the magic alone so the PARSED content is what the fuzz exercises. */
static int stamp_tail(int fd, off_t off)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    if (read_at(fd, blk, sizeof(blk), off))
        return 1;
    uint32_t crc = crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF);
    uint32_t le = htole32(crc);
    memcpy(blk + CETRAFS_BLK_TAIL_OFF + 4, &le, sizeof(le)); /* crc follows magic */
    return write_at(fd, blk, sizeof(blk), off);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <image> info | %s <image> stamp <type> <byteoffset>\n",
                argv[0], argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    int rc;
    if (strcmp(argv[2], "info") == 0) {
        rc = do_info(fd);
    } else if (strcmp(argv[2], "plant-journal") == 0) {
        rc = plant_journal(fd);
    } else if (strcmp(argv[2], "craft-tree") == 0 && argc == 5) {
        rc = craft_tree(fd, (off_t) strtoull(argv[3], NULL, 0),
                        (unsigned) strtoul(argv[4], NULL, 0));
    } else if (strcmp(argv[2], "stamp") == 0 && argc == 5) {
        const char *type = argv[3];
        off_t off = (off_t) strtoull(argv[4], NULL, 0);
        if (strcmp(type, "sb") == 0)
            rc = stamp_sb(fd, off);
        else if (strcmp(type, "zg") == 0)
            rc = stamp_zg(fd, off);
        else if (strcmp(type, "bg") == 0)
            rc = stamp_block_csum(fd, off, offsetof(cetrafs_block_group_t, checksum));
        else if (strcmp(type, "bgh") == 0)
            rc = stamp_block_csum(fd, off, offsetof(cetrafs_bg_header_t, checksum));
        else if (strcmp(type, "inode") == 0)
            rc = stamp_inode(fd, off);
        else if (strcmp(type, "node") == 0)
            rc = stamp_node(fd, off);
        else if (strcmp(type, "tail") == 0)
            rc = stamp_tail(fd, off);
        else if (strcmp(type, "journal") == 0)
            rc = stamp_journal(fd, off);
        else {
            fprintf(stderr, "unknown type: %s\n", type);
            rc = 2;
        }
    } else {
        fprintf(stderr, "usage: %s <image> info | %s <image> stamp <type> <byteoffset>\n",
                argv[0], argv[0]);
        rc = 2;
    }
    close(fd);
    return rc;
}
