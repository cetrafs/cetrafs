/* SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary */
/*
 * growfs.cetra -- grow a cetrafs volume into space the device already
 * has (an enlarged LUN, or capacity a `mkfs.cetra -s` deliberately left
 * unformatted).
 *
 * Two modes, chosen by where it runs:
 *
 *  - LIVE, on a host that has the volume mounted. The tool writes the
 *    new Block Groups and their table segment past the current end,
 *    where nothing can reach them yet, then hands the new superblock to
 *    the kernel (CETRAFS_IOC_GROW). The kernel checks it, credits the
 *    unowned pool, links the segment and publishes the superblock by
 *    compare-and-swap (kmod/grow.c); every other node catches up
 *    through layout_gen. Every registered node must advertise live-grow
 *    support, or the grow is refused.
 *  - OFFLINE, when no node has it mounted: the tool writes everything
 *    itself, and refuses if any node is still heartbeating.
 *
 * Either way nothing that exists moves -- the new space is appended --
 * and the tool holds the volume's repair claim throughout, so no second
 * grower, repair or (offline) mount runs alongside it.
 *
 * Design, and why no format bump is needed:
 * docs/internal/EXTENDFS-DESIGN.md.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"
#include "devutil.h"

/* Exit codes match mkfs.cetra/fsck.cetra: 1 failure, 2 arguments,
 * 3 device inaccessible or in use. */
static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "growfs.cetra: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static void die_arg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "growfs.cetra: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(2);
}

static void die_dev(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "growfs.cetra: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(3);
}

static void *xcalloc(size_t n, size_t s)
{
    void *p = calloc(n, s);

    if (!p)
        die("out of memory");
    return p;
}

static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    const u8 *p = (const u8 *) buf;

    while (len) {
        ssize_t w = pwrite(fd, p, len, off);

        if (w < 0) {
            if (errno == EINTR)
                continue;
            die_dev("pwrite(off=%lld): %s", (long long) off, strerror(errno));
        }
        if (w == 0)
            die_dev("pwrite(off=%lld): short write", (long long) off);
        p += w;
        len -= (size_t) w;
        off += w;
    }
}

static void pread_all(int fd, void *buf, size_t len, off_t off)
{
    u8 *p = (u8 *) buf;

    while (len) {
        ssize_t r = pread(fd, p, len, off);

        if (r < 0) {
            if (errno == EINTR)
                continue;
            die_dev("pread(off=%lld): %s", (long long) off, strerror(errno));
        }
        if (r == 0)
            die_dev("pread(off=%lld): unexpected EOF", (long long) off);
        p += r;
        len -= (size_t) r;
        off += r;
    }
}

static void write_block(int fd, u64 lba, const void *data, bool do_write)
{
    if (!do_write)
        return;
    /* The claim's timer found our row taken, or a node beating under it
     * (devutil.h): writing on would relocate tables under a live mount. */
    if (cetrafs_repair_write_gate())
        die("%s -- stopping before writing more",
            cetrafs_repair_lost == 2   ? "a node is mounted on this volume while it is being grown"
            : cetrafs_repair_lost == 3 ? "this grow's registry claim was not renewed in time (a node may call it dead)"
                                       : "this grow's registry claim was taken away");
    pwrite_all(fd, data, CETRAFS_BLOCK_SIZE, (off_t) lba * CETRAFS_BLOCK_SIZE);
}

static void read_block(int fd, u64 lba, void *data)
{
    pread_all(fd, data, CETRAFS_BLOCK_SIZE, (off_t) lba * CETRAFS_BLOCK_SIZE);
}

static void zero_blocks(int fd, u64 start, u64 count, bool do_write)
{
    static u8 *z;

    if (!do_write)
        return;
    if (!z)
        z = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);
    for (u64 i = 0; i < count; ++i)
        write_block(fd, start + i, z, true);
}

static void sync_device(int fd, bool do_write)
{
    if (!do_write)
        return;
    if (fsync(fd) < 0)
        die_dev("fsync: %s", strerror(errno));
}

/* Block 0's copy (CETRAFS_SB_REPLICA_NR, A-7), after the primary is
 * published: the layout, never the needs-fsck status. A stop before it
 * leaves a stale copy that mount reports and fsck -r rewrites from
 * block 0 -- never a copy ahead of block 0. */
static void growfs_write_sb_copy(int fd, const cetrafs_superblock_t *sb)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_superblock_t s = *sb;

    if (cetrafs_test_env("CETRAFS_GROWFS_TEST_NO_SB_COPY")) {
        fprintf(stderr, "growfs.cetra: TEST MODE: leaving the copy of block 0 as it was\n");
        return;
    }
    s.fsck_needed_since = cetrafs_cpu_to_le64(0);
    s.fsck_needed_node = cetrafs_cpu_to_le32(0);
    s.fsck_needed_pad = cetrafs_cpu_to_le32(0);
    s.checksum = cetrafs_cpu_to_le64(
        crc32c_struct(&s, sizeof(s), offsetof(cetrafs_superblock_t, checksum), sizeof(s.checksum)));
    memset(blk, 0, sizeof(blk));
    memcpy(blk, &s, sizeof(s));
    write_block(fd, CETRAFS_SB_REPLICA_NR, blk, true);
    sync_device(fd, true);
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s <blockdev> [-s size] [-N inodes] [-n]\n"
            "  grows a cetrafs volume into space the device already has\n"
            "  -s: grow to this size instead of the whole device. Accepts a\n"
            "      K/M/G/T suffix; a bare number is MiB, like mkfs.cetra\n"
            "  -N: the inode count to grow to (default: what mkfs.cetra would\n"
            "      give a volume of the new size, if that is more)\n"
            "  -n: dry-run (compute & print, no writes)\n"
            "\n"
            "  Run it on a node that has the volume mounted to grow it live; every\n"
            "  node must run a build that supports live grow, and each node's device\n"
            "  must already show the new size (rescan the LUN on every node first).\n"
            "  With the volume unmounted on every node, it grows it offline.\n",
            argv0);
}

/* Same grammar as mkfs.cetra's -s, deliberately: the two options name
 * the same quantity and an operator will pass them the same strings. */
static u64 parse_size_bytes(const char *arg)
{
    char *end = NULL;
    unsigned long long v;
    u64 mult;

    errno = 0;
    v = strtoull(arg, &end, 10);
    if (errno || end == arg)
        die_arg("-s: not a number: %s", arg);

    switch (*end) {
    case '\0':
    case 'm':
    case 'M':
        mult = 1024ULL * 1024ULL;
        break;
    case 'k':
    case 'K':
        mult = 1024ULL;
        break;
    case 'g':
    case 'G':
        mult = 1024ULL * 1024ULL * 1024ULL;
        break;
    case 't':
    case 'T':
        mult = 1024ULL * 1024ULL * 1024ULL * 1024ULL;
        break;
    default:
        die_arg("-s: unknown suffix '%s' (use K, M, G or T)", end);
        return 0; /* unreachable */
    }
    if (*end && end[1] != '\0')
        die_arg("-s: trailing garbage after suffix: %s", arg);
    if (v == 0)
        die_arg("-s: zero");
    if (v > UINT64_MAX / mult)
        die_arg("-s: too large");
    return (u64) v * mult;
}

/* The Node Registry row this grow holds, so a node cannot mount the
 * volume while its tables are being relocated. -1 when nothing is held;
 * released by atexit() so every path, die() included, gives it back.
 * A missed release expires on its own -- it is a lease. */
static int grow_repair_row = -1;
static int grow_repair_fd = -1;
static cetrafs_superblock_t grow_repair_sb;

static void growfs_repair_release_atexit(void)
{
    if (grow_repair_row >= 0 && grow_repair_fd >= 0) {
        cetrafs_repair_release(grow_repair_fd, &grow_repair_sb, (uint32_t) grow_repair_row);
        grow_repair_row = -1;
    }
}

/*
 * Give the volume back while the descriptor is still open.
 *
 * The atexit backstop above runs after main() returns, by which time fd
 * is closed and its write silently does nothing. Every ordinary exit
 * from here goes through close(fd), so every one of them has to release
 * first -- the one that did not was the TEST_NO_PUBLISH path, and
 * growfs.sh caught it immediately: the claim stayed live and the kernel
 * then refused, correctly, to mount the half-grown volume. The backstop
 * is for die(), where fd is still open.
 */
static void growfs_release_claim(int fd)
{
    if (grow_repair_row >= 0 && fd >= 0) {
        cetrafs_repair_release(fd, &grow_repair_sb, (uint32_t) grow_repair_row);
        grow_repair_row = -1;
    }
}

/*
 * Refuse a volume a node has mounted: the device itself is asked, by
 * watching every registered row's heartbeat over a probe window.
 */
/*
 * The layout the superblock describes must hold, before growfs writes
 * anything: the data area holds every Block Group the superblock already
 * names, and no table lies inside it. The mount (cetrafs_validate_layout)
 * and fsck enforce the same. growfs writes Block Group headers and zeroed
 * bitmaps at the end of the data area before its publish, so a layout
 * that breaks these is one whose "new" groups land on live ones (audit
 * 2026-11-14 U3, tests/image/growfs_layout_before_writes.sh). The regions
 * are the ones the kernel lists; the tail reserve is not one of them.
 */
struct growfs_region {
    const char *name;
    u64 start, count;
};

static void growfs_check_layout(const char *dev, const cetrafs_superblock_t *sb, u64 total_blocks)
{
    struct growfs_region r[10];
    unsigned n = 0, i, j;
    const u64 zg_cnt = cetrafs_le32(sb->zone_group_count);
    const u64 bg_cnt = cetrafs_le32(sb->block_group_count);
    const u64 bg_size = cetrafs_le64(sb->bg_size_blocks);
    const u64 data_start = cetrafs_le64(sb->bg_regions_start);
    const u64 node_cnt = cetrafs_le32(sb->node_table_count);
    u64 span, data_end, first, count;

    if (bg_size > CETRAFS_MAX_BG_SIZE_BLOCKS)
        die("%s: Block Group size %llu blocks exceeds the format's limit -- run fsck.cetra first", dev,
            (unsigned long long) bg_size);
    if (bg_size && bg_cnt > UINT64_MAX / bg_size)
        die("%s: %llu Block Groups of %llu blocks overflow the layout -- run fsck.cetra first", dev,
            (unsigned long long) bg_cnt, (unsigned long long) bg_size);
    span = bg_cnt * bg_size;
    if (data_start > UINT64_MAX - span)
        die("%s: the data area at block %llu overflows -- run fsck.cetra first", dev, (unsigned long long) data_start);
    data_end = cetrafs_le64(sb->bg_data_end) ? cetrafs_le64(sb->bg_data_end) : data_start + span;
    if (data_end < data_start)
        die("%s: bg_data_end (%llu) precedes bg_regions_start (%llu) -- run fsck.cetra first", dev,
            (unsigned long long) data_end, (unsigned long long) data_start);
    /* The box holds its groups: a box shorter than them puts the next
     * group's header on top of the last one. */
    if (data_end - data_start < span)
        die("%s: the data area [%llu,%llu) cannot hold the %llu Block Groups the superblock names -- "
            "run fsck.cetra first",
            dev, (unsigned long long) data_start, (unsigned long long) data_end, (unsigned long long) bg_cnt);
    if (data_end > total_blocks)
        die("%s: the data area ends at block %llu, past the %llu blocks of the volume -- run fsck.cetra first", dev,
            (unsigned long long) data_end, (unsigned long long) total_blocks);

    first = cetrafs_le64(sb->bg_table_first_count);
    if (!first || first > bg_cnt)
        first = bg_cnt;
    r[n++] = (struct growfs_region) {"superblock and its copy", 0, CETRAFS_SB_AREA_BLOCKS};
    r[n++] = (struct growfs_region) {"zone group table", cetrafs_le64(sb->zg_table_start), zg_cnt};
    r[n++] = (struct growfs_region) {"block group table", cetrafs_le64(sb->bg_table_start), first};
    r[n++] = (struct growfs_region) {"inode bitmap", cetrafs_le64(sb->inode_bmap_start), cetrafs_le64(sb->inode_bmap_blocks)};
    r[n++] = (struct growfs_region) {"inode table", cetrafs_le64(sb->inode_table_start), cetrafs_le64(sb->inode_table_blocks)};
    r[n++] = (struct growfs_region) {"node registry", cetrafs_le64(sb->node_table_start), cetrafs_le64(sb->node_table_blocks)};
    count = zg_cnt * cetrafs_le32(sb->pending_free_blocks_per_zg);
    r[n++] = (struct growfs_region) {"pending-free queues", cetrafs_le64(sb->pending_free_start), count};
    count = node_cnt * cetrafs_le32(sb->node_journal_blocks);
    r[n++] = (struct growfs_region) {"per-node journals", cetrafs_le64(sb->node_journal_start), count};
    r[n++] = (struct growfs_region) {"block group regions", data_start, data_end - data_start};

    for (i = 0; i < n;) {
        if (r[i].count == 0) {
            r[i] = r[--n];
            continue;
        }
        if (r[i].start == 0 && i != 0)
            die("%s: %s starts at block 0 (the superblock) -- run fsck.cetra first", dev, r[i].name);
        if (r[i].count > total_blocks || r[i].start > total_blocks - r[i].count)
            die("%s: %s [%llu,+%llu) does not fit in the %llu blocks of the volume -- run fsck.cetra first", dev,
                r[i].name, (unsigned long long) r[i].start, (unsigned long long) r[i].count,
                (unsigned long long) total_blocks);
        i++;
    }
    /* Insertion sort by start: a dozen entries, and the overlap test is
     * then one linear pass. */
    for (i = 1; i < n; i++) {
        struct growfs_region key = r[i];

        for (j = i; j > 0 && r[j - 1].start > key.start; j--)
            r[j] = r[j - 1];
        r[j] = key;
    }
    for (i = 1; i < n; i++)
        if (r[i].start < r[i - 1].start + r[i - 1].count)
            die("%s: %s [%llu,+%llu) overlaps %s [%llu,+%llu) -- run fsck.cetra first", dev, r[i].name,
                (unsigned long long) r[i].start, (unsigned long long) r[i].count, r[i - 1].name,
                (unsigned long long) r[i - 1].start, (unsigned long long) r[i - 1].count);
}

static void growfs_refuse_live_peer(const char *dev)
{
    char label[CETRAFS_NODE_LABEL_LEN + 1] = {0};
    long long age = 0;
    uint32_t row = 0;
    int lp = cetrafs_find_live_peer(dev, &row, label, sizeof(label), &age);

    if (lp < 0)
        die_dev(
            "%s: cannot read its Node Registry (I/O error) -- so it is impossible to prove\n"
            "       no other node has this volume mounted, and growing a volume out from\n"
            "       under a running node relocates the tables it is still writing to.\n"
            "       Fix the device and retry.",
            dev);
    if (lp)
        die_dev(
            "%s is mounted by another node (registry row %u%s%s) -- it is still heartbeating.\n"
            "       Run growfs.cetra on a node that has the volume mounted to grow it live,\n"
            "       or unmount it on every node to grow it offline. (row's own last_seen\n"
            "       reads %llds ago by this machine's clock, which means nothing if the two\n"
            "       disagree.)",
            dev, row, label[0] ? ", " : "", label[0] ? label : "", age);
}

/*
 * Link a new segment from the TAIL of a table chain -- one record, which
 * is what the live path swaps -- for a table's second and later grows.
 *
 * The tail is the segment the SUPERBLOCK's count ends in, found by
 * counting entries, never "the one whose next is 0". The link reaches
 * the device before the publish, so a grow that died in between left
 * the tail pointing at a segment the old superblock does not count --
 * and a retry, which computes the same segment address, rewrote that
 * segment with next=0, walked to it as the tail and linked it to ITSELF.
 * Counting stops at the real tail and overwrites the stale link instead.
 * Bounded: a chain that does not reach old_count is corruption, and
 * looping while holding a volume open is worse than refusing.
 */
static void growfs_link_tail(int fd, const char *dev, u8 *blk, u64 cur, u64 filled, u64 old_count, u32 magic,
                             const char *what, u64 new_lba)
{
    u64 guard = 0;

    if (!filled || filled > old_count)
        die("%s: the %s table's first segment holds %" PRIu64 " of %" PRIu64, dev, what, filled, old_count);
    for (;;) {
        cetrafs_seg_hdr_t seg;

        if (!cur || ++guard > old_count + 2)
            die("%s: the %s table chain does not reach entry %" PRIu64, dev, what, old_count);
        read_block(fd, cur, blk);
        memcpy(&seg, blk, sizeof(seg));
        if (cetrafs_le32(seg.magic) != magic)
            die("%s: %s table segment at %" PRIu64 " has no magic", dev, what, cur);
        /* Verified before it is restamped: a restamp would make a
         * damaged header valid (audit L14). */
        if ((u32) cetrafs_le64(seg.checksum) !=
            crc32c_struct(&seg, sizeof(seg), offsetof(cetrafs_seg_hdr_t, checksum), sizeof(seg.checksum)))
            die("%s: %s table segment at %" PRIu64 " fails its checksum -- run fsck", dev, what, cur);
        if (cetrafs_le32(seg.first_id) != filled || cetrafs_le32(seg.count) > old_count - filled)
            die("%s: %s table segment at %" PRIu64 " does not continue the chain", dev, what, cur);
        filled += cetrafs_le32(seg.count);
        if (filled == old_count) {
            if (cetrafs_le64(seg.next) != 0)
                fprintf(stderr, "growfs.cetra: replacing the link an interrupted grow left at block %" PRIu64 "\n",
                        cur);
            seg.next = cetrafs_cpu_to_le64(new_lba);
            seg.checksum = cetrafs_cpu_to_le64(0);
            seg.checksum = cetrafs_cpu_to_le64(
                (u64) crc32c_struct(&seg, sizeof(seg), offsetof(cetrafs_seg_hdr_t, checksum), sizeof(seg.checksum)));
            memcpy(blk, &seg, sizeof(seg));
            write_block(fd, cur, blk, true);
            sync_device(fd, true);
            return;
        }
        cur = cetrafs_le64(seg.next);
    }
}

int main(int argc, char **argv)
{
    int grow_rc = 0; /* a Zone Group row left unstamped after the publish (audit L14) */

    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    const char *dev = argv[1];
    bool dry_run = false;

    if (dev[0] == '-')
        die_arg("the device comes first: %s <device> [options] (got '%s' where the device goes)", argv[0], dev);
    u64 want_bytes = 0, want_inodes = 0;
    int opt;

    while ((opt = getopt(argc - 1, argv + 1, "s:N:n")) != -1) {
        switch (opt) {
        case 'N': {
            char *end = NULL;
            unsigned long long v;

            errno = 0;
            v = strtoull(optarg, &end, 10);
            if (errno || !end || *end || !v || v >= UINT32_MAX)
                die_arg("-N wants an inode count between 1 and %u", UINT32_MAX - 1);
            want_inodes = v;
            break;
        }
        case 's':
            want_bytes = parse_size_bytes(optarg);
            if (want_bytes % CETRAFS_BLOCK_SIZE)
                die_arg("-s must be a multiple of 4KiB");
            break;
        case 'n':
            dry_run = true;
            break;
        default:
            usage(argv[0]);
            return 2;
        }
    }
    /* "growfs.cetra /dev/x 3T" grew to the whole device and dropped the
     * 3T -- irreversibly (M-35, BM-62). The size is -s. */
    if (optind < argc - 1)
        die_arg("unexpected argument '%s' (a size is given with -s)", argv[1 + optind]);

    /*
     * The offline premise, enforced before anything is read for a
     * decision. Both halves are needed and neither subsumes the other:
     * the first sees only THIS system's mount table, the second asks the
     * device itself about peers. Checked even in dry-run -- a dry-run
     * that printed a plan derived from a live cluster's moving geometry
     * would be worse than no plan.
     */
    /*
     * LIVE when this host has the volume mounted: the grow is then
     * published by the kernel (CETRAFS_IOC_GROW on the mount), which
     * compare-and-swaps what the mounted nodes also swap and catches
     * every node up through layout_gen. Peers being mounted is then
     * expected rather than refused -- but only a host that has it
     * mounted can grow it live: from anywhere else there is no kernel
     * to publish through, and a plain write would race the nodes.
     */
    char live_where[4096] = {0};
    const bool live = cetrafs_device_mounted(dev, live_where, sizeof(live_where)) != 0;

    if (live)
        printf("cetrafs growfs: %s is mounted on %s -- growing it live\n", dev, live_where);
    /* The device-side half: a dry run asks now (it claims nothing);
     * a real grow asks once its claim is down, below -- asked before
     * the claim, a node that mounted in between passed every check of
     * its own (there was no claim yet) and was never looked for again. */
    if (dry_run && !live)
        growfs_refuse_live_peer(dev);

    int fd = open(dev, dry_run ? (O_RDONLY | O_CLOEXEC) : (O_RDWR | O_CLOEXEC));

    if (fd < 0)
        die_dev("open(%s): %s", dev, strerror(errno));

    /* The knobs that leave the volume damaged on purpose are refused
     * here, before anything is written, on anything but a test device. */
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_SKIP_BG_HEADERS", fd);
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_CLOBBER_PENDING", fd);
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_CLOBBER_JOURNAL", fd);
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_NO_AGGREGATE", fd);
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_BG_OFFSET", fd);
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_DESC_SHIFT", fd);
    (void) cetrafs_test_env_damaging("CETRAFS_GROWFS_TEST_KEEP_DEAD_CREDIT", fd);

    unsigned long long dev_bytes = 0ULL;

    if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0)
        die_dev("BLKGETSIZE64: %s", strerror(errno));

    u64 dev_blocks = dev_bytes / CETRAFS_BLOCK_SIZE;
    u64 target_blocks = dev_blocks;

    if (want_bytes) {
        if (want_bytes > dev_bytes)
            die_arg("-s %llu bytes exceeds the device (%llu bytes)", (unsigned long long) want_bytes, dev_bytes);
        target_blocks = want_bytes / CETRAFS_BLOCK_SIZE;
    }

    /* ---- read and validate the existing superblock ---- */
    cetrafs_superblock_t sb;
    u8 *blk = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);

    read_block(fd, CETRAFS_SB_BLOCK_NR, blk);
    memcpy(&sb, blk, sizeof(sb));

    if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC)
        die("%s: not a cetrafs volume (magic 0x%08X)", dev, cetrafs_le32(sb.magic));
    if (cetrafs_le16(sb.version) < CETRAFS_VERSION_MIN || cetrafs_le16(sb.version) > CETRAFS_VERSION)
        die("%s: format version 0x%04X, this build accepts 0x%04X..0x%04X", dev, cetrafs_le16(sb.version),
            CETRAFS_VERSION_MIN, CETRAFS_VERSION);
    /* A grow rewrites the layout, and a structure it does not know --
     * even a compatible one -- is one it would grow past or over
     * (cetrafs.h, the feature rules). Before anything is written. */
    if ((cetrafs_le64(sb.features_incompat) & ~CETRAFS_FEAT_INCOMPAT_SUPP) ||
        (cetrafs_le64(sb.features_ro_compat) & ~CETRAFS_FEAT_RO_COMPAT_SUPP) ||
        (cetrafs_le64(sb.features_compat) & ~CETRAFS_FEAT_COMPAT_SUPP))
        die("%s: feature bits this growfs does not know are set (compat 0x%" PRIx64 ", ro_compat 0x%" PRIx64
            ", incompat 0x%" PRIx64 ") -- use the growfs.cetra of the build that set them",
            dev, (uint64_t) cetrafs_le64(sb.features_compat), (uint64_t) cetrafs_le64(sb.features_ro_compat),
            (uint64_t) cetrafs_le64(sb.features_incompat));
    if (cetrafs_le32(sb.block_size) != CETRAFS_BLOCK_SIZE)
        die("%s: block size %u != %u", dev, cetrafs_le32(sb.block_size), CETRAFS_BLOCK_SIZE);
    {
        u64 stored = cetrafs_le64(sb.checksum);
        u32 calc;

        sb.checksum = cetrafs_cpu_to_le64(0);
        calc = crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum));
        sb.checksum = cetrafs_cpu_to_le64(stored);
        if ((u32) stored != calc)
            die("%s: superblock CRC32C mismatch (stored 0x%08X, computed 0x%08X) -- run fsck.cetra first", dev,
                (u32) stored, calc);
    }

    /* The geometry every computation below divides or multiplies by.
     * The CRC only proves the superblock is the one written; the mount
     * refuses these values (fs.c), and growing a volume the kernel will
     * not mount used to "complete" -- with a modulo by zero further
     * down for some of them. Same limits as the mount path. */
    if (!cetrafs_le32(sb.zone_group_count) || cetrafs_le32(sb.zone_group_count) > CETRAFS_MAX_ZONE_GROUPS)
        die("%s: invalid zone_group_count %u -- run fsck.cetra first", dev, cetrafs_le32(sb.zone_group_count));
    if (!cetrafs_le32(sb.block_group_count))
        die("%s: invalid block_group_count 0 -- run fsck.cetra first", dev);
    if (cetrafs_le64(sb.bg_size_blocks) < 64)
        die("%s: invalid bg_size_blocks %" PRIu64 " -- run fsck.cetra first", dev,
            (u64) cetrafs_le64(sb.bg_size_blocks));
    /* It places every group this grow adds. */
    if (!cetrafs_data_align_ok(cetrafs_le32(sb.data_align_blocks), cetrafs_le64(sb.bg_size_blocks)))
        die("%s: invalid data_align_blocks %u -- run fsck.cetra first", dev, cetrafs_le32(sb.data_align_blocks));
    /* It sizes the journal reservation this grow moves past. */
    if (!cetrafs_journal_blocks_ok(cetrafs_le32(sb.node_journal_blocks)))
        die("%s: invalid node_journal_blocks %u -- run fsck.cetra first", dev, cetrafs_le32(sb.node_journal_blocks));

    const u64 old_total = cetrafs_le64(sb.total_blocks);
    const u32 old_z = cetrafs_le32(sb.zone_group_count);
    const u32 old_b = cetrafs_le32(sb.block_group_count);
    const u64 bg_size = cetrafs_le64(sb.bg_size_blocks);
    const u64 regions_start = cetrafs_le64(sb.bg_regions_start);
    const u64 align = cetrafs_le32(sb.data_align_blocks);

    if (old_total > dev_blocks)
        die("%s: superblock claims %" PRIu64 " blocks but the device has %" PRIu64
            " -- the device SHRANK;\n"
            "       this tool only grows, and formatting is the only way back",
            dev, old_total, dev_blocks);

    if (target_blocks <= old_total) {
        fprintf(stdout,
                "cetrafs growfs: nothing to do\n"
                "  filesystem: %" PRIu64
                " blocks (%llu bytes)\n"
                "  target:     %" PRIu64 " blocks (%llu bytes)\n",
                old_total, (unsigned long long) old_total * CETRAFS_BLOCK_SIZE, target_blocks,
                (unsigned long long) target_blocks * CETRAFS_BLOCK_SIZE);
        close(fd);
        return 0;
    }

    /* Before any write below: the layout the new groups are carved from
     * must be one the mount accepts (audit 2026-11-14 U3). */
    growfs_check_layout(dev, &sb, old_total);

    /*
     * ---- geometry ----
     *
     * New BG regions begin exactly where the old volume's trailing
     * rounding waste began -- immediately after the last old BG -- so
     * the BG regions stay ONE contiguous span. That contiguity is not
     * cosmetic: cetrafs_validate_layout() (kernel and fsck both) models
     * the regions as bg_cnt * bg_size_blocks from bg_regions_start, and
     * anything placed inside that computed span reads as an overlap at
     * every mount. It is also why the relocated tables go at the very
     * END, after the new BGs, and never in the gap.
     */
    /*
     * Where the new Block Groups start.
     *
     * On a never-grown volume that is simply after the last BG -- which
     * is exactly where the old trailing rounding waste began, so the
     * data area stays contiguous.
     *
     * On an ALREADY-GROWN volume it is after the superseded tail
     * reserve, because that reserve still holds the tables this grow is
     * about to read, and writing new BG headers over them in step 1 --
     * before the publish -- would destroy the old filesystem and the
     * new one together. Skipping it leaves a HOLE in the data area,
     * which is what bg_data_end exists to describe (cetrafs.h). The
     * "hole" is the previous segment, still in use: nothing is orphaned.
     */
    const u64 old_data_end = cetrafs_le64(sb.bg_data_end) ? cetrafs_le64(sb.bg_data_end)
                                                          : regions_start + (u64) old_b * bg_size;
    const u64 old_reserve_start = cetrafs_le64(sb.tail_reserve_start);
    const u64 old_reserve_blocks = cetrafs_le64(sb.tail_reserve_blocks);

    u64 new_bg_start = old_data_end;

    if (old_reserve_blocks && old_reserve_start + old_reserve_blocks > new_bg_start)
        new_bg_start = old_reserve_start + old_reserve_blocks;
    /* On the volume's data alignment, as mkfs placed the first group
     * (cetrafs_superblock_t.data_align_blocks): the skip widens the hole
     * bg_data_end already allows for. A never-grown volume's groups end
     * on it already. */
    new_bg_start = (new_bg_start + align - 1) / align * align;

    /*
     * TEST-ONLY. Shifts the new BG regions by this many BGs, to place
     * them deliberately on top of the old ones.
     *
     * It exists because the assertion that matters most in the grow test
     * -- "the pre-existing files still verify after the new space has
     * been written" -- passes trivially against correct code and would
     * also pass against code with no bug to find. This is how the test
     * proves it discriminates: with the offset set, the originals MUST
     * come back corrupted. An assertion whose discriminating power has
     * not been measured is a guess (tests/README.md).
     *
     * Deliberately an environment variable and not an option: nothing an
     * operator can reach by misreading the usage text.
     */
    {
        const long long off = cetrafs_test_env_ll("CETRAFS_GROWFS_TEST_BG_OFFSET", -65536, 65536, 0);

        if (off) {
            fprintf(stderr, "growfs.cetra: TEST MODE: shifting new BG regions by %lld BG(s)\n", off);
            if (off < 0 && (u64) (-off) * bg_size > new_bg_start)
                die("test offset puts the new regions before block 0");
            new_bg_start = (u64) ((long long) new_bg_start + off * (long long) bg_size);
        }
    }

    if (new_bg_start > target_blocks)
        die("%s: the existing layout already ends past the target size", dev);

    /*
     * The reserve and the BG count are mutually dependent -- more BGs
     * need a bigger BG table, which leaves less room for BGs. Solve it
     * the way mkfs does: iterate to a fixed point. It converges
     * downward in a couple of rounds and is bounded by the loop count.
     */
    /*
     * The inode table grows with the volume (audit 2026-11-15 M-36): to
     * what mkfs would give a volume of the new size, or to -N. Its new
     * segment -- header, bitmap, records -- follows the Block Group
     * segment in the same reserve.
     */
    const u32 old_inodes = cetrafs_le32(sb.inodes_count);
    u64 new_inodes = want_inodes ? want_inodes : cetrafs_default_inodes_for_bytes(target_blocks * CETRAFS_BLOCK_SIZE);

    if (want_inodes && want_inodes < old_inodes)
        die_arg("-N %" PRIu64 " is fewer than the %u inodes the volume has -- an inode table only grows",
                want_inodes, old_inodes);
    if (new_inodes < old_inodes)
        new_inodes = old_inodes;
    const u64 ino_add = new_inodes - old_inodes;
    const u64 ino_span = ino_add ? 1 + cetrafs_calc_inode_bmap_blocks(ino_add) + ino_add : 0;

    u64 new_b = old_b;
    u64 reserve_blocks = 0;
    u64 tail_waste = 0;

    for (int pass = 0; pass < 8; pass++) {
        u64 avail = target_blocks - new_bg_start;
        u64 added;

        if (avail <= reserve_blocks)
            die("%s: the added space (%" PRIu64 " blocks) cannot even hold the relocated tables (%" PRIu64
                " blocks) -- grow by more",
                dev, avail, reserve_blocks);

        added = (avail - reserve_blocks) / bg_size;
        if (added == 0)
            die("%s: the added space is smaller than one Block Group (%" PRIu64 " blocks, %llu MiB)", dev, bg_size,
                (unsigned long long) (bg_size * CETRAFS_BLOCK_SIZE / 1024 / 1024));

        u64 cand_b = (u64) old_b + added;

        if (cand_b > CETRAFS_MAX_BLOCK_GROUPS)
            die("%s: %" PRIu64 " Block Groups exceed the %u a volume may have (the mount refuses more)", dev, cand_b,
                CETRAFS_MAX_BLOCK_GROUPS);

        /*
         * Zone Group policy: keep roughly the BGs-per-ZG ratio the
         * volume was formatted with, so new capacity is spread over new
         * ZGs that separate nodes can claim. Giving it all to existing
         * ZGs is not an option anyway -- first_bg_id/bg_count is a
         * CONTIGUOUS span, so only the last ZG could absorb new BGs, and
         * that would hand the entire added capacity to whichever single
         * node owns it.
         */
        /*
         * The Zone Group count does NOT change. Growing used to add
         * Zone Groups so the new Block Groups had somewhere to live,
         * because a Zone Group owned a contiguous range and could not
         * absorb ids that were not adjacent to it. Now a Block Group
         * names its own owner, so the added ones are spread across the
         * Zone Groups that already exist -- which reaches every node
         * immediately instead of handing the new capacity to whoever
         * claims the new groups. docs/internal/BG-OWNERSHIP-DESIGN.md
         *
         * This also means the ZG table and the pending-free region do
         * not grow, so only the Block Group table has to be relocated.
         */
        /*
         * The tail reserve now holds ONE THING: the appended Block
         * Group table segment -- its header plus a descriptor per added
         * Block Group.
         *
         * It used to hold relocated copies of the Zone Group table, the
         * whole Block Group table and the pending-free region. None of
         * that has to move any more. The Zone Group count is invariant
         * across a grow (stage 2), so the Zone Group table and the
         * pending-free region -- which is indexed by Zone Group -- can
         * never grow; copying them was pure waste, and the pending-free
         * copy was most of the orphaned space. The Block Group table
         * does grow, but it grows by APPENDING a segment and linking it
         * (stage 5), not by being rewritten somewhere else.
         *
         * So a grow moves nothing. That is the whole point: a mounted
         * peer caches these addresses and reads them with no lock, and
         * what never changes cannot be read stale.
         */
        u64 need = 1 /* segment header */ + (cand_b - old_b) /* added descriptors */ + ino_span;

        if (need == reserve_blocks && cand_b == new_b)
            break;

        reserve_blocks = need;
        new_b = cand_b;
    }

    const u64 reserve_start = new_bg_start + (new_b - old_b) * bg_size;
    const u64 new_data_end = reserve_start; /* the box ends where the new BGs do */

    if (reserve_start + reserve_blocks > target_blocks)
        die("internal: tail reserve [%" PRIu64 ",+%" PRIu64 ") past target %" PRIu64, reserve_start, reserve_blocks,
            target_blocks);

    tail_waste = target_blocks - (reserve_start + reserve_blocks);

    /*
     * What this grow strands: nothing. The tail reserve holds only the
     * appended Block Group table segment, which stays linked and in use,
     * and no table moves (stage 5 below) -- so a later grow that starts
     * its Block Groups past the previous reserve skips a region that is
     * still the previous segment, not one left behind. This used to add
     * the prefix tables on a first grow, from when they were relocated,
     * and persist the sum into the superblock (audit 2026-11-11 G1).
     */
    const u64 orphan_total = cetrafs_le64(sb.orphan_blocks);

    u32 off_bmap32, off_data32;
    u64 data_cnt;

    cetrafs_calc_bg_layout(bg_size, align, &off_bmap32, &off_data32, &data_cnt);

    fprintf(stdout,
            "cetrafs growfs %s\n"
            "  device:      %llu bytes (%" PRIu64
            " blocks)\n"
            "  filesystem:  %" PRIu64 " -> %" PRIu64
            " blocks\n"
            "  Block Groups: %u -> %" PRIu64 " (+%" PRIu64
            ", %llu MiB each)\n"
            "  Zone Groups:  %u -> %u (a grow adds none)\n"
            "  new BG regions: LBA %" PRIu64 " .. %" PRIu64
            "\n"
            "  tail reserve:   LBA %" PRIu64 "+%" PRIu64
            " (the appended table segments)\n"
            "  inodes:       %u -> %" PRIu64
            "\n"
            "  unused tail:    %" PRIu64
            " blocks (rounding)\n",
            dry_run ? "(DRY-RUN)" : "plan", dev_bytes, dev_blocks, old_total, target_blocks, old_b, new_b,
            new_b - old_b, (unsigned long long) (bg_size * CETRAFS_BLOCK_SIZE / 1024 / 1024), old_z, old_z,
            new_bg_start, reserve_start - 1, reserve_start, reserve_blocks, old_inodes, new_inodes,
            tail_waste);

    /*
     * Growing is a ONE-WAY DOOR for the whole cluster, so say so once
     * the plan above is known viable -- and say it with evidence rather
     * than as boilerplate.
     *
     * A grown volume is stamped CETRAFS_VERSION. Builds that predate
     * the grow feature REFUSE it: their fsck wants pending_free_start
     * immediately after the node table and their module wants
     * bg_regions_start >= 1+Z+B, neither of which a relocated layout
     * satisfies. That refusal is deliberate -- without it an old build
     * would call a healthy grown volume damaged and invite `fsck -r` on
     * it -- but it means every node that mounts this volume again needs
     * a module from this release or newer.
     *
     * Two things are checkable here, and both beat a generic warning:
     *
     *   - the Node Registry records, per node, the capabilities its
     *     module advertised at registration. A row reading 0 was
     *     written by a build that predates them, i.e. one that cannot
     *     mount what this is about to produce. That is on-disk evidence
     *     about PEERS, written by the peers themselves.
     *   - this machine's own loaded module, via /sys/module.
     */
    {
        char labels[64][CETRAFS_NODE_LABEL_LEN + 1];
        uint32_t caps[64], rows[64];
        int n = cetrafs_scan_node_caps(dev, labels, caps, rows, 64);
        int stale_nodes = 0;

        fprintf(stdout,
                "\ncetrafs growfs: NOTICE -- growing stamps this volume format 0x%04X.\n"
                "  Every node that mounts it afterwards needs a cetrafs module from this\n"
                "  release or newer. Older modules REFUSE a grown volume by design: they\n"
                "  would otherwise report it as damaged and invite a repair.\n",
                CETRAFS_VERSION);

        if (n < 0) {
            fprintf(stdout, "  Could not read the Node Registry, so peer readiness is UNKNOWN.\n");
        } else if (n == 0) {
            fprintf(stdout, "  No node has ever registered on this volume.\n");
        } else {
            int i;

            fprintf(stdout, "  Nodes registered on this volume:\n");
            for (i = 0; i < n; i++) {
                int ok = (caps[i] & CETRAFS_NODE_CAP_LIVE_GROW) != 0;

                if (!ok)
                    stale_nodes++;
                fprintf(stdout, "    row %-3u %-24s %s\n", rows[i], labels[i][0] ? labels[i] : "(no label)",
                        ok ? "ready (module understands a grown layout)"
                           : "** NOT READY -- module predates grow; it will refuse this volume **");
            }
        }
        {
            FILE *vf = fopen("/sys/module/cetrafs/version", "r");
            char ver[128];

            if (vf && fgets(ver, sizeof(ver), vf)) {
                ver[strcspn(ver, "\n")] = 0;
                fprintf(stdout, "  This machine's loaded module: %s\n", ver);
            } else {
                fprintf(stdout, "  This machine has no cetrafs module loaded; its readiness is UNKNOWN.\n");
            }
            if (vf)
                fclose(vf);
        }
        if (stale_nodes)
            fprintf(stdout,
                    "  %d registered node(s) above will NOT mount this volume after the grow\n"
                    "  until their module is upgraded.\n",
                    stale_nodes);
        fprintf(stdout, "\n");
    }

    if (dry_run) {
        growfs_release_claim(fd);
        close(fd);
        return 0;
    }

    /*
     * Claim the volume before STEP 1 writes anything.
     *
     * The live-peer check above refuses to grow a volume a node has
     * MOUNTED. Nothing covered the other direction: a node mounting
     * while this runs caches descriptor tables that are being
     * relocated under it. The claim is a Node Registry row in
     * CETRAFS_NODE_STATE_REPAIR -- the same lease `fsck -r` takes, and
     * the same one fill_super() refuses to mount past.
     */
    if (!dry_run) {
        uint32_t other_row = 0;
        char other[CETRAFS_NODE_LABEL_LEN + 1] = {0};
        int busy = cetrafs_find_repair_claim(fd, &sb, &other_row, other, sizeof(other));

        if (busy < 0)
            die_dev("%s: cannot read its Node Registry -- refusing to grow blind", dev);
        if (busy)
            die_dev("%s is being repaired right now (registry row %u%s%s) -- wait for it to finish", dev, other_row,
                    other[0] ? ", " : "", other[0] ? other : "");

        cetrafs_repair_peers_expected = live; /* before the claim arms its timer */
        grow_repair_row = cetrafs_repair_claim(fd, &sb, "growfs");
        if (grow_repair_row == -2)
            die_dev("%s: another repair or grow claimed this volume at the same time -- stopping", dev);
        if (grow_repair_row == -3)
            die_dev("%s: the superblock changed while this grow claimed the volume -- run it again", dev);
        if (grow_repair_row < 0)
            die_dev("%s: no free Node Registry row to claim for the grow -- refusing to write while a node could "
                    "still mount it",
                    dev);
        grow_repair_fd = fd;
        grow_repair_sb = sb;
        atexit(growfs_repair_release_atexit);
        printf("  claimed registry row %d for the duration of this grow\n", grow_repair_row);
        fflush(stdout);
        /* Test knob only, as in fsck: hold the claim before any work, so
         * a suite can act on the volume while it is held. */
        cetrafs_test_hold("CETRAFS_TEST_REPAIR_HOLD_SECS");
        /* Claim first, then look: a node mounting from here on sees the
         * claim and refuses, and one that got in before it is found
         * here. The other order left the gap between them open. A live
         * grow expects mounted nodes; what the claim buys it is that no
         * other grower or repairer works on the volume meanwhile. */
        if (!live)
            growfs_refuse_live_peer(dev);
    }

    /* ---------------------------------------------------------------
     * STEP 1: the new BG regions -- header + zeroed bitmap each.
     *
     * Rule 5/8: a block must be VALID before anything can reach it, and
     * nothing may become durable before what it refers to. These regions
     * become reachable the instant the superblock is published, so they
     * are on the platter first, and fsync'd before the tables that name
     * them are written.
     * --------------------------------------------------------------- */
    /* TEST-ONLY: leave the new Block Groups' headers and bitmaps unwritten.
     * A grow that publishes over them is what the crash rig must catch. */
    const bool skip_bg_hdr = cetrafs_test_env("CETRAFS_GROWFS_TEST_SKIP_BG_HEADERS");
    /* TEST-ONLY: the new bitmaps are left full of 1s, as an earlier
     * filesystem's would be; the kernel must refuse the grow. */
    const bool dirty_bmp = cetrafs_test_env("CETRAFS_GROWFS_TEST_DIRTY_BG_BITMAPS");

    {
        u64 start = new_bg_start;

        for (u64 b = old_b; b < new_b; ++b) {
            cetrafs_bg_header_t bh;

            memset(&bh, 0, sizeof(bh));
            bh.bg_id = cetrafs_cpu_to_le32((u32) b);
            bh.length_blocks = cetrafs_cpu_to_le64(bg_size);
            bh.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
            bh.off_data_region = cetrafs_cpu_to_le32(off_data32);
            bh.data_block_count = cetrafs_cpu_to_le64(data_cnt);
            bh.checksum = cetrafs_cpu_to_le64(0);
            bh.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bh, sizeof(bh), offsetof(cetrafs_bg_header_t, checksum),
                                                            sizeof(cetrafs_le64(bh.checksum))));

            memcpy(blk, &bh, sizeof(bh));
            write_block(fd, start, blk, !skip_bg_hdr);

            /* A stale bitmap from a previous filesystem at these offsets
             * would read as "allocated" and silently cost the volume the
             * space, so these are really zeroed, not assumed zero. */
            if (dirty_bmp) {
                /* TEST-ONLY: a bitmap a previous filesystem left behind. */
                memset(blk, 0xff, CETRAFS_BLOCK_SIZE);
                for (u64 k = 0; k < cetrafs_calc_bg_dbm_blocks(bg_size); ++k)
                    write_block(fd, start + off_bmap32 + k, blk, !skip_bg_hdr);
            } else {
                zero_blocks(fd, start + off_bmap32, cetrafs_calc_bg_dbm_blocks(bg_size), !skip_bg_hdr);
            }
            start += bg_size;
        }
    }
    sync_device(fd, true);

    /* ---------------------------------------------------------------
     * STEP 2: the relocated tables, in the tail reserve.
     * --------------------------------------------------------------- */
    /* The appended segment: its header, then one descriptor per added
     * Block Group. The Zone Group table and the pending-free region
     * stay exactly where mkfs put them. */
    const u64 seg_header_lba = reserve_start;
    const u64 seg_first_desc = seg_header_lba + 1;

    /* Which ZG owns which BG. Existing BGs keep their existing ZG --
     * nothing about the old half of the volume moves. New BGs are spread
     * over the new ZGs, and if the 255-ZG cap stopped new ZGs from being
     * created at all, over the last existing one. */
    /*
     * Who owns each Block Group.
     *
     * Existing ones keep their owner in their own record, untouched -- a
     * Zone Group no longer carries a member list. New ones
     * are spread ROUND-ROBIN across every existing Zone Group, which is
     * what makes grown capacity reach every node at once instead of
     * landing on whichever one happens to own the tail. No Zone Group
     * record is rewritten at all: the only thing that changes is each
     * one's free-space aggregate.
     * docs/internal/BG-OWNERSHIP-DESIGN.md
     */
    u32 *bg_owner = (u32 *) xcalloc(new_b, sizeof(u32));
    u64 *zg_added = (u64 *) xcalloc(old_z, sizeof(u64));

    /* Only the NEW Block Groups' owners are decided or used here. The
     * existing ones are never read: on a grown volume their descriptors
     * are not at bg_table_start + b, and a loop that read them there
     * fetched the wrong blocks into a result nothing used (audit
     * 2026-11-06 L26). */
    /* A live grow puts every new Block Group in the unowned POOL, and
     * the kernel credits the pool shards when it publishes: a Zone
     * Group's free aggregate is accrued in memory by whichever node
     * owns it, so this tool must not write it under a mounted node.
     * The capacity reaches nodes through the ordinary claim path. */
    for (u32 b = old_b; b < new_b; ++b) {
        if (live) {
            bg_owner[b] = CETRAFS_BG_OWNER_FREE;
            continue;
        }
        bg_owner[b] = cetrafs_sb_zg_shard(&sb, b);
        /* TEST-ONLY: fold every new Block Group onto the last Zone Group,
         * the behaviour the 255-ZG branch used to have. The spread check
         * in tests/kernel/growfs_zg_cap.sh must see it. */
        if (cetrafs_test_env("CETRAFS_GROWFS_TEST_FOLD_LAST"))
            bg_owner[b] = old_z - 1;
        zg_added[bg_owner[b]]++;
    }

    /* BG table: existing descriptors copied VERBATIM -- their free
     * counts, reconcile epochs and owner_zg are live state this tool has
     * no business recomputing -- new ones appended. */
    /* The existing descriptors are NOT copied anywhere. They stay where
     * they are, which is what makes this safe to do under a running
     * peer: nothing it has cached moves. Only the new ones are written,
     * into the appended segment. */
    {
        u64 start = new_bg_start;

        for (u64 b = old_b; b < new_b; ++b) {
            cetrafs_block_group_t bg;

            memset(&bg, 0, sizeof(bg));
            bg.bg_id = cetrafs_cpu_to_le32((u32) b);
            bg.owner_zg = cetrafs_cpu_to_le16((u16) bg_owner[b]);
            /*
             * TEST-ONLY, and a different instrument from
             * CETRAFS_GROWFS_TEST_BG_OFFSET above: that one moves the
             * whole carve, which cetrafs_validate_layout() catches at
             * mount (the BG regions are modelled as one contiguous span,
             * so a misplaced carve collides with the tail reserve). This
             * one leaves the global geometry correct and lies only in
             * the DESCRIPTOR -- which nothing validates against the span
             * -- so the volume mounts, reads clean, and only corrupts
             * once the allocator writes through that descriptor.
             *
             * That is the exact failure the grow test's third verify
             * exists for, and the only way to produce it on demand.
             */
            u64 desc_start = start;
            const long long sh = cetrafs_test_env_ll("CETRAFS_GROWFS_TEST_DESC_SHIFT", -65536, 65536, 0);

            if (sh) {
                if (sh < 0 && (u64) (-sh) * bg_size > desc_start)
                    die("test descriptor shift puts the region before block 0");
                desc_start = (u64) ((long long) desc_start + sh * (long long) bg_size);
            }

            bg.start_block = cetrafs_cpu_to_le64(desc_start);
            bg.length_blocks = cetrafs_cpu_to_le64(bg_size);
            bg.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
            bg.off_data_region = cetrafs_cpu_to_le32(off_data32);
            bg.data_block_count = cetrafs_cpu_to_le64(data_cnt);
            bg.free_data_blocks = cetrafs_cpu_to_le64(data_cnt);
            bg.checksum = cetrafs_cpu_to_le64(0);
            bg.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum),
                                                            sizeof(cetrafs_le64(bg.checksum))));

            memcpy(blk, &bg, sizeof(bg));
            write_block(fd, seg_first_desc + (b - old_b), blk, true);
            start += bg_size;
        }
    }

    /* The segment header, written LAST of the segment's blocks and
     * BEFORE it is linked: everything it describes is already on the
     * device when anything can reach it (rule 8). */
    {
        cetrafs_seg_hdr_t seg;

        memset(&seg, 0, sizeof(seg));
        seg.magic = cetrafs_cpu_to_le32(CETRAFS_BGSEG_MAGIC);
        seg.count = cetrafs_cpu_to_le32((u32) (new_b - old_b));
        seg.first_id = cetrafs_cpu_to_le32((u32) old_b);
        seg.next = cetrafs_cpu_to_le64(0);
        seg.checksum = cetrafs_cpu_to_le64(0);
        seg.checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(&seg, sizeof(seg),
                                                               offsetof(cetrafs_seg_hdr_t, checksum),
                                                               sizeof(seg.checksum)));
        memcpy(blk, &seg, sizeof(seg));
        write_block(fd, seg_header_lba, blk, true);
    }

    /* The inode table's segment, after the Block Group one: its bitmap
     * and records zeroed -- every number free, every record unborn --
     * and its header last, as above. */
    const u64 iseg_lba = seg_first_desc + (new_b - old_b);

    if (ino_add) {
        cetrafs_seg_hdr_t seg;

        zero_blocks(fd, iseg_lba + 1, ino_span - 1, true);
        memset(&seg, 0, sizeof(seg));
        seg.magic = cetrafs_cpu_to_le32(CETRAFS_INOSEG_MAGIC);
        seg.count = cetrafs_cpu_to_le32((u32) ino_add);
        seg.first_id = cetrafs_cpu_to_le32(old_inodes);
        seg.checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(&seg, sizeof(seg), offsetof(cetrafs_seg_hdr_t, checksum),
                                                               sizeof(seg.checksum)));
        memset(blk, 0, CETRAFS_BLOCK_SIZE);
        memcpy(blk, &seg, sizeof(seg));
        write_block(fd, iseg_lba, blk, true);
    }

    free(bg_owner);
    /* zg_added is freed after the post-publish aggregate pass below,
     * which is the only remaining user of it. */

    /* Everything the new superblock is about to name is now on the
     * device. Rule 8: the reference may not become durable before what
     * it refers to, and a dirty page is not written. */
    sync_device(fd, true);

    /* TEST-ONLY: damage what the grow must not damage. Zeroing the
     * pending-free queue of Zone Group 0, or every node's journal, is the
     * outcome of a grow that relocated a region and lost it. The
     * tests/kernel/growfs_pending_queue.sh and grow_dead_journal.sh
     * assertions must see the loss. */
    if (cetrafs_test_env("CETRAFS_GROWFS_TEST_CLOBBER_PENDING")) {
        zero_blocks(fd, cetrafs_le64(sb.pending_free_start), cetrafs_le32(sb.pending_free_blocks_per_zg), true);
        sync_device(fd, true);
    }
    if (cetrafs_test_env("CETRAFS_GROWFS_TEST_CLOBBER_JOURNAL")) {
        zero_blocks(fd, cetrafs_le64(sb.node_journal_start),
                    (u64) cetrafs_le32(sb.node_table_count) * cetrafs_le32(sb.node_journal_blocks), true);
        sync_device(fd, true);
    }

    /* ---------------------------------------------------------------
     * STEP 3: publish.
     *
     * One superblock write, and the volume is the new size. Every
     * structure it names was fsync'd above. On a FIRST grow a crash
     * before this point leaves the old filesystem intact -- the new BGs
     * and tables are unreferenced bytes past the end. On a second or
     * later grow it does not quite: the old tail's link below is
     * written first, and the chain then describes more Block Groups
     * than the old superblock counts, which mount and fsck refuse.
     * Nothing is lost and nothing is shared; re-running growfs finishes
     * the grow (the tail walk replaces that link).
     *
     * Offline, a plain write is sufficient ONLY because of the premise
     * enforced at the top of this function: no node is mounted, so there
     * is no peer to exclude and no concurrent writer of block 0. Live,
     * this tool writes neither the superblock nor the link: it hands the
     * superblock to the kernel, which publishes the same change by
     * compare-and-swap (cetrafs_grow_commit(), kmod/grow.c). The
     * superblock is 424 bytes and its checksum sits at offset 200, so it
     * is entirely inside sector 0 -- one swap carries all of it.
     * --------------------------------------------------------------- */
    sb.total_blocks = cetrafs_cpu_to_le64(target_blocks);
    sb.block_group_count = cetrafs_cpu_to_le32((u32) new_b);
    /* zg_table_start, bg_table_start and pending_free_start are NOT
     * touched. Nothing moved, which is the point: every address a
     * mounted peer cached is still correct. The chain head is what
     * makes the new descriptors reachable, and it is appended to rather
     * than rewritten -- a volume grown twice links the second segment
     * from the first, not from here. */
    if (cetrafs_le64(sb.bg_table_next) == 0)
        sb.bg_table_next = cetrafs_cpu_to_le64(seg_header_lba);
    else if (!live) /* live, the kernel links it once it has checked everything this grow wrote (kmod/grow.c) */
        growfs_link_tail(fd, dev, blk, cetrafs_le64(sb.bg_table_next), cetrafs_le64(sb.bg_table_first_count), old_b,
                         CETRAFS_BGSEG_MAGIC, "Block Group", seg_header_lba);
    if (ino_add) {
        if (cetrafs_le64(sb.inode_seg_next) == 0) {
            sb.inode_seg_next = cetrafs_cpu_to_le64(iseg_lba);
            sb.inode_first_count = cetrafs_cpu_to_le32(old_inodes);
        } else if (!live) {
            growfs_link_tail(fd, dev, blk, cetrafs_le64(sb.inode_seg_next), cetrafs_le32(sb.inode_first_count),
                             old_inodes, CETRAFS_INOSEG_MAGIC, "inode", iseg_lba);
        }
        sb.inodes_count = cetrafs_cpu_to_le32((u32) new_inodes);
    }
    if (cetrafs_le64(sb.bg_table_first_count) == 0)
        sb.bg_table_first_count = cetrafs_cpu_to_le64(old_b); /* pre-chain volume */
    sb.layout_gen = cetrafs_cpu_to_le64(cetrafs_le64(sb.layout_gen) + 1);
    /*
     * Stamp the current format version. A volume formatted by the
     * previous release arrives here as 0x0008 and leaves as 0x0009,
     * which is what stops that release from touching it again: its fsck
     * and its kernel module both reject a relocated layout, but they
     * reject it as DAMAGE -- "pending-free queue region layout
     * mismatch", "bg_regions_start < 1+Z+B" -- and an operator reading
     * that is one step away from running `fsck -r` on a healthy volume.
     * A version refusal says the true thing instead.
     *
     * Growing is therefore a one-way door with respect to older
     * packages. That is intended, and it is in the release notes.
     */
    sb.version = cetrafs_cpu_to_le16(CETRAFS_VERSION);
    sb.bg_data_end = cetrafs_cpu_to_le64(new_data_end);
    sb.tail_reserve_start = cetrafs_cpu_to_le64(reserve_start);
    sb.tail_reserve_blocks = cetrafs_cpu_to_le64(reserve_blocks);
    sb.orphan_blocks = cetrafs_cpu_to_le64(orphan_total);

    sb.checksum = cetrafs_cpu_to_le64(0);
    sb.checksum = cetrafs_cpu_to_le64(
        (u64) crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum)));

    /*
     * TEST-ONLY. Stops right before the publish, leaving steps 1 and 2
     * on the device and the superblock untouched -- the state a crash
     * mid-grow leaves behind. fsck must report such an image CLEAN at
     * the OLD size: the new BGs and tables are unreferenced bytes past
     * the end of the filesystem, not damage. Without this there is no
     * way to build that image at all.
     */
    if (cetrafs_test_env("CETRAFS_GROWFS_TEST_NO_PUBLISH")) {
        fprintf(stderr, "growfs.cetra: TEST MODE: stopping before the superblock publish\n");
        growfs_release_claim(fd);
        close(fd);
        free(blk);
        return 0;
    }

    if (live) {
        /*
         * The kernel publishes: it re-walks the layout this superblock
         * describes -- the segment, every new descriptor, every overlap
         * -- and only then credits the pool, links the segment and swaps
         * block 0. It refuses rather than publishes anything it would
         * not mount.
         */
        int dfd = open(live_where, O_RDONLY | O_DIRECTORY | O_CLOEXEC);

        /* TEST-ONLY: hand the kernel a superblock that skips a
         * generation, as a grower working from a superblock someone else
         * had already superseded would. The kernel must refuse it
         * (-ESTALE) with nothing written (tests/kernel/grow_live_race.sh). */
        if (cetrafs_test_env("CETRAFS_GROWFS_TEST_GEN_SKIP")) {
            fprintf(stderr, "growfs.cetra: TEST MODE: submitting layout_gen + 1 too far\n");
            sb.layout_gen = cetrafs_cpu_to_le64(cetrafs_le64(sb.layout_gen) + 1);
            sb.checksum = cetrafs_cpu_to_le64(0);
            sb.checksum = cetrafs_cpu_to_le64(
                (u64) crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum)));
        }

        if (dfd < 0)
            die_dev("open(%s): %s", live_where, strerror(errno));
        /* TEST-ONLY: give the claim up before asking the kernel to
         * publish, as a program calling the ioctl without growfs's claim
         * would. The kernel must refuse (-EBUSY; grow_live_race.sh E). */
        if (cetrafs_test_env("CETRAFS_GROWFS_TEST_UNCLAIMED")) {
            fprintf(stderr, "growfs.cetra: TEST MODE: releasing the claim before the publish\n");
            growfs_release_claim(fd);
        }
        /* The claim this grow holds: its row, and the nonce it wrote into
         * that row. The kernel publishes only under that claim, not under
         * any growfs row (audit L8). A grow that released its claim above
         * sends no row the kernel can match. */
        cetrafs_grow_arg_t ga;

        memset(&ga, 0, sizeof(ga));
        ga.sb = sb;
        if (grow_repair_row >= 0) {
            ga.claim_row = cetrafs_cpu_to_le32((uint32_t) grow_repair_row);
            memcpy(ga.claim_nonce, cetrafs_repair_nonce, sizeof(ga.claim_nonce));
        } else {
            ga.claim_row = cetrafs_cpu_to_le32(UINT32_MAX);
        }
        if (ioctl(dfd, CETRAFS_IOC_GROW, &ga) < 0) {
            int e = errno;

            close(dfd);
            growfs_release_claim(fd);
            if (e == ESTALE)
                die_dev("%s: the volume changed while this grow ran -- nothing was published; run it again", dev);
            if (e == EOPNOTSUPP)
                die_dev("%s: a node in the cluster cannot follow a live grow -- upgrade it, or grow offline", dev);
            if (e == EBUSY)
                die_dev("%s: the kernel found no growfs claim on the volume -- nothing was published", dev);
            die_dev("%s: the kernel refused to publish the grow: %s -- see dmesg; nothing was published unless\n"
                    "       it says the outcome is unknown",
                    dev, strerror(e));
        }
        close(dfd);
        free(zg_added);
        growfs_write_sb_copy(fd, &sb);
        growfs_release_claim(fd);
        close(fd);
        free(blk);
        fprintf(stdout,
                "cetrafs growfs: completed live (layout_gen %" PRIu64
                "); every node picks up the new space on its next heartbeat\n",
                cetrafs_le64(sb.layout_gen));
        return 0;
    }

    /*
     * A live grow that died after naming its pool credit (step 1,
     * kmod/grow.c) left a marker above the published layout_gen on the
     * Zone Group rows it credited. Every node treats such a marker as
     * dead and takes its credit back -- but this publish is about to
     * raise layout_gen past it, after which it reads as settled and the
     * dead credit stays in the pool for good (review of 63e7f0e). This
     * grow holds the volume, so no other grow is live: take the credit
     * back now, BEFORE the publish, exactly as the kernel's step 1 and
     * fsck -r do. A crash between the two leaves the pool right for the
     * layout still published.
     */
    /* TEST-ONLY: keep the dead credit, as this grow used to -- the
     * control of grow_live_crash.sh part 3. */
    if (!cetrafs_test_env("CETRAFS_GROWFS_TEST_KEEP_DEAD_CREDIT")) {
        u64 published = cetrafs_le64(sb.layout_gen) - 1; /* raised above, not yet written */

        for (u32 z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
            cetrafs_zone_group_t zg;
            u64 credit, pool;

            read_block(fd, cetrafs_le64(sb.zg_table_start) + z, blk);
            memcpy(&zg, blk, sizeof(zg));
            if (cetrafs_le64(zg.pool_grow_gen) <= published)
                continue;
            if ((u32) cetrafs_le64(zg.hot_checksum) !=
                crc32c_struct((const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                              offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF,
                              sizeof(zg.hot_checksum))) {
                fprintf(stderr, "growfs.cetra: Zone Group %u fails its checksum -- a dead grow's pool credit on it "
                                "was not taken back; run fsck -r\n",
                        z);
                grow_rc = 1;
                continue;
            }
            credit = cetrafs_le64(zg.pool_grow_credit);
            pool = cetrafs_le64(zg.pool_free_blocks);
            fprintf(stderr,
                    "growfs.cetra: Zone Group %u: taking back the pool credit (%" PRIu64 " blocks) of a live grow to "
                    "layout_gen %" PRIu64 " that never published\n",
                    z, credit, (u64) cetrafs_le64(zg.pool_grow_gen));
            zg.pool_free_blocks = cetrafs_cpu_to_le64(credit > pool ? 0 : pool - credit);
            zg.pool_grow_gen = zg.pool_grow_id = zg.pool_grow_credit = cetrafs_cpu_to_le64(0);
            zg.hot_checksum = cetrafs_cpu_to_le64(0);
            zg.hot_checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(
                (const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum)));
            memcpy(blk, &zg, sizeof(zg));
            write_block(fd, cetrafs_le64(sb.zg_table_start) + z, blk, true);
        }
        sync_device(fd, true);
    }

    memset(blk, 0, CETRAFS_BLOCK_SIZE);
    memcpy(blk, &sb, sizeof(sb));
    write_block(fd, CETRAFS_SB_BLOCK_NR, blk, true);
    sync_device(fd, true);
    growfs_write_sb_copy(fd, &sb);

    /*
     * Zone Group aggregates LAST, after the publish.
     *
     * They used to be written into a relocated copy of the Zone Group
     * table that the publish made live, so a crash before the publish
     * discarded them along with everything else. They are written in
     * place now, and doing it before the publish leaves a window where
     * a crash strands aggregates counting capacity the superblock does
     * not yet know about -- which fsck reports, correctly, as a volume
     * claiming free space its Block Groups do not have.
     *
     * After the publish the staleness runs the other way: a crash here
     * leaves the aggregates too LOW, so a node believes it has less
     * free space than it does. That is the conservative direction, and
     * these counters are caches that a reconcile rebuilds from the
     * bitmaps at the next ownership transfer anyway (PERFORMANCE.md).
     */
    /* Zone Group rows: re-stamped IN PLACE with the capacity they
     * gained. They do not move -- the Zone Group count is invariant
     * across a grow, so the table never needs to be bigger, and a row
     * a peer has cached stays at the address it cached. The
     * pending-free region likewise stays put: it is indexed by Zone
     * Group, so it cannot grow either. */
    /* TEST-ONLY: leave the Zone Group credits out, which is the state a
     * crash after the publish leaves; tests/image/fsck_grow_window.sh
     * needs it on an image. */
    const bool skip_agg = cetrafs_test_env("CETRAFS_GROWFS_TEST_NO_AGGREGATE") != NULL;

    for (u32 z = 0; z < old_z; ++z) {
        cetrafs_zone_group_t zg;

        if (!zg_added[z] || skip_agg)
            continue;
        read_block(fd, cetrafs_le64(sb.zg_table_start) + z, blk);
        memcpy(&zg, blk, sizeof(zg));
        /* As the segment above: restamping a damaged hot sector would
         * hide the damage under a valid checksum (audit L14). The grow
         * is already published, so this one is reported, not fatal: the
         * aggregate is a cache and the row is left for fsck. */
        if ((u32) cetrafs_le64(zg.hot_checksum) !=
            crc32c_struct((const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                          offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum))) {
            fprintf(stderr, "growfs.cetra: Zone Group %u fails its checksum -- its free count was not updated; run "
                            "fsck\n",
                    z);
            grow_rc = 1;
            continue;
        }
        zg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.free_data_blocks) + zg_added[z] * data_cnt);
        zg.hot_checksum = cetrafs_cpu_to_le64(0);
        zg.hot_checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(
            (const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
            offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum)));
        memcpy(blk, &zg, sizeof(zg));
        write_block(fd, cetrafs_le64(sb.zg_table_start) + z, blk, true);
    }
    free(zg_added);
    sync_device(fd, true);
    /* Give the volume back BEFORE the fd goes: the atexit backstop runs
     * after main() returns, by which time this descriptor is closed and
     * its write would silently do nothing (measured: the claim was
     * still on the device after a successful grow). The backstop stays
     * for the die() paths, where fd is still open. */
    growfs_release_claim(fd);
    close(fd);
    free(blk);

    fprintf(stdout, "cetrafs growfs: completed (layout_gen %" PRIu64 ") -- run fsck.cetra to verify\n",
            cetrafs_le64(sb.layout_gen));
    return grow_rc;
}
