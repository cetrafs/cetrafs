// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * inode_block_poke.c -- test-only helper: overwrite or dump the raw bytes
 * of one inode's slot in the global inode table, writing directly to the
 * loop device's *backing file* rather than the loop device node itself.
 *
 * Exists to reproduce, on a single-kernel loop-device harness, the
 * cross-node data-loss bug fixed in kmod/inode.c's cetrafs_write_raw_
 * inode(): inode records used to be
 * packed ~22 per block, so a stale cached read-modify-write of one
 * inode's record could silently revert a block-mate inode's bytes.
 * Since v0x0007 every record owns a whole block, so this
 * test now guards that structural property end to end rather than the
 * write path's read-freshness.
 *
 * Reproducing that needs two things to be true at once: the kernel's
 * buffer-head cache for the shared block must already be warm (uptodate)
 * *before* the external change lands, and the external change must be
 * genuinely invisible to that cache rather than updating it in place.
 * Writing to the loop device node (e.g. /dev/loopN) wouldn't do that --
 * a buffered write there lands in the exact same bdev page cache
 * sb_bread() reads from (so the kernel would trivially see it, proving
 * nothing), and an O_DIRECT write there actively invalidates that same
 * cache as a side effect (so the bug would look "fixed" even without the
 * real fix). Writing straight to the loop device's *backing file*
 * instead -- a completely separate address_space from the loop block
 * device's own -- changes what's physically on disk without touching
 * the mounted filesystem's cache at all, exactly mirroring what an
 * independent second node's write does to a real shared LUN. This is
 * also why mount_test.sh's other *_poke.c tools always run against the
 * loop device only while *unmounted* (cetrafs_put_super() calls
 * invalidate_bdev() on umount, so the next mount's reads are guaranteed
 * fresh regardless): this tool is the first one that needs to poke
 * *through* a live mount, which is exactly the scenario it exists to
 * test.
 *
 * Usage:
 *   inode_block_poke <backing-file> dump <ino>              -- print the
 *     record's raw bytes as hex to stdout.
 *   inode_block_poke <backing-file> poke <ino> <byte-value>  -- fill the
 *     whole record with the given repeated byte value (0-255).
 *
 * Deliberately does not compute or stamp the record checksums -- the point of
 * this tool is to plant a recognizable byte pattern and later check
 * whether it survived or was reverted, never to hand the kernel a record
 * it would actually accept as valid.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
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
    /* maxleaves takes no inode argument: it prints a compiled-in
     * constant, so it must answer before the usage check below. */
    if (argc == 3 && strcmp(argv[2], "maxleaves") == 0) {
        printf("%u\n", (unsigned) CETRAFS_EXT_BLOCK_MAX_LEAVES);
        return 0;
    }
    if (argc < 4) {
        fprintf(stderr, "usage: %s <backing-file> dump <ino>\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> poke <ino> <byte-value>\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> corrupt <ino>        (invalidate its checksum)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> extlen <ino> <len>    (absurd preallocated extent)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> growext <ino> <n>     (valid record a peer just extended)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> bumpgen <ino> <gen>   (reuse: generation only)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> setsize <ino> <bytes> (as a PEER extending it would)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> size <ino>           (print the on-disk size)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> bumpseq <ino>        (advance dirent_seq, as a peer would)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> extents <ino>       (prints depth/entries/blocks)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> setmode <ino> <octal> (set the raw mode, e.g. 020600 for a chardev)\n",
                argv[0]);
        fprintf(stderr, "       %s <backing-file> nlink <ino> <n>      (set nlink; 0 = a deleted file's record)\n",
                argv[0]);
        fprintf(stderr, "       %s <backing-file> retype_keep_gen <ino> (type change, same generation)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> dirtytail <ino>      (garbage past the record)\n", argv[0]);
        fprintf(stderr, "       %s <backing-file> tailzero <ino>       (prints yes/no)\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    const char *mode = argv[2];
    uint64_t ino = strtoull(argv[3], NULL, 0);

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    cetrafs_superblock_t sb;
    pread_all(fd, &sb, sizeof(sb), 0);

    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %llu out of range (inodes_count=%u)\n", (unsigned long long) ino, sb.inodes_count);
        return 1;
    }

    off_t rec_off = (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * cetrafs_le32(sb.block_size) /* v0x0007: one record per block */;
    unsigned char *buf = malloc(cetrafs_le32(sb.inode_size));
    if (!buf) {
        perror("malloc");
        return 1;
    }

    if (strcmp(mode, "dump") == 0) {
        pread_all(fd, buf, cetrafs_le32(sb.inode_size), rec_off);
        for (uint32_t i = 0; i < cetrafs_le32(sb.inode_size); i++)
            printf("%02x", buf[i]);
        printf("\n");
    } else if (strcmp(mode, "poke") == 0) {
        if (argc < 5) {
            fprintf(stderr, "poke needs a byte value\n");
            return 2;
        }
        unsigned val = (unsigned) strtoul(argv[4], NULL, 0) & 0xff;
        memset(buf, (int) val, cetrafs_le32(sb.inode_size));
        pwrite_all(fd, buf, cetrafs_le32(sb.inode_size), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu record filled with 0x%02x\n", (unsigned long long) ino, val);
    } else if (strcmp(mode, "retype") == 0) {
        /* v0x0008 generation test: rewrite ino's record as a REGULAR
         * file with a new generation (keeping its extents -- the old
         * data block simply becomes file content), valid checksum --
         * simulating "a peer deleted this file and reused its number
         * for a different one" behind a live mount's cache. */
        if (argc < 5) {
            fprintf(stderr, "retype needs a new generation value\n");
            return 2;
        }
        cetrafs_inode_t rec;
        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.mode = cetrafs_cpu_to_le32(0100644); /* S_IFREG | 0644 */
        rec.generation = cetrafs_cpu_to_le64(strtoull(argv[4], NULL, 0));
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu retyped to REG, generation=%llu\n", (unsigned long long) ino,
                (unsigned long long) cetrafs_le64(rec.generation));
    } else if (strcmp(mode, "retype_keep_gen") == 0) {
        /* Change only the file TYPE, keeping the generation and fixing
         * the checksum: the shape a generation collision (or a bug in
         * the generation check) would present. A refresh must refuse it
         * rather than leave the VFS calling one type's operations on
         * another's. */
        cetrafs_inode_t rec;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.mode = cetrafs_cpu_to_le32((cetrafs_le32(rec.mode) & 07777) | 0040000); /* S_IFDIR */
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu retyped to DIR, generation unchanged (%llu)\n",
                (unsigned long long) ino, (unsigned long long) cetrafs_le64(rec.generation));
    } else if (strcmp(mode, "bumpseq") == 0) {
        /* Advance a directory's dirent_seq and restamp the record, the
         * way a PEER's namespace mutation leaves it. Paired with
         * corrupt_poke's dirent erase, this is what a peer unlinking
         * something looks like to a node that has the directory cached. */
        cetrafs_inode_t rec;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.dirent_seq = cetrafs_cpu_to_le64(cetrafs_le64(rec.dirent_seq) + 1);
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu dirent_seq -> %llu\n", (unsigned long long) ino,
                (unsigned long long) cetrafs_le64(rec.dirent_seq));
    } else if (strcmp(mode, "extents") == 0) {
        /* The extent tree's SHAPE, which no other helper exposes.
         * Needed because "this directory is big" is not the same claim
         * as "this directory spilled into an external leaf": the
         * run-aware allocator keeps a directory grown on its own in one
         * contiguous extent however many entries it has, so a test that
         * only counts entries never reaches depth 1 at all. */
        cetrafs_inode_t rec;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        printf("depth=%u entries=%u blocks=%llu size=%llu\n", rec.eh.eh_depth, rec.eh.eh_entries,
               (unsigned long long) cetrafs_le64(rec.blocks), (unsigned long long) cetrafs_le64(rec.size));
        /* Then the entries themselves, IN STORED ORDER. The array is
         * append-only (insert never sorts), so a file written at
         * descending offsets stores its extents reversed from logical
         * order -- and a test of anything that must tolerate that
         * (fiemap, SEEK_HOLE) has to assert the structure really came
         * out unordered, not just that the input used to produce it. */
        if (rec.eh.eh_depth == 0) {
            /* logical AND physical. This printed ee_block as "block",
             * which is the LOGICAL offset -- 0 for a first extent, on
             * every healthy inode -- and never showed the physical
             * start at all, so a reader comparing a damaged inode
             * against a healthy one saw block=0 for both and learned
             * nothing. (It also passed the raw __le32 to %u, unconverted.) */
            for (uint32_t e = 0; e < cetrafs_le16(rec.eh.eh_entries) && e < 4; ++e)
                printf("ext %u logical=%u phys=%llu len=%u\n", e, cetrafs_le32(rec.et.leaf[e].ee_block),
                       (unsigned long long) (((uint64_t) cetrafs_le16(rec.et.leaf[e].ee_start_hi) << 32) |
                                             cetrafs_le32(rec.et.leaf[e].ee_start_lo)),
                       cetrafs_le32(rec.et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK);
        } else if (cetrafs_le16(rec.eh.eh_depth) == 1) {
            uint64_t lba = ((uint64_t) cetrafs_le16(rec.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(rec.et.idx[0].ei_leaf_lo);
            uint8_t blk[CETRAFS_BLOCK_SIZE];
            const cetrafs_extent_hdr_t *lh = (const cetrafs_extent_hdr_t *) blk;

            pread_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
            const cetrafs_extent_t *le = (const cetrafs_extent_t *) (blk + sizeof(*lh));
            uint32_t n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);

            for (uint32_t e = 0; e < n; ++e)
                printf("ext %u logical=%u phys=%llu len=%u\n", e, cetrafs_le32(le[e].ee_block),
                       (unsigned long long) (((uint64_t) cetrafs_le16(le[e].ee_start_hi) << 32) |
                                             cetrafs_le32(le[e].ee_start_lo)),
                       cetrafs_le32(le[e].ee_len) & CETRAFS_EXT_LEN_MASK);
        }
    } else if (strcmp(mode, "setmode") == 0) {
        /* Set the raw mode, S_IFMT included. The point is to produce a
         * type this build cannot create -- a device node, a FIFO -- and
         * see whether the kernel says so or quietly treats it as a
         * regular file and serves its extents as contents. */
        cetrafs_inode_t rec;
        uint32_t m = (argc > 4) ? (uint32_t) strtoul(argv[4], NULL, 8) : 0100644;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.mode = cetrafs_cpu_to_le32(m);
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu mode -> 0%o\n", (unsigned long long) ino, m);
    } else if (strcmp(mode, "leaf") == 0) {
        /* Follow a depth-1 inode's index to its external extent leaf and
         * print what is ON THE DEVICE there. The point is to compare the
         * durable leaf against what the file really has: the leaf is a
         * raw metadata block, not part of the inode's page-cache
         * mapping, so nothing that flushes the file's DATA touches it. */
        cetrafs_inode_t rec;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        if (cetrafs_le16(rec.eh.eh_depth) != 1) {
            printf("depth=%u (no external leaf)\n", rec.eh.eh_depth);
        } else {
            uint64_t lba = ((uint64_t) cetrafs_le16(rec.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(rec.et.idx[0].ei_leaf_lo);
            uint8_t blk[CETRAFS_BLOCK_SIZE];
            const cetrafs_extent_hdr_t *lh = (const cetrafs_extent_hdr_t *) blk;

            pread_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
            const cetrafs_extent_t *le = (const cetrafs_extent_t *) (blk + sizeof(*lh));
            uint64_t blocks = 0;
            uint32_t n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);

            for (uint32_t e = 0; e < n; ++e)
                blocks += cetrafs_le32(le[e].ee_len) & CETRAFS_EXT_LEN_MASK;
            printf("depth=1 leaf_lba=%llu leaf_entries=%u leaf_blocks=%llu\n", (unsigned long long) lba,
                   lh->eh_entries, (unsigned long long) blocks);
        }
    } else if (strcmp(mode, "extlen") == 0) {
        /* Set inline extent 0's length to an arbitrary value and mark it
         * PREALLOCATED, restamping the checksum so the record stays
         * integrity-valid. Reproduces the fuzzer's "valid CRC, insane
         * content" class: an extent claiming more blocks than the device
         * can back, which the split path then tried to free one at a
         * time. */
        cetrafs_inode_t rec;
        unsigned long len = (argc > 4) ? strtoul(argv[4], NULL, 0) : 0;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        /* THREE entries, not one. The tail-release path only runs when
         * the array has room for the initialised entry but NOT for the
         * tail (n + 1 <= max && n + 2 > max), which for the 4-slot
         * inline array means exactly 3. With one entry the split simply
         * appends a tail and the freeing loop never runs -- the first
         * version of this helper set 1 and the test passed against the
         * unfixed kernel. */
        rec.et.leaf[0].ee_len = cetrafs_cpu_to_le32((uint32_t) (len & CETRAFS_EXT_LEN_MASK) | CETRAFS_EXT_UNINIT);
        rec.et.leaf[0].ee_block = cetrafs_cpu_to_le32(0);
        rec.et.leaf[1].ee_block = cetrafs_cpu_to_le32(0x40000000u);
        rec.et.leaf[1].ee_len = cetrafs_cpu_to_le32(1);
        rec.et.leaf[2].ee_block = cetrafs_cpu_to_le32(0x50000000u);
        rec.et.leaf[2].ee_len = cetrafs_cpu_to_le32(1);
        rec.eh.eh_entries = cetrafs_cpu_to_le16(3);
        rec.eh.eh_depth = 0;
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu extent0 len -> %lu, marked preallocated\n",
                (unsigned long long) ino, len);
    } else if (strcmp(mode, "growext") == 0) {
        /* Extend inline extent 0 by n blocks, keeping its physical start
         * and everything else -- what a PEER appending to this file
         * would have left on the device.
         *
         * Unlike extlen above (which rewrites the whole array with
         * nonsense to reproduce a fuzz case), this leaves a RECORD THAT
         * IS ENTIRELY VALID and merely newer than whatever this node has
         * cached. That is the state the background scrub has to survive:
         * blocks referenced only by a record it has not re-read. */
        cetrafs_inode_t rec;
        unsigned long n = (argc > 4) ? strtoul(argv[4], NULL, 0) : 1;
        uint32_t len0;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        if (cetrafs_le16(rec.eh.eh_entries) == 0 || rec.eh.eh_depth != 0) {
            fprintf(stderr, "growext: ino %llu has no inline extent 0 to grow\n", (unsigned long long) ino);
            close(fd);
            return 1;
        }
        len0 = cetrafs_le32(rec.et.leaf[0].ee_len) & CETRAFS_EXT_LEN_MASK;
        rec.et.leaf[0].ee_len = cetrafs_cpu_to_le32((len0 + (uint32_t) n) & CETRAFS_EXT_LEN_MASK);
        rec.blocks = cetrafs_cpu_to_le64(cetrafs_le64(rec.blocks) + n * (CETRAFS_BLOCK_SIZE / 512));
        rec.size = cetrafs_cpu_to_le64(cetrafs_le64(rec.size) + n * CETRAFS_BLOCK_SIZE);
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        printf("inode_block_poke: ino %llu extent0 len %u -> %lu\n", (unsigned long long) ino, len0, len0 + n);
    } else if (strcmp(mode, "bumpgen") == 0) {
        /* Change ONLY the generation, leaving type/size/extents alone:
         * the inode number was reused, but nothing else about the
         * record tells you so. retype also flips the mode to REG, which
         * makes a directory fail ENOTDIR at lookup before any mapping
         * code runs -- useless for testing a check that lives in
         * cetrafs_get_block(). */
        cetrafs_inode_t rec;
        unsigned long long g = (argc > 4) ? strtoull(argv[4], NULL, 0) : 0;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.generation = cetrafs_cpu_to_le64(g);
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu generation -> %llu (type untouched)\n",
                (unsigned long long) ino, g);
    } else if (strcmp(mode, "setsize") == 0) {
        /* Set the on-disk size directly, as a PEER extending the file
         * would leave it. Used to prove this node's deferred
         * .write_inode does not stamp its own stale i_size back over a
         * peer's newer record -- the nofilelock live-migration window. */
        cetrafs_inode_t rec;
        unsigned long long sz = (argc > 4) ? strtoull(argv[4], NULL, 0) : 0;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.size = cetrafs_cpu_to_le64(sz);
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu size -> %llu\n", (unsigned long long) ino, sz);
    } else if (strcmp(mode, "size") == 0) {
        cetrafs_inode_t rec;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        printf("%llu\n", (unsigned long long) cetrafs_le64(rec.size));
    } else if (strcmp(mode, "nlink") == 0) {
        /* Set nlink directly. nlink = 0 with the dirent still in place
         * is exactly the "dangling entry" state fsck reports and that a
         * stale cached dirent block produces across nodes: the record
         * still describes the dead file -- its mode, its size, its
         * extents -- while its blocks are back in the allocator. */
        cetrafs_inode_t rec;
        uint32_t n = (argc > 4) ? (uint32_t) strtoul(argv[4], NULL, 0) : 0;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.nlink = cetrafs_cpu_to_le32(n);
        cetrafs_inode_stamp_crcs_us(&rec); /* v0x0005 */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu nlink -> %u\n", (unsigned long long) ino, n);
    } else if (strcmp(mode, "corrupt") == 0) {
        /* Flip one byte of the record so its checksum no longer
         * matches, WITHOUT touching anything else: the kernel must
         * report that loudly rather than serving the bytes. Filling the
         * whole record (poke, above) also breaks the mode/type, which
         * would be caught by something else -- this changes only the
         * checksum's validity. */
        cetrafs_inode_t rec;

        pread_all(fd, &rec, sizeof(rec), rec_off);
        rec.ns_checksum = cetrafs_cpu_to_le64(cetrafs_le64(rec.ns_checksum) ^ 0xFFFFFFFFu); /* v0x0005: break the ns sector CRC */
        pwrite_all(fd, &rec, sizeof(rec), rec_off);
        fprintf(stderr, "inode_block_poke: ino %llu record checksum invalidated\n", (unsigned long long) ino);
    } else if (strcmp(mode, "dirtytail") == 0) {
        /* Write garbage into the block PAST the record. A record write
         * must zero-fill that tail: v0x0007 gave each record its own
         * block, and a reader that ever looks past the struct (a later,
         * larger struct would) must not find a previous tenant's
         * bytes. */
        unsigned char *tail = malloc(cetrafs_le32(sb.block_size) - (size_t) CETRAFS_INODE_ONDISK_SIZE);

        if (!tail)
            return 1;
        memset(tail, 0x5A, cetrafs_le32(sb.block_size) - (size_t) CETRAFS_INODE_ONDISK_SIZE);
        pwrite_all(fd, tail, cetrafs_le32(sb.block_size) - (size_t) CETRAFS_INODE_ONDISK_SIZE, rec_off + (off_t) (size_t) CETRAFS_INODE_ONDISK_SIZE);
        free(tail);
        fprintf(stderr, "inode_block_poke: ino %llu block tail filled with 0x5A\n", (unsigned long long) ino);
    } else if (strcmp(mode, "tailzero") == 0) {
        /* "yes" if every byte past the record is zero. */
        unsigned char *tail = malloc(cetrafs_le32(sb.block_size) - (size_t) CETRAFS_INODE_ONDISK_SIZE);
        uint32_t i;
        int clean = 1;

        if (!tail)
            return 1;
        pread_all(fd, tail, cetrafs_le32(sb.block_size) - (size_t) CETRAFS_INODE_ONDISK_SIZE, rec_off + (off_t) (size_t) CETRAFS_INODE_ONDISK_SIZE);
        for (i = 0; i < cetrafs_le32(sb.block_size) - (size_t) CETRAFS_INODE_ONDISK_SIZE; i++)
            if (tail[i]) {
                clean = 0;
                break;
            }
        printf("%s\n", clean ? "yes" : "no");
        free(tail);
    } else {
        fprintf(stderr, "unknown mode '%s'\n", mode);
        return 2;
    }

    free(buf);
    close(fd);
    return 0;
}
