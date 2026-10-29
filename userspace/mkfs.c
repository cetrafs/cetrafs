// SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary
/* mkfs.cetrafs — mkfs for CETRAFS v2.2 (QoL + CRC32C)
 *
 * Matches cetrafs.h (v2.1) layout.
 *
 * New in v2.2:
 *  - -n/--dry-run (no writes, prints computed layout)
 *  - -f/--force (allow overwrite on non-empty/existing FS)
 *  - Static asserts on structure sizes
 *  - CRC32C checksums for SB and ZG (stored in their .checksum fields)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h> /* BLKGETSIZE64 */
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"
#include "devutil.h"

#define CETRAFS_ROOT_INO 1ULL

/* ---------- compile-time guards ---------- */
#define STATIC_ASSERT(COND, MSG) _Static_assert(COND, MSG)
STATIC_ASSERT(sizeof(cetrafs_superblock_t) <= CETRAFS_BLOCK_SIZE, "SB > block");
STATIC_ASSERT(sizeof(cetrafs_zone_group_t) <= CETRAFS_BLOCK_SIZE, "ZG > block");
STATIC_ASSERT(sizeof(cetrafs_block_group_t) <= CETRAFS_BLOCK_SIZE, "BG desc > block");
STATIC_ASSERT(sizeof(cetrafs_bg_header_t) <= CETRAFS_BLOCK_SIZE, "BG header > block");
STATIC_ASSERT(sizeof(cetrafs_node_entry_t) <= CETRAFS_BLOCK_SIZE, "node entry > block");

/* ---------- small utils ---------- */
/* Exit-code contract, aligned with fsck.cetra/defrag.cetra for deployment
 * automation (provisioning scripts on a shared LUN branch on these):
 *   0  success
 *   1  could not create the filesystem (too small, non-empty, geometry,
 *      write failure, internal error)
 *   2  bad invocation / out-of-range arguments
 *   3  device could not be accessed or is in use (open/ioctl failure,
 *      mounted locally, or mounted by a live peer) -- mirrors fsck's
 *      "could not examine the device". */
static void vdie(int code, const char *fmt, va_list ap)
{
    vfprintf(stderr, fmt, ap);
    if (fmt[0] && fmt[strlen(fmt) - 1] != '\n')
        fprintf(stderr, "\n");
    exit(code);
}
static void die(const char *fmt, ...) /* exit 1: creation failure */
{
    va_list ap;
    va_start(ap, fmt);
    vdie(1, fmt, ap);
    va_end(ap); /* unreached */
}
static void die_arg(const char *fmt, ...) /* exit 2: bad arguments */
{
    va_list ap;
    va_start(ap, fmt);
    vdie(2, fmt, ap);
    va_end(ap);
}
static void die_dev(const char *fmt, ...) /* exit 3: device inaccessible / in use */
{
    va_list ap;
    va_start(ap, fmt);
    vdie(3, fmt, ap);
    va_end(ap);
}

static void *xcalloc(size_t n, size_t s)
{
    void *p = calloc(n, s);
    if (!p)
        die("OOM (%zu x %zu)", n, s);
    return p;
}

static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    const char *p = (const char *) buf;
    while (len) {
        ssize_t w = pwrite(fd, p, len, off);
        if (w < 0)
            die("pwrite failed: %s", strerror(errno));
        p += (size_t) w;
        off += (off_t) w;
        len -= (size_t) w;
    }
}

static void write_block(int fd, u64 block_num, const void *data, bool do_write)
{
    if (!do_write)
        return;
    pwrite_all(fd, data, CETRAFS_BLOCK_SIZE, (off_t) block_num * CETRAFS_BLOCK_SIZE);
}

static void zero_blocks(int fd, u64 start_block, u64 count, bool do_write)
{
    if (!do_write)
        return;
    static u8 *z;
    static size_t zlen;
    if (!z) {
        zlen = CETRAFS_BLOCK_SIZE;
        z = (u8 *) calloc(1, zlen);
    }
    for (u64 i = 0; i < count; ++i)
        write_block(fd, start_block + i, z, true);
}

static inline void bmap_set_bit(u8 *bm, u64 bit)
{
    bm[bit >> 3] |= (u8) (1u << (bit & 7));
}

static bool is_device_nonempty(int fd, u64 blocks_to_scan, u32 *found_magic)
{
    u8 *buf = (u8 *) malloc(CETRAFS_BLOCK_SIZE);
    if (!buf)
        return true; /* conservative */

    /* check block 0 for our magic */
    if (pread(fd, buf, CETRAFS_BLOCK_SIZE, 0) == (ssize_t) CETRAFS_BLOCK_SIZE) {
        u32 mg = *(u32 *) buf;
        if (found_magic)
            *found_magic = mg;
        if (mg == CETRAFS_MAGIC) {
            free(buf);
            return true;
        }
        /* if not empty (any non-zero in first blocks), consider non-empty */
        for (size_t i = 0; i < CETRAFS_BLOCK_SIZE; ++i)
            if (buf[i] != 0) {
                free(buf);
                return true;
            }
    }

    /* scan a few more blocks */
    for (u64 b = 1; b < blocks_to_scan; ++b) {
        if (pread(fd, buf, CETRAFS_BLOCK_SIZE, (off_t) b * CETRAFS_BLOCK_SIZE) != (ssize_t) CETRAFS_BLOCK_SIZE)
            break;
        for (size_t i = 0; i < CETRAFS_BLOCK_SIZE; ++i)
            if (buf[i] != 0) {
                free(buf);
                return true;
            }
    }

    free(buf);
    return false; /* looks empty */
}

/* ---------- CLI ---------- */
static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s <blockdev> [-z ZGs] [-b BG_MiB] [-N inodes] [-J MiB] [-M nodes]\n"
            "       [-s size] [-n] [-f]\n"
            "  -z: number of Zone Groups (1..%u), default 16 (clamped down to\n"
            "      however many Block Groups the device can actually back if\n"
            "      fewer than that -- a ZG with no BGs is never useful, even if\n"
            "      -z was given explicitly)\n"
            "  -b: Block Group size in MiB (default 1024, auto-shrunk to 512 on\n"
            "      small devices where 1024 would waste >10%% of capacity to\n"
            "      rounding -- pass -b explicitly to disable this)\n"
            "  -N: total inodes (default: derived from size, 1 per 4MiB, capped at 65536)\n"
            "  -J: per-NODE journal size in MiB (default 2, auto-shrunk on small\n"
            "      devices to cap the total reservation across all -M node slots\n"
            "      at ~5%% of capacity; 0 disables; pass -J explicitly to\n"
            "      disable the auto-shrink)\n"
            "  -M: Node Registry capacity, max cluster nodes (default 64)\n"
            "  -s: format only this much of the device, leaving the rest unused\n"
            "      until the volume is grown (default: the whole device). Accepts\n"
            "      a K/M/G/T suffix; a bare number is MiB, like -b and -J\n"
            "  -n: dry-run (compute & print, no writes)\n"
            "  -f: force (overwrite even if device looks non-empty)\n",
            argv0, CETRAFS_MAX_ZONE_GROUPS);
}

/*
 * Parse a -s size: a decimal number with an optional binary suffix
 * (K/M/G/T, case-insensitive). A bare number is MiB, consistent with
 * -b and -J. Returns bytes; dies on anything malformed or out of range.
 *
 * Bounded well below u64 overflow before the multiply, the same way -b
 * and -J are: a size that wraps feeds a garbage total_blocks into every
 * geometry computation downstream.
 */
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
    case 'M': mult = 1024ULL * 1024ULL; break;
    case 'k':
    case 'K': mult = 1024ULL; break;
    case 'g':
    case 'G': mult = 1024ULL * 1024ULL * 1024ULL; break;
    case 't':
    case 'T': mult = 1024ULL * 1024ULL * 1024ULL * 1024ULL; break;
    default:  die_arg("-s: unknown suffix '%s' (use K, M, G or T)", end);
              return 0; /* unreachable; keeps the compiler quiet */
    }
    if (*end && end[1] != '\0')
        die_arg("-s: trailing garbage after suffix: %s", arg);

    if (v == 0)
        die_arg("-s: zero");
    if (v > UINT64_MAX / mult)
        die_arg("-s: too large");

    return (u64) v * mult;
}

/*
 * Given a candidate BG size (in blocks) and the metadata footprint
 * already fixed before any BG region, return how many whole BGs fit
 * (0 if none) and how many blocks would be left permanently unused past
 * the last one -- there's no partial/fractional trailing BG, so a
 * device whose size isn't a clean multiple of the BG size (plus fixed
 * overhead) always loses some tail to rounding. Shared between the
 * auto-sizing heuristic below and the real geometry solve, so there's
 * only one copy of this formula.
 */
static u64 cetrafs_solve_bg_count(u64 total_blocks, u64 fixed_wo_B, u64 bg_size_blocks, u64 *out_waste)
{
    u64 R, B, consumed;

    if (total_blocks <= fixed_wo_B + (bg_size_blocks + 1)) {
        *out_waste = total_blocks > fixed_wo_B ? total_blocks - fixed_wo_B : total_blocks;
        return 0;
    }

    R = total_blocks - fixed_wo_B;
    B = R / (bg_size_blocks + 1ULL); /* floor */
    consumed = fixed_wo_B + B + B * bg_size_blocks;

    *out_waste = total_blocks - consumed;
    return B;
}

/* ---------- main mkfs ---------- */
int main(int argc, char **argv)
{
    if (argc < 2) {
        usage(argv[0]);
        return 2; /* usage, as fsck.cetra and defrag.cetra also use */
    }

    const char *dev = argv[1];

    u32 zg_count = 16;                                 /* default */
    u64 bg_size_bytes = CETRAFS_DEFAULT_BG_SIZE_BYTES; /* default 1 GiB */
    u64 inodes_total = 0;                              /* 0 => derive */
    u64 j_per_node_bytes = 2ULL * 1024 * 1024;         /* 2 MiB per node slot */
    u64 node_table_count = 64;                         /* default cluster-size cap */
    bool dry_run = false;
    bool force = false;
    bool bg_size_explicit = false;
    bool j_explicit = false;
    u64 fs_bytes = 0; /* -s: format only this much of the device (0 => all) */

    int opt;
    while ((opt = getopt(argc - 1, argv + 1, "z:b:N:J:M:s:nf")) != -1) {
        switch (opt) {
        case 'z': {
            long v = strtol(optarg, NULL, 10);
            if (v < 1 || v > (long) CETRAFS_MAX_ZONE_GROUPS)
                die_arg("-z out of range");
            zg_count = (u32) v;
            break;
        }
        case 'b': {
            long long mib = strtoll(optarg, NULL, 10);
            if (mib < 512)
                die_arg("-b too small (min 512 MiB)");
            /* Bounded ABOVE too: past ~2^44 MiB the byte multiplication
             * below wraps u64 and a garbage bg_size feeds every geometry
             * computation. 1 PiB per BG is already far beyond any device
             * this supports. */
            if (mib > (1LL << 30))
                die_arg("-b too large (max 1 PiB)");
            bg_size_bytes = (u64) mib * 1024ULL * 1024ULL;
            if (bg_size_bytes % CETRAFS_BLOCK_SIZE)
                die_arg("-b must be multiple of 4KiB");
            bg_size_explicit = true;
            break;
        }
        case 'N': {
            long long nin = strtoll(optarg, NULL, 10);
            if (nin < 1024)
                die_arg("-N too small (min 1024)");
            /*
             * The superblock stores this in a __le32, so anything past
             * UINT32_MAX is silently truncated -- while the inode table
             * is still SIZED from the full value. Measured: -N 4294967400
             * reserved 4294967400 blocks (16 TiB) of inode table on a
             * volume whose superblock then claimed 104 inodes. The
             * layout check at mount passes (104 <= 4294967400), so the
             * result is a volume that holds a hundred files and has
             * given its entire capacity to a table for them.
             *
             * Refuse instead. This is the same shape as the -M cap
             * below: a value the on-disk format cannot represent must
             * fail at format time, not become something else.
             */
            if ((unsigned long long) nin > UINT32_MAX)
                die_arg("-N too large (max %llu: the superblock stores the inode count in 32 bits)",
                    (unsigned long long) UINT32_MAX);
            inodes_total = (u64) nin;
            break;
        }
        case 'J': {
            long long mib = strtoll(optarg, NULL, 10);
            if (mib < 0)
                die_arg("-J invalid");
            /* Same overflow bound as -b; a journal slice has no business
             * anywhere near it either. */
            if (mib > (1LL << 30))
                die_arg("-J too large (max 1 PiB)");
            j_per_node_bytes = (u64) mib * 1024ULL * 1024ULL;
            if (j_per_node_bytes % CETRAFS_BLOCK_SIZE)
                die_arg("-J must be multiple of 4KiB");
            j_explicit = true;
            break;
        }
        case 'M': {
            long long m = strtoll(optarg, NULL, 10);
            if (m < 1 || m > 0xFFFE)
                die_arg("-M out of range (1..65534)");
            if (m > CETRAFS_MAX_READER_NODES) {
                fprintf(stderr,
                        "-M %llu exceeds the %u-row cap: a file's cross-node reader set is a 64-bit\n"
                        "presence mask (cetrafs_inode_t.read_open_nodes), and a node that could not be\n"
                        "represented in it would reopen the unlink-while-open-for-read hole.\n",
                        (unsigned long long) m, CETRAFS_MAX_READER_NODES);
                return 2; /* out-of-range argument */
            }
            node_table_count = (u64) m;
            break;
        }
        case 's':
            fs_bytes = parse_size_bytes(optarg);
            if (fs_bytes % CETRAFS_BLOCK_SIZE)
                die_arg("-s must be a multiple of 4KiB");
            break;
        case 'n':
            dry_run = true;
            break;
        case 'f':
            force = true;
            break;
        default:
            usage(argv[0]);
            return 2; /* bad option */
        }
    }

    /* Safety first: never format a device a kernel on this system has
     * mounted -- not even with -f or in dry-run; -f is about overwriting
     * on-disk data, not about racing a live mount. See devutil.h. */
    {
        char where[4096];

        if (cetrafs_device_mounted(dev, where, sizeof(where)))
            die_dev("%s is mounted on %s -- unmount it first", dev, where);
    }

    /* And the case that actually matters on a shared LUN: ANOTHER node
     * having it mounted right now. Invisible to the check above, which
     * only sees this system's own mount table -- but the peers record
     * themselves in the Node Registry, so the device itself can be
     * asked. Refused even with -f and even in dry-run, for the same
     * reason: -f overwrites data, it does not license formatting a
     * volume out from under a running cluster. Waiting out the peer's
     * stale window is the escape hatch if it really is gone. */
    {
        char label[CETRAFS_NODE_LABEL_LEN + 1] = {0};
        long long age = 0;
        uint32_t row = 0;

        int lp = cetrafs_find_live_peer(dev, &row, label, sizeof(label), &age);

        if (lp < 0)
            die_dev("%s: cannot read its Node Registry (I/O error) -- so it is impossible to\n"
                    "       prove no other node has this volume mounted, and formatting on a guess\n"
                    "       destroys a live cluster's volume. Fix the device and retry.",
                    dev);
        if (lp)
            die_dev("%s is mounted by another node (registry row %u%s%s) -- it is still heartbeating\n"
                "       -- formatting it now would destroy a live cluster's volume.\n"
                "       Unmount it there, then retry. (row's own last_seen reads %llds ago by this\n"
                "       machine's clock, which means nothing if the two disagree.)",
                dev, row, label[0] ? ", " : "", label[0] ? label : "", age);
    }

    int fd = open(dev, dry_run ? (O_RDONLY | O_CLOEXEC) : (O_RDWR | O_CLOEXEC));
    if (fd < 0)
        die_dev("open(%s): %s", dev, strerror(errno));

    unsigned long long dev_bytes = 0ULL;
    if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0)
        die_dev("BLKGETSIZE64: %s", strerror(errno));

    /*
     * -s formats only the first fs_bytes of the device. The filesystem
     * is then smaller than the LUN it sits on, and everything past
     * total_blocks is untouched -- which is exactly the state a volume
     * is in after its LUN has been grown but before the filesystem has.
     *
     * That equivalence is the point: `growfs` has only two inputs,
     * sb.total_blocks and the device's block count, so an undersized
     * mkfs and a real LUN resize present it with the identical delta.
     * It makes the grow path testable without ever asking a storage
     * array for anything (docs/internal/EXTENDFS-DESIGN.md).
     *
     * It is a real option, not a test hook -- deliberately formatting
     * smaller than the LUN and growing into it later is the normal
     * reason the grow feature exists -- but it is a footgun, so an
     * undersize is always announced, dry-run included.
     */
    u64 fs_size_bytes = dev_bytes;

    if (fs_bytes) {
        if (fs_bytes > dev_bytes)
            die_arg("-s %llu bytes exceeds the device (%llu bytes)", (unsigned long long) fs_bytes, dev_bytes);
        fs_size_bytes = fs_bytes;
    }

    u64 total_blocks = fs_size_bytes / CETRAFS_BLOCK_SIZE;
    if (total_blocks < 1024) {
        die("%s too small: %llu bytes (blocks=%" PRIu64 ")", fs_bytes ? "-s size" : "device",
            (unsigned long long) fs_size_bytes, (uint64_t) total_blocks);
    }

    if (fs_size_bytes < dev_bytes)
        fprintf(stderr,
                "note: formatting %llu of %llu bytes (%.1f%%) -- %llu bytes past the end of the\n"
                "      filesystem are left untouched and are not usable until the volume is grown\n",
                (unsigned long long) fs_size_bytes, dev_bytes, 100.0 * (double) fs_size_bytes / (double) dev_bytes,
                dev_bytes - (unsigned long long) fs_size_bytes);

    /* Derived from the FILESYSTEM size, not the device: with -s the two
     * differ, and sizing the inode table for space the volume does not
     * yet have would spend a large fraction of a small filesystem on a
     * table for files it cannot hold. A grow does not add inodes
     * (-N at grow time is fixed), so this is also the honest number. */
    if (!inodes_total)
        inodes_total = cetrafs_default_inodes_for_bytes(fs_size_bytes);

    /* --- non-empty check --- */
    if (!dry_run && !force) {
        u32 mg = 0;
        bool nonempty = is_device_nonempty(fd, 256 /* ~1MB */, &mg);
        if (nonempty) {
            if (mg == CETRAFS_MAGIC)
                die("Refusing to overwrite existing cetrafs (use -f)");
            else
                die("Refusing to format non-empty device (use -f)");
        }
    }

    /* --- compute metadata footprint, auto-tune J/B, and solve B --- */
    const u64 sb_blocks = 1;
    const u64 i_bmap_blk = cetrafs_calc_inode_bmap_blocks(inodes_total);
    const u64 i_tbl_blk = cetrafs_calc_inode_table_blocks(inodes_total, CETRAFS_INODE_ONDISK_SIZE);
    /* Node Registry is packed densely like the inode table, just a much
     * smaller one -- cetrafs_calc_inode_table_blocks() is generic enough
     * ("N entries of a given size, packed with no gaps") to reuse as-is. */
    const u64 node_tbl_blk = cetrafs_calc_inode_table_blocks(node_table_count, sizeof(cetrafs_node_entry_t));

    u64 zg_blocks, pending_total_blk, fixed_wo_B, bg_size_blocks, B, waste;

    /* Per-NODE journal sizing (version 0x0006): depends only on
     * node_table_count, which is fixed, so it can be settled once
     * outside the zg_count clamp loop below. Auto-tune (only when -J
     * wasn't given): cap the TOTAL reservation across all node slots at
     * ~5% of the device. A per-node area smaller than 1 flag block + 1
     * slot (slots are 2 blocks) can't hold a single journal entry --
     * treat that as "journaling disabled" rather than reserving a
     * useless sliver. */
    u64 j_per_node_blk = j_per_node_bytes / CETRAFS_BLOCK_SIZE;

    if (!j_explicit) {
        u64 cap_per_node_blk = (total_blocks / 20) / node_table_count;

        if (cap_per_node_blk < j_per_node_blk)
            j_per_node_blk = cap_per_node_blk;
    }
    if (j_per_node_blk > 0 && j_per_node_blk < 3) {
        if (j_explicit)
            die("-J too small for even one journal slot (need >= 12KiB per node)");
        j_per_node_blk = 0;
    }

    const u64 j_total_blk = j_per_node_blk * node_table_count;

    /* zg_count feeds the footprint below (one ZG-table block and one
     * pending-free-queue reservation per ZG), which is itself one input
     * to solving B -- so a Zone Group count larger than the Block Group
     * count the device can actually back can't be caught until B comes
     * out of this very computation. At most two passes are ever needed:
     * pass 2 only ever *shrinks* zg_count, which can only free up more
     * room for B, never less, so pass 2's own B can never again
     * undershoot pass 2's (already-shrunk) zg_count. */
    /* Per-ZG pending-free queue size. The target is a queue big enough
     * to absorb one large image's worth of freed extents (see the
     * header), but on a small device that reservation is a large
     * fraction of the volume and will never be filled -- so cap the
     * whole pending area at CETRAFS_PENDING_FREE_MAX_PERCENT and shrink
     * the per-ZG size to fit, never below the minimum. Every reader
     * takes the real value from the superblock. */
    /* The per-ZG queue is a flat CETRAFS_PENDING_FREE_BLOCKS_PER_ZG.
     *
     * An adaptive cap was tried and removed: a Zone Group needs at
     * least one Block Group, and the smallest BG is 512 MiB, so
     * zg_count can never exceed total/512MiB. The per-ZG share of even
     * a 1%-of-volume budget is therefore always at least ~1310 blocks
     * -- five times the target -- and the cap could not fire on any
     * geometry mkfs can produce. A limit that cannot be reached is not
     * a safeguard, it is dead code that reads like one. */
    const u32 pending_per_zg = CETRAFS_PENDING_FREE_BLOCKS_PER_ZG;

    for (int pass = 0; pass < 2; pass++) {
        zg_blocks = zg_count; /* 1 block each */
        pending_total_blk = (u64) pending_per_zg * zg_count;
        fixed_wo_B = sb_blocks + zg_blocks + i_bmap_blk + i_tbl_blk + node_tbl_blk + pending_total_blk + j_total_blk;

        /* Auto-tune the default BG size (only when -b wasn't given): the
         * default 1 GiB is fine whenever several such BGs fit, but on a
         * small device it can waste a large fraction of capacity to
         * rounding (no partial trailing BG exists). Falls back to 512
         * MiB -- the smallest size -b itself still allows -- when the 1
         * GiB default would waste more than ~10% of the device; this is
         * exactly what a user would discover by hand and pass -b for, so
         * do it for them by default instead. Reset to the 1 GiB default
         * at the top of each pass, same reason as the journal default
         * above: pass 2 must judge this fresh against its own footprint,
         * not inherit pass 1's possibly-stale shrink. */
        if (!bg_size_explicit) {
            bg_size_bytes = CETRAFS_DEFAULT_BG_SIZE_BYTES;

            const u64 cand_1g_blk = CETRAFS_DEFAULT_BG_SIZE_BYTES / CETRAFS_BLOCK_SIZE;
            const u64 cand_512m_blk = (512ULL * 1024 * 1024) / CETRAFS_BLOCK_SIZE;
            u64 waste_1g, waste_512m;
            u64 b_1g = cetrafs_solve_bg_count(total_blocks, fixed_wo_B, cand_1g_blk, &waste_1g);

            if (b_1g == 0 || waste_1g * 10 > total_blocks) {
                u64 b_512m = cetrafs_solve_bg_count(total_blocks, fixed_wo_B, cand_512m_blk, &waste_512m);

                if (b_512m > 0 && (b_1g == 0 || waste_512m < waste_1g))
                    bg_size_bytes = 512ULL * 1024 * 1024;
            }
        }

        bg_size_blocks = bg_size_bytes / CETRAFS_BLOCK_SIZE;

        /* Solve B from: B * (bg_size_blocks + 1 BG-table block per BG) <= remaining */
        B = cetrafs_solve_bg_count(total_blocks, fixed_wo_B, bg_size_blocks, &waste);
        if (B == 0)
            die("no space for any BG (increase device or reduce -b/-J/-N)");

        if (B >= zg_count)
            break;

        /* A Zone Group with zero Block Groups is permanently useless --
         * claimable by a node but giving it no real allocation capacity
         * at all, and able to poison every node's worst-case max-file-
         * size computation down to zero just by existing (kmod/
         * zonegroup.c's cetrafs_compute_max_file_size() picks a node's
         * *smallest* possible ZG claim, and a zero-BG ZG is as small as
         * it gets) -- caught via a real deployment that mkfs'd -z 16
         * against a device only large enough for 9 Block Groups.
         * Clamped rather than a hard die(): asking for more ZGs than
         * this device can usefully back isn't a real request, just an
         * oversized default on a small device, the same shape of problem
         * -b/-J already auto-tune around above -- applied even when -z
         * was explicit, since a ZG with no BGs is simply never useful,
         * not a legitimate trade-off like -b/-J's space-vs-control one. */
        fprintf(stderr,
                "note: -z %u exceeds what this device can back (%" PRIu64 " Block Group(s)); using -z %" PRIu64
                " instead\n",
                zg_count, B, B);
        zg_count = (u32) B;
    }

    const u64 bg_table_blk = B; /* one block per BG */
    const u64 consumed = total_blocks - waste;
    if (consumed > total_blocks)
        die("internal calc error: consumed > total");

    /* --- lay out absolute LBAs --- */
    const u64 sb_lba = CETRAFS_SB_BLOCK_NR;      /* 0 */
    const u64 zg_lba = sb_lba + sb_blocks;       /* 1 */
    const u64 bg_table_lba = zg_lba + zg_blocks; /* 1 + Z */
    const u64 i_bmap_lba = bg_table_lba + bg_table_blk;
    const u64 i_tbl_lba = i_bmap_lba + i_bmap_blk;
    const u64 node_tbl_lba = i_tbl_lba + i_tbl_blk;
    const u64 pending_lba = node_tbl_lba + node_tbl_blk;
    const u64 j_area_lba = pending_lba + pending_total_blk;
    const u64 bg_regions_lba = j_area_lba + j_total_blk;

    /* --- build superblock --- */
    cetrafs_superblock_t sb;
    memset(&sb, 0, sizeof(sb));

    sb.magic = cetrafs_cpu_to_le32(CETRAFS_MAGIC);
    sb.version = cetrafs_cpu_to_le16(CETRAFS_VERSION);
    sb.sb_bytes = cetrafs_cpu_to_le16(sizeof(sb));
    sb.block_size = cetrafs_cpu_to_le32(CETRAFS_BLOCK_SIZE);
    sb.pad0 = 0;
    sb.total_blocks = cetrafs_cpu_to_le64(total_blocks);

    sb.zone_group_count = cetrafs_cpu_to_le32(zg_count);
    sb.block_group_count = cetrafs_cpu_to_le32((u32) B); /* if >32-bit, revisit types */

    sb.zg_table_start = cetrafs_cpu_to_le64(zg_lba);
    sb.bg_table_start = cetrafs_cpu_to_le64(bg_table_lba);

    sb.inode_bmap_start = cetrafs_cpu_to_le64(i_bmap_lba);
    sb.inode_bmap_blocks = cetrafs_cpu_to_le64(i_bmap_blk);
    sb.inode_table_start = cetrafs_cpu_to_le64(i_tbl_lba);
    sb.inode_table_blocks = cetrafs_cpu_to_le64(i_tbl_blk);

    sb.node_table_start = cetrafs_cpu_to_le64(node_tbl_lba);
    sb.node_table_blocks = cetrafs_cpu_to_le64(node_tbl_blk);
    sb.node_table_count = cetrafs_cpu_to_le32((u32) node_table_count);
    sb.node_entry_size = cetrafs_cpu_to_le32(sizeof(cetrafs_node_entry_t));

    sb.pending_free_start = cetrafs_cpu_to_le64(pending_lba);
    sb.pending_free_blocks_per_zg = cetrafs_cpu_to_le32(pending_per_zg);

    sb.node_journal_start = cetrafs_cpu_to_le64(j_per_node_blk ? j_area_lba : 0);
    sb.node_journal_blocks = cetrafs_cpu_to_le32((u32) j_per_node_blk);

    sb.bg_regions_start = cetrafs_cpu_to_le64(bg_regions_lba);

    /* The Block Group table starts as ONE contiguous run -- the
     * implicit first segment of the chain (cetrafs_bg_segment_t).
     * Saying so explicitly rather than leaving it zero means a reader
     * never has to infer it from block_group_count, which stops being
     * the first segment's size the moment the volume is grown.
     * bg_table_next stays 0: nothing is appended yet. */
    sb.bg_table_first_count = cetrafs_cpu_to_le64(B);
    sb.bg_table_next = cetrafs_cpu_to_le64(0);

    sb.root_ino = cetrafs_cpu_to_le64(CETRAFS_ROOT_INO);
    sb.inode_size = cetrafs_cpu_to_le32(CETRAFS_INODE_ONDISK_SIZE);
    sb.inodes_count = cetrafs_cpu_to_le32(inodes_total);

    sb.bg_size_blocks = cetrafs_cpu_to_le64(bg_size_blocks);

    {
        u64 incompat =
            CETRAFS_FEAT_INCOMPAT_EXTENTS | CETRAFS_FEAT_INCOMPAT_GLOBAL_ITBL | CETRAFS_FEAT_INCOMPAT_NODE_REGISTRY;
        sb.features_incompat = cetrafs_cpu_to_le64(incompat);
    }


    /* SB checksum (CRC32C over full struct with checksum zeroed) */
    sb.checksum = 0;
    uint32_t sb_crc = crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum));
    sb.checksum = cetrafs_cpu_to_le64((u64) sb_crc);

    /* pad to a block */
    u8 *blk = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);
    memcpy(blk, &sb, sizeof(sb));
    write_block(fd, sb_lba, blk, !dry_run);

    /* --------------------------- */
    /* --- ZG table & journals --- */
    /* --------------------------- */

    /* precompute per-BG layout -- needed here too, to compute each ZG's
     * free_data_blocks aggregate before the BG table itself is written */
    u32 off_bmap32, off_data32;
    u64 data_cnt;
    cetrafs_calc_bg_layout(bg_size_blocks, &off_bmap32, &off_data32, &data_cnt);

    /* bg_owner_zg[b] records which ZG will claim BG b, for the BG table
     * loop below to stamp into bg.owner_zg.
     *
     * ROUND-ROBIN, not contiguous runs.
     *
     * A Zone Group no longer records which Block Groups belong to it --
     * each Block Group names its own owner -- so membership does not
     * have to be contiguous, and interleaving is the honest default: it
     * spreads capacity across every Zone Group instead of giving each
     * one a single run at one end of the device, which matters once
     * Block Groups can move between Zone Groups at runtime.
     * docs/internal/BG-OWNERSHIP-DESIGN.md
     *
     * BG 0 still falls to ZG 0 (0 % zg_count == 0), which the root
     * directory's one-block discount below depends on.
     */
    u32 *bg_owner_zg = (u32 *) xcalloc(B, sizeof(u32));

    for (u64 b = 0; b < B; ++b)
        bg_owner_zg[b] = (u32) (b % zg_count);

    for (u32 z = 0; z < zg_count; ++z) {
        cetrafs_zone_group_t zg;
        memset(&zg, 0, sizeof(zg));

        zg.zg_id = cetrafs_cpu_to_le16((u16) z);
        /* CETRAFS_NODE_ID_NONE, not 0 -- 0 is a valid Node Registry row
         * index and would misreport this ZG as already
         * claimed by that node. Real claiming happens at mount. */
        zg.owner_node_id = cetrafs_cpu_to_le16((u16) CETRAFS_NODE_ID_NONE);

        /* Count this Zone Group's members from the assignment above --
         * there is no span to read it off any more. */
        u64 cnt = 0;

        for (u64 b = 0; b < B; ++b)
            if (bg_owner_zg[b] == z)
                cnt++;

        /* free_data_blocks: sum of each member BG's usable data blocks.
         * BG 0 is owned by ZG 0 and holds the root directory's one
         * block, so ZG 0's aggregate is discounted by 1 -- mirrors the
         * same discount applied to BG 0's own free_data_blocks (see the
         * BG table loop). */
        u64 fdb = data_cnt * cnt;

        if (z == 0 && cnt > 0)
            fdb -= 1;
        zg.free_data_blocks = cetrafs_cpu_to_le64(fdb);


        /* v0x0008: two independently-checksummed halves (cetrafs.h) --
         * the HOT sector is the CAS unit, the COLD remainder is mkfs-time
         * geometry. Each checksum covers only its own half, with its own
         * field zeroed. */
        zg.hot_checksum = 0;
        zg.hot_checksum = cetrafs_cpu_to_le64((u64) crc32c_struct((const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                                                      offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF,
                                                      sizeof(zg.hot_checksum)));
        zg.cold_checksum = 0;
        zg.cold_checksum = cetrafs_cpu_to_le64((u64) crc32c_struct(
            (const u8 *) &zg + CETRAFS_ZG_COLD_OFF, CETRAFS_ZG_COLD_LEN,
            offsetof(cetrafs_zone_group_t, cold_checksum) - CETRAFS_ZG_COLD_OFF, sizeof(zg.cold_checksum)));

        memcpy(blk, &zg, sizeof(zg));
        write_block(fd, zg_lba + z, blk, !dry_run);
    }

    /* Zero the pending-free queues (empty = no entries) and the whole
     * per-node journal region. The journal region must be REALLY zeroed,
     * not assumed-zero: a device reused from a previous cetrafs mkfs can
     * still hold that volume's journal slots at these offsets, and a
     * stale entry carries a valid magic AND a valid checksum -- replay
     * would faithfully apply a previous filesystem's post-image over
     * this one's blocks. */
    zero_blocks(fd, pending_lba, pending_total_blk, !dry_run);
    if (j_total_blk)
        zero_blocks(fd, j_area_lba, j_total_blk, !dry_run);

    /* ------------------------------------- */
    /* --- BG table & BG headers/bitmaps --- */
    /* ------------------------------------- */

    u64 next_bg_start = bg_regions_lba;

    for (u64 b = 0; b < B; ++b) {
        /* BG descriptor */
        cetrafs_block_group_t bg;
        memset(&bg, 0, sizeof(bg));

        bg.bg_id = cetrafs_cpu_to_le32((u32) b);

        /* owner_zg: plain-native like the rest of this struct's non-SB/ZG
         * fields (see the checksum comment below); computed by the ZG
         * loop above into bg_owner_zg[]. */
        bg.owner_zg = cetrafs_cpu_to_le16((u16) bg_owner_zg[b]);

        bg.start_block = cetrafs_cpu_to_le64(next_bg_start);
        bg.length_blocks = cetrafs_cpu_to_le64(bg_size_blocks);

        bg.off_bg_header = cetrafs_cpu_to_le32(0);
        bg.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
        bg.off_data_region = cetrafs_cpu_to_le32(off_data32);

        bg.data_block_count = cetrafs_cpu_to_le64(data_cnt);
        /* BG 0 always hosts the root directory's one data block (set
         * below, after this loop) -- discount it here so the cached
         * counter the kernel now trusts starts
         * correct instead of 1 too high. */
        bg.free_data_blocks = cetrafs_cpu_to_le64(b == 0 ? data_cnt - 1 : data_cnt);

        /* BG descriptor fields are stored plain-native (unlike SB/ZG's
         * __le*), matching fsck.c's read-side precedent -- so the
         * checksum itself is stored plain too, not cetrafs_cpu_to_le64()'d. */
        bg.checksum = 0;
        bg.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum), sizeof(cetrafs_le64(bg.checksum))));

        memcpy(blk, &bg, sizeof(bg));
        write_block(fd, bg_table_lba + b, blk, !dry_run);

        /* BG header at region start */
        cetrafs_bg_header_t bh;
        memset(&bh, 0, sizeof(bh));

        bh.bg_id = cetrafs_cpu_to_le32((u32) b);

        bh.owner_zg = bg.owner_zg;
        bh.flags = cetrafs_cpu_to_le16(0);

        bh.length_blocks = cetrafs_cpu_to_le64(bg_size_blocks);
        bh.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
        bh.off_data_region = cetrafs_cpu_to_le32(off_data32);
        bh.data_block_count = cetrafs_cpu_to_le64(data_cnt);

        /* plain-native, like the BG descriptor's checksum above */
        bh.checksum = 0;
        bh.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bh, sizeof(bh), offsetof(cetrafs_bg_header_t, checksum), sizeof(cetrafs_le64(bh.checksum))));

        memcpy(blk, &bh, sizeof(bh));
        write_block(fd, next_bg_start + 0, blk, !dry_run);

        /* Zero the data bitmap blocks */
        {
            u64 dbm_blocks = cetrafs_calc_bg_dbm_blocks(bg_size_blocks);
            zero_blocks(fd, next_bg_start + off_bmap32, dbm_blocks, !dry_run);
        }

        next_bg_start += bg_size_blocks;
    }

    free(bg_owner_zg);

    /* ----------------------------------- */
    /* --- Global inode bitmap & table --- */
    /* ----------------------------------- */

    /* zero them */
    zero_blocks(fd, i_bmap_lba, i_bmap_blk, !dry_run);
    zero_blocks(fd, i_tbl_lba, i_tbl_blk, !dry_run);

    /* ----------------------- */
    /* --- Node Registry  --- */
    /* ----------------------- */

    /* All-zero means every entry is CETRAFS_NODE_STATE_FREE (0) -- no
     * nodes are registered by mkfs; that happens at mount time. */
    zero_blocks(fd, node_tbl_lba, node_tbl_blk, !dry_run);

    /* set root inode in bitmap */
    {
        u64 root_idx = CETRAFS_ROOT_INO; /* assuming 1-based; place bit 1 */

        if (root_idx == 0 || root_idx > inodes_total)
            die("root ino out of range");

        /* Convert to 0-based for bitmap */
        u64 bit = root_idx - 1;

        /* modify target bitmap block */
        u64 bm_block_off = (bit / CETRAFS_BITS_PER_BLOCK);

        u8 *bmblk = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);

        off_t off = (off_t) (i_bmap_lba + bm_block_off) * CETRAFS_BLOCK_SIZE;
        /* Read-modify-write: a failed read would leave the zeroed buffer
         * and the write-back below would clear every other bit in this
         * block. The area is zero-filled by now, so the read is only
         * confirming that -- but an unchecked RMW is not something to
         * leave in a tool that formats devices. */
        if (!dry_run && pread(fd, bmblk, CETRAFS_BLOCK_SIZE, off) != (ssize_t) CETRAFS_BLOCK_SIZE)
            die("inode bitmap read at %lld failed: %s", (long long) off, strerror(errno));
        bmap_set_bit(bmblk, bit % CETRAFS_BITS_PER_BLOCK);
        write_block(fd, (i_bmap_lba + bm_block_off), bmblk, !dry_run);

        free(bmblk);
    }

    /* ------------------------------------------- */
    /* --- Create root directory block in BG 0 --- */
    /* ------------------------------------------- */
    u64 root_bg_start = bg_regions_lba;
    u64 root_data_lba = root_bg_start + off_data32; /* first data block of BG 0 */

    /* Set bit 0 in BG0 data bitmap */
    {
        u64 dbm0_lba = root_bg_start + off_bmap32;

        u8 *bm = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);
        if (!dry_run &&
            pread(fd, bm, CETRAFS_BLOCK_SIZE, (off_t) dbm0_lba * CETRAFS_BLOCK_SIZE) !=
                (ssize_t) CETRAFS_BLOCK_SIZE)
            die("BG 0 data bitmap read at block %llu failed: %s", (unsigned long long) dbm0_lba,
                strerror(errno));
        bmap_set_bit(bm, 0); /* first data block */

        write_block(fd, dbm0_lba, bm, !dry_run);

        free(bm);
    }

    /* Write directory block with '.' and '..' */
    {
        u8 *dirblk = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);

        cetrafs_dirent_t *d = (cetrafs_dirent_t *) dirblk;

        /* '.' */
        d[0].inode = cetrafs_cpu_to_le64(CETRAFS_ROOT_INO);
        d[0].file_type = CETRAFS_FT_DIR;
        d[0].name_len = cetrafs_cpu_to_le16(1);
        strncpy(d[0].name, ".", CETRAFS_FILENAME_MAX);

        /* '..' */
        d[1].inode = cetrafs_cpu_to_le64(CETRAFS_ROOT_INO);
        d[1].file_type = CETRAFS_FT_DIR;
        d[1].name_len = cetrafs_cpu_to_le16(2);
        strncpy(d[1].name, "..", CETRAFS_FILENAME_MAX);

        /* Dirent-block tail checksum (v0x0007) -- the
         * kernel stamps/verifies this on every dirent block it touches;
         * mkfs must stamp the one dirent block it creates itself. */
        {
            cetrafs_dirent_tail_t *tail = (cetrafs_dirent_tail_t *) (dirblk + CETRAFS_DIRENT_TAIL_OFF);

            tail->magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
            tail->crc = cetrafs_cpu_to_le32(crc32c_update(0, dirblk, CETRAFS_DIRENT_TAIL_OFF));
        }

        write_block(fd, root_data_lba, dirblk, !dry_run);
        free(dirblk);
    }

    /* ------------------ */
    /* --- Root inode --- */
    /* ------------------ */

    cetrafs_inode_t ri;
    memset(&ri, 0, sizeof(ri));

    ri.ino = cetrafs_cpu_to_le64(CETRAFS_ROOT_INO);
    ri.mode = cetrafs_cpu_to_le32(S_IFDIR | 0755);
    ri.uid = 0;
    ri.gid = 0;
    ri.nlink = cetrafs_cpu_to_le32(2);
    ri.size = cetrafs_cpu_to_le64(sizeof(cetrafs_dirent_t) * 2);
    ri.generation = cetrafs_cpu_to_le64(1);                       /* v0x0008: nonzero; ino 1 (root) is never reused anyway */
    ri.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE); /* v0x000A: unlocked (0 would mean node 0) */
    ri.blocks = cetrafs_cpu_to_le64(CETRAFS_BLOCK_SIZE / 512);
    ri.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);

    /* inline extent header + single extent to root_data_lba */
    ri.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    ri.eh.eh_entries = cetrafs_cpu_to_le16(1);
    ri.eh.eh_max = cetrafs_cpu_to_le16(4);   /* inline capacity */
    ri.eh.eh_depth = 0; /* leaf */
    ri.eh.eh_generation = 0;
    ri.et.leaf[0].ee_block = 0; /* logical block 0 */
    ri.et.leaf[0].ee_len = cetrafs_extent_pack_len(1, 0);
    {
        __le16 _hi;
        __le32 _lo;
        cetrafs_extent_phys_to_hilo(root_data_lba, &_hi, &_lo);
        ri.et.leaf[0].ee_start_hi = _hi;
        ri.et.leaf[0].ee_start_lo = _lo;
    }

    /* v0x0005 two-sector record: identity echoes + per-sector CRCs
     * (plain-native, like the BG descriptor/header checksums above). */
    cetrafs_inode_stamp_crcs_us(&ri);

    /* write inode into its own whole block at slot (ino-1) -- one record
     * per block as of v0x0007 */
    off_t ino_off = (off_t) (i_tbl_lba + (CETRAFS_ROOT_INO - 1)) * CETRAFS_BLOCK_SIZE;
    if (!dry_run)
        pwrite_all(fd, &ri, sizeof(ri), ino_off);

    if (!dry_run) {
        fsync(fd);
    }
    close(fd);

    /* --- summary --- */
    fprintf(stdout,
            "cetrafs mkfs %s\n"
            "  device bytes: %llu\n"
            "  filesystem bytes: %llu (blocks=%" PRIu64
            ")\n"
            "  ZGs: %u, BGs: %" PRIu64 ", BG size: %" PRIu64
            " blocks (%llu MiB)\n"
            "  inode_bmap: LBA %" PRIu64 "+%" PRIu64 ", inode_table: LBA %" PRIu64 "+%" PRIu64
            "\n"
            "  node_table: LBA %" PRIu64 "+%" PRIu64 " (capacity %" PRIu64
            " nodes)\n"
            "  pending-free queues: LBA %" PRIu64 "+%" PRIu64
            " (per-ZG %u blocks)\n"
            "  journals: LBA %" PRIu64 "+%" PRIu64 " (per-NODE %" PRIu64
            " blocks)\n"
            "  BG table: LBA %" PRIu64 "+%" PRIu64
            "\n"
            "  BG regions start: LBA %" PRIu64
            "\n"
            "  ZG<->BG ownership: round-robin, %" PRIu64 "-%" PRIu64
            " BG per ZG\n"
            "  SB CRC32C: 0x%08X\n",
            dry_run ? "(DRY-RUN)" : "completed", dev_bytes, (unsigned long long) fs_size_bytes,
            (uint64_t) total_blocks, zg_count, (uint64_t) B,
            (uint64_t) bg_size_blocks, (unsigned long long) (bg_size_blocks * CETRAFS_BLOCK_SIZE / 1024 / 1024),
            (uint64_t) i_bmap_lba, (uint64_t) i_bmap_blk, (uint64_t) i_tbl_lba, (uint64_t) i_tbl_blk,
            (uint64_t) node_tbl_lba, (uint64_t) node_tbl_blk, (uint64_t) node_table_count, (uint64_t) pending_lba,
            (uint64_t) pending_total_blk, (unsigned) pending_per_zg, (uint64_t) j_area_lba,
            (uint64_t) j_total_blk, (uint64_t) j_per_node_blk, (uint64_t) bg_table_lba, (uint64_t) bg_table_blk,
            (uint64_t) bg_regions_lba, (uint64_t) (B / zg_count), (uint64_t) ((B + zg_count - 1) / zg_count),
            sb_crc);

    return 0;
}
