/* SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary */
/*
 * growfs.cetra -- grow a cetrafs volume into space the device already
 * has (an enlarged LUN, or capacity a `mkfs.cetra -s` deliberately left
 * unformatted).
 *
 * OFFLINE ONLY. This build refuses to run while any node has the volume
 * mounted, and that refusal is load-bearing, not caution: every mounted
 * node caches the superblock and reads bg_table_start off it on the
 * per-block allocation path with no lock held. This tool RELOCATES that
 * table, so a peer running across a grow would keep compare-and-swapping
 * descriptors at the superseded LBAs -- divergent ownership, divergent
 * free counts, then double allocation. The live path needs an RCU'd
 * superblock swap, a layout_gen check on the heartbeat, and a node-
 * registry capability gate; until all three exist, "nobody is mounted"
 * is the entire mutual-exclusion argument and it must hold absolutely.
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

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s <blockdev> [-s size] [-n]\n"
            "  grows a cetrafs volume into space the device already has\n"
            "  -s: grow to this size instead of the whole device. Accepts a\n"
            "      K/M/G/T suffix; a bare number is MiB, like mkfs.cetra\n"
            "  -n: dry-run (compute & print, no writes)\n"
            "\n"
            "  The volume must be unmounted on EVERY node. Growing is not a\n"
            "  live operation in this build and the tool refuses rather than\n"
            "  risking it.\n",
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

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    const char *dev = argv[1];
    bool dry_run = false;
    u64 want_bytes = 0;
    int opt;

    while ((opt = getopt(argc - 1, argv + 1, "s:n")) != -1) {
        switch (opt) {
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

    /*
     * The offline premise, enforced before anything is read for a
     * decision. Both halves are needed and neither subsumes the other:
     * the first sees only THIS system's mount table, the second asks the
     * device itself about peers. Checked even in dry-run -- a dry-run
     * that printed a plan derived from a live cluster's moving geometry
     * would be worse than no plan.
     */
    {
        char where[4096];

        if (cetrafs_device_mounted(dev, where, sizeof(where)))
            die_dev("%s is mounted on %s -- unmount it first (growing is offline in this build)", dev, where);
    }
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
                "       Growing relocates the descriptor tables that node has cached, which would\n"
                "       send its allocator writes to superseded blocks. Unmount it there, then\n"
                "       retry. (row's own last_seen reads %llds ago by this machine's clock,\n"
                "       which means nothing if the two disagree.)",
                dev, row, label[0] ? ", " : "", label[0] ? label : "", age);
    }

    int fd = open(dev, dry_run ? (O_RDONLY | O_CLOEXEC) : (O_RDWR | O_CLOEXEC));

    if (fd < 0)
        die_dev("open(%s): %s", dev, strerror(errno));

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
    if (cetrafs_le32(sb.block_size) != CETRAFS_BLOCK_SIZE)
        die("%s: block size %u != %u", dev, cetrafs_le32(sb.block_size), CETRAFS_BLOCK_SIZE);
    {
        u64 stored = cetrafs_le64(sb.checksum);
        u32 calc;

        sb.checksum = 0;
        calc = crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum));
        sb.checksum = cetrafs_cpu_to_le64(stored);
        if ((u32) stored != calc)
            die("%s: superblock CRC32C mismatch (stored 0x%08X, computed 0x%08X) -- run fsck.cetra first", dev,
                (u32) stored, calc);
    }

    const u64 old_total = cetrafs_le64(sb.total_blocks);
    const u32 old_z = cetrafs_le32(sb.zone_group_count);
    const u32 old_b = cetrafs_le32(sb.block_group_count);
    const u64 bg_size = cetrafs_le64(sb.bg_size_blocks);
    const u64 regions_start = cetrafs_le64(sb.bg_regions_start);
    const u32 pending_per_zg = cetrafs_le32(sb.pending_free_blocks_per_zg);

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
     * which is what bg_data_end exists to describe (cetrafs.h); the
     * hole is counted into orphan_blocks below.
     */
    const u64 old_data_end = cetrafs_le64(sb.bg_data_end) ? cetrafs_le64(sb.bg_data_end)
                                                          : regions_start + (u64) old_b * bg_size;
    const u64 old_reserve_start = cetrafs_le64(sb.tail_reserve_start);
    const u64 old_reserve_blocks = cetrafs_le64(sb.tail_reserve_blocks);

    u64 new_bg_start = old_data_end;

    if (old_reserve_blocks && old_reserve_start + old_reserve_blocks > new_bg_start)
        new_bg_start = old_reserve_start + old_reserve_blocks;

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
        const char *tw = getenv("CETRAFS_GROWFS_TEST_BG_OFFSET");

        if (tw) {
            long long off = strtoll(tw, NULL, 10);

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
    u32 new_z = old_z;
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

        if (cand_b > UINT32_MAX)
            die("%s: %" PRIu64 " Block Groups exceeds the 32-bit block_group_count", dev, cand_b);

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
        u64 cand_z = old_z;

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
        u64 need = 1 /* segment header */ + (cand_b - old_b); /* added descriptors */

        if (need == reserve_blocks && cand_b == new_b && cand_z == new_z)
            break;

        reserve_blocks = need;
        new_b = cand_b;
        new_z = (u32) cand_z;
    }

    const u64 reserve_start = new_bg_start + (new_b - old_b) * bg_size;
    const u64 new_data_end = reserve_start; /* the box ends where the new BGs do */

    if (reserve_start + reserve_blocks > target_blocks)
        die("internal: tail reserve [%" PRIu64 ",+%" PRIu64 ") past target %" PRIu64, reserve_start, reserve_blocks,
            target_blocks);

    tail_waste = target_blocks - (reserve_start + reserve_blocks);

    /*
     * What this grow strands.
     *
     * First grow: the mkfs-time ZG table, BG table and pending-free
     * region, left behind in the PREFIX below bg_regions_start, where no
     * Block Group can ever be carved.
     *
     * Later grows: the superseded tail reserve, which is now a hole
     * INSIDE the data area's bounding box. Its prefix tables were
     * already counted by the first grow.
     */
    const u64 orphaned_now = old_reserve_blocks ? (new_bg_start - old_data_end)
                                                : (u64) old_z + old_b + (u64) old_z * pending_per_zg;
    const u64 orphan_total = cetrafs_le64(sb.orphan_blocks) + orphaned_now;

    u32 off_bmap32, off_data32;
    u64 data_cnt;

    cetrafs_calc_bg_layout(bg_size, &off_bmap32, &off_data32, &data_cnt);

    fprintf(stdout,
            "cetrafs growfs %s\n"
            "  device:      %llu bytes (%" PRIu64
            " blocks)\n"
            "  filesystem:  %" PRIu64 " -> %" PRIu64
            " blocks\n"
            "  Block Groups: %u -> %" PRIu64 " (+%" PRIu64
            ", %llu MiB each)\n"
            "  Zone Groups:  %u -> %u (+%u)\n"
            "  new BG regions: LBA %" PRIu64 " .. %" PRIu64
            "\n"
            "  tail reserve:   LBA %" PRIu64 "+%" PRIu64
            " (relocated ZG/BG/pending-free tables)\n"
            "  unused tail:    %" PRIu64
            " blocks (rounding)\n"
            "  orphaned by this grow: %" PRIu64 " blocks (%llu MiB); total ever: %" PRIu64 " blocks\n",
            dry_run ? "(DRY-RUN)" : "plan", dev_bytes, dev_blocks, old_total, target_blocks, old_b, new_b,
            new_b - old_b, (unsigned long long) (bg_size * CETRAFS_BLOCK_SIZE / 1024 / 1024), old_z, new_z,
            new_z - old_z, new_bg_start, reserve_start - 1, reserve_start, reserve_blocks, tail_waste, orphaned_now,
            (unsigned long long) (orphaned_now * CETRAFS_BLOCK_SIZE / 1024 / 1024), orphan_total);

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
        close(fd);
        return 0;
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
    {
        u64 start = new_bg_start;

        for (u64 b = old_b; b < new_b; ++b) {
            cetrafs_bg_header_t bh;

            memset(&bh, 0, sizeof(bh));
            bh.bg_id = cetrafs_cpu_to_le32((u32) b);
            bh.owner_zg = cetrafs_cpu_to_le16(0); /* fixed up by the ZG pass below */
            bh.flags = cetrafs_cpu_to_le16(0);
            bh.length_blocks = cetrafs_cpu_to_le64(bg_size);
            bh.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
            bh.off_data_region = cetrafs_cpu_to_le32(off_data32);
            bh.data_block_count = cetrafs_cpu_to_le64(data_cnt);
            bh.checksum = 0;
            bh.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bh, sizeof(bh), offsetof(cetrafs_bg_header_t, checksum),
                                                            sizeof(cetrafs_le64(bh.checksum))));

            memcpy(blk, &bh, sizeof(bh));
            write_block(fd, start, blk, true);

            /* A stale bitmap from a previous filesystem at these offsets
             * would read as "allocated" and silently cost the volume the
             * space, so these are really zeroed, not assumed zero. */
            zero_blocks(fd, start + off_bmap32, cetrafs_calc_bg_dbm_blocks(bg_size), true);
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
     * Existing ones keep their owner, read from the Block Group's own
     * record -- a Zone Group no longer carries a member list. New ones
     * are spread ROUND-ROBIN across every existing Zone Group, which is
     * what makes grown capacity reach every node at once instead of
     * landing on whichever one happens to own the tail. No Zone Group
     * record is rewritten at all: the only thing that changes is each
     * one's free-space aggregate.
     * docs/internal/BG-OWNERSHIP-DESIGN.md
     */
    u32 *bg_owner = (u32 *) xcalloc(new_b, sizeof(u32));
    u64 *zg_added = (u64 *) xcalloc(new_z, sizeof(u64));

    for (u64 b = 0; b < old_b; ++b) {
        cetrafs_block_group_t obg;

        read_block(fd, cetrafs_le64(sb.bg_table_start) + b, blk);
        memcpy(&obg, blk, sizeof(obg));
        bg_owner[b] = cetrafs_le16(obg.owner_zg);
    }
    for (u64 b = old_b; b < new_b; ++b) {
        bg_owner[b] = (u32) (b % old_z);
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
            const char *ds = getenv("CETRAFS_GROWFS_TEST_DESC_SHIFT");

            if (ds) {
                long long sh = strtoll(ds, NULL, 10);

                if (sh < 0 && (u64) (-sh) * bg_size > desc_start)
                    die("test descriptor shift puts the region before block 0");
                desc_start = (u64) ((long long) desc_start + sh * (long long) bg_size);
            }

            bg.start_block = cetrafs_cpu_to_le64(desc_start);
            bg.length_blocks = cetrafs_cpu_to_le64(bg_size);
            bg.off_bg_header = cetrafs_cpu_to_le32(0);
            bg.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
            bg.off_data_region = cetrafs_cpu_to_le32(off_data32);
            bg.data_block_count = cetrafs_cpu_to_le64(data_cnt);
            bg.free_data_blocks = cetrafs_cpu_to_le64(data_cnt);
            bg.checksum = 0;
            bg.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum),
                                                            sizeof(cetrafs_le64(bg.checksum))));

            memcpy(blk, &bg, sizeof(bg));
            write_block(fd, seg_first_desc + (b - old_b), blk, true);

            /* The header written in step 1 guessed owner_zg; correct it
             * now that the spans are decided. Still ahead of the publish,
             * so nothing has ever seen the wrong value. */
            {
                cetrafs_bg_header_t bh;

                read_block(fd, start, blk);
                memcpy(&bh, blk, sizeof(bh));
                bh.owner_zg = cetrafs_cpu_to_le16((u16) bg_owner[b]);
                bh.checksum = 0;
                bh.checksum = cetrafs_cpu_to_le64(crc32c_struct(
                    &bh, sizeof(bh), offsetof(cetrafs_bg_header_t, checksum), sizeof(cetrafs_le64(bh.checksum))));
                memcpy(blk, &bh, sizeof(bh));
                write_block(fd, start, blk, true);
            }
            start += bg_size;
        }
    }

    /* The segment header, written LAST of the segment's blocks and
     * BEFORE it is linked: everything it describes is already on the
     * device when anything can reach it (rule 8). */
    {
        cetrafs_bg_segment_t seg;

        memset(&seg, 0, sizeof(seg));
        seg.magic = cetrafs_cpu_to_le32(CETRAFS_BGSEG_MAGIC);
        seg.count = cetrafs_cpu_to_le32((u32) (new_b - old_b));
        seg.first_bg_id = cetrafs_cpu_to_le32((u32) old_b);
        seg.next = cetrafs_cpu_to_le64(0);
        seg.checksum = 0;
        seg.checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(&seg, sizeof(seg),
                                                               offsetof(cetrafs_bg_segment_t, checksum),
                                                               sizeof(seg.checksum)));
        memcpy(blk, &seg, sizeof(seg));
        write_block(fd, seg_header_lba, blk, true);
    }

    free(bg_owner);
    /* zg_added is freed after the post-publish aggregate pass below,
     * which is the only remaining user of it. */

    /* Everything the new superblock is about to name is now on the
     * device. Rule 8: the reference may not become durable before what
     * it refers to, and a dirty page is not written. */
    sync_device(fd, true);

    /* ---------------------------------------------------------------
     * STEP 3: publish.
     *
     * One superblock write, and the volume is the new size. Every
     * structure it names was fsync'd above, so a crash before this point
     * leaves the OLD filesystem intact and fully consistent -- the new
     * BGs and tables are simply unreferenced bytes past the end.
     *
     * A plain write is sufficient ONLY because of the offline premise
     * enforced at the top of this function: no node is mounted, so there
     * is no peer to exclude and no concurrent writer of block 0. The
     * superblock is 424 bytes and its checksum sits at offset 200, so it
     * is entirely inside sector 0 -- which is what will let the live
     * path publish this exact same change with one atomic
     * cetrafs_cas_region(sb, 0, 0, ...) instead, when it exists.
     * --------------------------------------------------------------- */
    sb.total_blocks = cetrafs_cpu_to_le64(target_blocks);
    sb.zone_group_count = cetrafs_cpu_to_le32(new_z);
    sb.block_group_count = cetrafs_cpu_to_le32((u32) new_b);
    /* zg_table_start, bg_table_start and pending_free_start are NOT
     * touched. Nothing moved, which is the point: every address a
     * mounted peer cached is still correct. The chain head is what
     * makes the new descriptors reachable, and it is appended to rather
     * than rewritten -- a volume grown twice links the second segment
     * from the first, not from here. */
    if (cetrafs_le64(sb.bg_table_next) == 0) {
        sb.bg_table_next = cetrafs_cpu_to_le64(seg_header_lba);
    } else {
        /*
         * Second and later grows link from the TAIL segment, not from
         * here -- one compare-and-swap on one record, which is what the
         * live path will do. Walk to the tail, bounded: a chain that
         * does not terminate is corruption, and looping forever while
         * holding a volume open is a worse answer than refusing.
         */
        u64 cur = cetrafs_le64(sb.bg_table_next);
        unsigned guard = 0;

        for (;;) {
            cetrafs_bg_segment_t seg;

            if (++guard > new_b + 2)
                die("%s: the Block Group table chain does not terminate", dev);
            read_block(fd, cur, blk);
            memcpy(&seg, blk, sizeof(seg));
            if (cetrafs_le32(seg.magic) != CETRAFS_BGSEG_MAGIC)
                die("%s: Block Group table segment at %" PRIu64 " has no magic", dev, cur);
            if (cetrafs_le64(seg.next) == 0) {
                seg.next = cetrafs_cpu_to_le64(seg_header_lba);
                seg.checksum = 0;
                seg.checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(&seg, sizeof(seg),
                                                                       offsetof(cetrafs_bg_segment_t, checksum),
                                                                       sizeof(seg.checksum)));
                memcpy(blk, &seg, sizeof(seg));
                write_block(fd, cur, blk, true);
                sync_device(fd, true);
                break;
            }
            cur = cetrafs_le64(seg.next);
        }
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

    sb.checksum = 0;
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
    if (getenv("CETRAFS_GROWFS_TEST_NO_PUBLISH")) {
        fprintf(stderr, "growfs.cetra: TEST MODE: stopping before the superblock publish\n");
        close(fd);
        free(blk);
        return 0;
    }

    memset(blk, 0, CETRAFS_BLOCK_SIZE);
    memcpy(blk, &sb, sizeof(sb));
    write_block(fd, CETRAFS_SB_BLOCK_NR, blk, true);
    sync_device(fd, true);

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
    for (u32 z = 0; z < new_z; ++z) {
        cetrafs_zone_group_t zg;

        if (!zg_added[z])
            continue;
        read_block(fd, cetrafs_le64(sb.zg_table_start) + z, blk);
        memcpy(&zg, blk, sizeof(zg));
        zg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.free_data_blocks) + zg_added[z] * data_cnt);
        zg.hot_checksum = 0;
        zg.hot_checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(
            (const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
            offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum)));
        memcpy(blk, &zg, sizeof(zg));
        write_block(fd, cetrafs_le64(sb.zg_table_start) + z, blk, true);
    }
    free(zg_added);
    sync_device(fd, true);
    close(fd);
    free(blk);

    fprintf(stdout, "cetrafs growfs: completed (layout_gen %" PRIu64 ") -- run fsck.cetra to verify\n",
            cetrafs_le64(sb.layout_gen));
    return 0;
}
