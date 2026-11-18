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
#include <signal.h>
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
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0)
            die("pwrite failed: %s", strerror(errno));
        /* pwrite(2) returning 0 for a nonzero count means it is making
         * no progress -- retrying it is an infinite loop, not patience. */
        if (w == 0)
            die("pwrite wrote nothing at offset %lld with %zu bytes left", (long long) off, len);
        p += (size_t) w;
        off += (off_t) w;
        len -= (size_t) w;
    }
}

static void write_block(int fd, u64 block_num, const void *data, bool do_write)
{
    if (!do_write)
        return;
    /* While mkfs holds a registry claim (formatting over an old volume):
     * its row taken, a node beating, or its own renewal stalled past the
     * lease -- stop before writing more (devutil.h). */
    if (cetrafs_repair_write_gate())
        die("%s -- stopping before writing more",
            cetrafs_repair_lost == 2   ? "a node is mounted on this volume while it is being formatted"
            : cetrafs_repair_lost == 3 ? "mkfs's registry claim was not renewed in time (a node may call it dead)"
                                       : "mkfs's registry claim was taken away");
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

    /* check block 0 for our magic. A read that fails is not an empty
     * device: it is one we cannot see, and this check is what stands
     * between -f-less mkfs and an existing volume.
     *
     * Read past this machine's cache: a shared LUN is not coherent
     * through it, and a block 0 cached while the LUN was blank would read
     * "empty" over a volume a peer has formatted and mounted since
     * (audit 2026-11-11 M2). */
    (void) posix_fadvise(fd, 0, (off_t) blocks_to_scan * CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED);
    if (pread(fd, buf, CETRAFS_BLOCK_SIZE, 0) != (ssize_t) CETRAFS_BLOCK_SIZE) {
        free(buf);
        return true; /* conservative */
    }
    {
        /* The magic is __le32 on the device. Reading it in NATIVE byte
         * order compares the wrong number on a big-endian host, where
         * an existing cetrafs volume would read as empty and this
         * refusal -- the one thing standing between an operator and a
         * reformat of a live LUN -- would not fire. The whole format is
         * __le* and `make endian-check` guards it; this peek predated
         * the rule. memcpy, also, because the buffer is not guaranteed
         * to be u32-aligned. */
        __le32 mg_raw;
        u32 mg;

        memcpy(&mg_raw, buf, sizeof(mg_raw));
        mg = cetrafs_le32(mg_raw);
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
        ssize_t got = pread(fd, buf, CETRAFS_BLOCK_SIZE, (off_t) b * CETRAFS_BLOCK_SIZE);

        if (got < 0) {
            free(buf);
            return true; /* an I/O error: cannot tell, so not "empty" */
        }
        if (got != (ssize_t) CETRAFS_BLOCK_SIZE)
            break; /* the end of a small device */
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
            "       [-A KiB] [-s size] [-n] [-f]\n"
            "  -z: number of Zone Groups (1..%u), default the larger of 16 and -M\n"
            "      -- one per node that may ever write (clamped down to\n"
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
            "  -A: data alignment in KiB (default 1024): every Block Group and its\n"
            "      data region start on a multiple of it -- the array's allocation\n"
            "      unit (UNMAP granularity) or stripe. A power of two, 4..65536,\n"
            "      dividing the Block Group size; 4 is no alignment\n"
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
/* strtol with nothing checked accepts "-z 5x" as 5: the trailing
 * garbage is simply dropped, and an operator who mistyped a geometry
 * gets a volume built to something they did not ask for. -s has always
 * parsed strictly (it has to, for its suffixes); the plain integers
 * did not. */
static long long parse_int_arg(const char *arg, const char *what)
{
    char *end = NULL;
    long long v;

    errno = 0;
    v = strtoll(arg, &end, 10);
    if (errno || end == arg || *end != '\0')
        die_arg("%s: not a whole number: %s", what, arg);
    return v;
}

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
/*
 * Look for anyone still using an existing cetrafs volume, and make it
 * unmountable, BEFORE anything is written over it.
 *
 * The claim is the repair claim fsck -r and growfs take: a REPAIR row in
 * the Node Registry, renewed on a timer, which fill_super() refuses to
 * mount past and every other tool waits for. Taken FIRST, then the probe
 * for a live node runs under it -- check-then-claim leaves the gap
 * between them open, and a node mounting inside it would be let in.
 *
 * Block 0 stays untouched until the verdict is "format". It used to be
 * zeroed as the claim, before a probe that can last minutes, with the
 * old superblock saved to a file on this host: a SIGKILL, an OOM kill, a
 * provisioning timeout or a host crash in that window left a running
 * cluster with no superblock -- unmountable on every node, the only copy
 * in a temp file on the machine that died (audit 2026-11-14 A-8; the
 * older M1 wrapped the same window in held signals and that copy). Now a
 * killed mkfs leaves the superblock where it was and a REPAIR claim that
 * stops renewing, which mounts and tools judge dead after their probe
 * window and reap.
 *
 * A mount that read the old superblock before the format and registers
 * after it re-reads block 0 once its row is committed, and refuses.
 */
/*
 * A superblock that does not verify can still be a live cluster's: a
 * stray write into block 0 (audit 2026-11-15 A-7) breaks its checksum
 * and nothing else, and its nodes, which read it at mount, keep running
 * and beating. Formatting it on "no node can mount it" alone destroyed
 * that cluster (B-16). The registry is wherever the damaged superblock
 * still places it, if that is inside the device; every row carries its
 * own magic and checksum, so a row that verifies and beats is a live
 * node wherever it is found. Watch it there, read-only -- no claim can be
 * written to a place nothing proves -- and refuse on a beat or on an I/O
 * error. A placement outside the device locates nothing: format.
 *
 * TEST ONLY: CETRAFS_TEST_UNVERIFIED_NO_PROBE=1 skips it (the control of
 * tests/kernel/mkfs_damaged_sb_live.sh).
 */
static void mkfs_probe_unverified(int fd, const char *dev, const cetrafs_superblock_t *sb)
{
    unsigned long long dev_bytes = 0;
    uint64_t start = cetrafs_le64(sb->node_table_start), nblk = cetrafs_le64(sb->node_table_blocks);
    uint32_t count = cetrafs_le32(sb->node_table_count), row = 0;
    char label[CETRAFS_NODE_LABEL_LEN + 1] = {0};
    long long age = 0;
    struct stat st;
    int lp;

    if (cetrafs_test_env_ll("CETRAFS_TEST_UNVERIFIED_NO_PROBE", 0, 1, 0))
        return;
    if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0) {
        if (fstat(fd, &st) < 0)
            die_dev("%s: cannot size the device: %s", dev, strerror(errno));
        dev_bytes = (unsigned long long) st.st_size;
    }
    if (!start || !count || count > nblk || nblk > dev_bytes / CETRAFS_BLOCK_SIZE ||
        start > dev_bytes / CETRAFS_BLOCK_SIZE - nblk)
        return; /* places no registry on this device */
    lp = cetrafs_find_live_peer_on(fd, dev, sb, &row, label, sizeof(label), &age);
    if (lp < 0)
        die_dev("%s: its old superblock does not verify, and the Node Registry it places cannot be read\n"
                "       (I/O error) -- so it is impossible to prove no node still runs on it. Nothing was\n"
                "       written. Fix the device and retry.",
                dev);
    if (lp)
        die_dev("%s: its old superblock does not verify, but a node is still heartbeating in its registry\n"
                "       (row %u%s%s) -- this is a live cluster's volume with a damaged block 0, and\n"
                "       formatting it would destroy it. Nothing was written. Unmount it everywhere first.",
                dev, row, label[0] ? ", " : "", label[0] ? label : "");
}

/*
 * The copy of block 0 at CETRAFS_SB_REPLICA_NR (A-7), read past this
 * machine's cache. 1 when it holds a superblock that verifies. With
 * block 0 overwritten this is what still places the volume's registry:
 * mkfs used to search the first GiB for blocks that looked like
 * registry rows instead (B-16).
 */
static int mkfs_read_sb_copy(int fd, cetrafs_superblock_t *out)
{
    unsigned char blk[CETRAFS_BLOCK_SIZE];
    const off_t at = (off_t) CETRAFS_SB_REPLICA_NR * CETRAFS_BLOCK_SIZE;

    (void) posix_fadvise(fd, at, CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED);
    if (pread(fd, blk, sizeof(blk), at) != (ssize_t) sizeof(blk))
        return 0;
    memcpy(out, blk, sizeof(*out));
    return cetrafs_le32(out->magic) == (uint32_t) CETRAFS_MAGIC &&
           (uint32_t) cetrafs_le64(out->checksum) ==
               crc32c_struct(out, sizeof(*out), offsetof(cetrafs_superblock_t, checksum), sizeof(out->checksum));
}

/*
 * A GPT keeps a backup of its header and entries in the LAST 33 sectors
 * of the disk. Formatting overwrites the primary copy (blocks 0..4) and
 * left the backup, and the kernel or a partitioning tool that finds a
 * valid backup with a damaged primary offers to "repair" the table --
 * writing it back over block 0, the superblock (audit 2026-11-14 M-34).
 * Cleared only where a header is actually there: the tail of a volume
 * formatted smaller than its LUN (-s) is otherwise left as it was.
 */
#define MKFS_GPT_TAIL_SECTORS 34
static void mkfs_wipe_backup_gpt(int fd, const char *dev)
{
    unsigned long long dev_bytes = 0;
    unsigned char sec[512], zero[MKFS_GPT_TAIL_SECTORS * 512];
    struct stat st;

    if (getenv("CETRAFS_TEST_MKFS_KEEP_GPT")) /* TEST ONLY: the control of mkfs_backup_gpt.sh */
        return;
    if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0) {
        if (fstat(fd, &st) != 0)
            return;
        dev_bytes = (unsigned long long) st.st_size;
    }
    if (dev_bytes < sizeof(zero))
        return;
    (void) posix_fadvise(fd, (off_t) (dev_bytes - sizeof(zero)), sizeof(zero), POSIX_FADV_DONTNEED);
    if (pread(fd, sec, sizeof(sec), (off_t) (dev_bytes - sizeof(sec))) != (ssize_t) sizeof(sec))
        return;
    if (memcmp(sec, "EFI PART", 8) != 0)
        return;
    memset(zero, 0, sizeof(zero));
    if (pwrite(fd, zero, sizeof(zero), (off_t) (dev_bytes - sizeof(zero))) != (ssize_t) sizeof(zero) || fsync(fd) != 0)
        die_dev("%s: cannot clear the backup partition table at the end of the device: %s", dev, strerror(errno));
    fprintf(stderr, "%s: cleared a backup GPT at the end of the device, so no tool restores it over the "
                    "superblock\n",
            dev);
}

static void mkfs_retire_old_superblock(int fd, const char *dev)
{
    unsigned char old[CETRAFS_BLOCK_SIZE], zero[CETRAFS_BLOCK_SIZE];
    cetrafs_superblock_t sb;
    char label[CETRAFS_NODE_LABEL_LEN + 1] = {0};
    long long age = 0;
    uint32_t row = 0;
    int lp, rc, claim;

    /* Past this machine's cache, as every other reader of a shared LUN
     * (M2): a cached "not cetrafs" skipped the probe below entirely. */
    (void) posix_fadvise(fd, 0, CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED);
    if (pread(fd, old, sizeof(old), 0) != (ssize_t) sizeof(old))
        die_dev("%s: cannot read block 0: %s", dev, strerror(errno));
    memcpy(&sb, old, sizeof(sb));
    memset(zero, 0, sizeof(zero));
    if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC) {
        /*
         * No superblock -- but maybe a live cluster's volume whose block
         * 0 took a stray write (B-16). Its copy places the registry: if
         * it verifies, the volume is probed through it exactly as through
         * block 0. With neither, no node can be mounting it (a mount
         * needs block 0, and the copy was written before any block 0).
         */
        if (getenv("CETRAFS_TEST_MKFS_NO_SB_COPY_PROBE") || /* TEST ONLY: the control of mkfs_block0_wiped_live.sh */
            !mkfs_read_sb_copy(fd, &sb) || !cetrafs_node_table_placed_ok(fd, &sb)) {
            if (pwrite(fd, zero, sizeof(zero), 0) != (ssize_t) sizeof(zero) || fsync(fd) != 0)
                die_dev("%s: cannot clear the old superblock: %s", dev, strerror(errno));
            return;
        }
        fprintf(stderr, "%s: block 0 holds no cetrafs superblock, but its copy at block %llu does -- checking\n"
                        "       the registry it places for a node still using this volume\n",
                dev, (unsigned long long) CETRAFS_SB_REPLICA_NR);
        goto probe;
    }

    /*
     * A superblock that does not verify -- its checksum, or a layout the
     * device cannot hold -- places its Node Registry nowhere provable,
     * so no claim can be written there and no probe can read there
     * (cetrafs_node_table_placed_ok()). No node can mount it either:
     * the mount refuses the same superblock. Formatting it is what -f
     * is for; refusing left a damaged volume impossible to reformat
     * (8c19f12). Read a few times first, apart: a peer's growfs publish
     * of block 0 seen torn verifies on a later read, and then this is a
     * live volume and the probe below runs.
     */
    for (int tries = 0; tries < 5 && !cetrafs_node_table_placed_ok(fd, &sb); tries++) {
        if (tries == 4) {
            mkfs_probe_unverified(fd, dev, &sb);
            fprintf(stderr, "%s: its old superblock does not verify and no node beats in a registry it places\n"
                            "       -- no node can mount it; formatting over it (-f)\n",
                    dev);
            if (pwrite(fd, zero, sizeof(zero), 0) != (ssize_t) sizeof(zero) || fsync(fd) != 0)
                die_dev("%s: cannot clear the old superblock: %s", dev, strerror(errno));
            return;
        }
        usleep(200000);
        (void) posix_fadvise(fd, 0, CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED);
        if (pread(fd, old, sizeof(old), 0) != (ssize_t) sizeof(old))
            die_dev("%s: cannot read block 0: %s", dev, strerror(errno));
        memcpy(&sb, old, sizeof(sb));
        if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC)
            break; /* rewritten meanwhile: judged again below */
    }
    if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC)
        die_dev("%s: its superblock changed while mkfs read it -- nothing was written; run it again", dev);

probe:
    rc = cetrafs_find_repair_claim(fd, &sb, &row, label, sizeof(label));
    if (rc < 0)
        die_dev("%s: cannot read its Node Registry (I/O error) -- so it is impossible to\n"
                "       prove no other node has this volume mounted, and formatting on a guess\n"
                "       destroys a live cluster's volume. Fix the device and retry.",
                dev);
    if (rc)
        die_dev("%s is being repaired (%s, registry row %u) -- wait for it to finish", dev,
                label[0] ? label : "an offline tool", row);
    claim = cetrafs_repair_claim(fd, &sb, "mkfs");
    if (claim == -2)
        die_dev("%s: another tool claimed this volume at the same time -- nothing was written", dev);
    if (claim == -3)
        die_dev("%s: its superblock changed while mkfs claimed it -- nothing was written; run it again", dev);
    if (claim < 0)
        die_dev("%s: no free Node Registry row to claim while checking no node uses it -- nothing was\n"
                "       written. Unmount it everywhere (or run fsck -r to retire dead rows) and retry.",
                dev);

    /* Under the claim: no mount can start, a live one shows up beating. */
    lp = cetrafs_find_live_peer_on(fd, dev, &sb, &row, label, sizeof(label), &age);
    if (!lp && !cetrafs_repair_lost) {
        /* The verdict: formatting. Block 0 first, while the claim still
         * stands; the renewals stop only after, and the format rewrites
         * the registry they were writing to. */
        if (pwrite(fd, zero, sizeof(zero), 0) != (ssize_t) sizeof(zero) || fsync(fd) != 0) {
            cetrafs_repair_release(fd, &sb, (uint32_t) claim);
            die_dev("%s: cannot clear the old superblock: %s", dev, strerror(errno));
        }
        cetrafs_repair_timer(fd, &sb, (uint32_t) claim, 0);
        return;
    }
    cetrafs_repair_release(fd, &sb, (uint32_t) claim);
    if (lp < 0)
        die_dev("%s: cannot read its Node Registry (I/O error) -- so it is impossible to\n"
                "       prove no other node has this volume mounted, and formatting on a guess\n"
                "       destroys a live cluster's volume. Fix the device and retry.",
                dev);
    if (!lp)
        die_dev("%s: a node started beating in its registry while mkfs checked it -- nothing was\n"
                "       written. Unmount it everywhere, then retry.",
                dev);
    die_dev("%s is mounted by another node (registry row %u%s%s) -- it is still heartbeating\n"
            "       -- formatting it now would destroy a live cluster's volume. Nothing was written.\n"
            "       Unmount it there, then retry. (row's own last_seen reads %llds ago by this\n"
            "       machine's clock, which means nothing if the two disagree.)",
            dev, row, label[0] ? ", " : "", label[0] ? label : "", age);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage(argv[0]);
        return 2; /* usage, as fsck.cetra and defrag.cetra also use */
    }

    const char *dev = argv[1];

    /* The device comes first and options follow; "mkfs.cetra -f /dev/x"
     * used to open "-f" (audit 2026-11-14 M-35). */
    if (dev[0] == '-')
        die_arg("the device comes first: %s <device> [options] (got '%s' where the device goes)", argv[0], dev);

    u32 zg_count = 16;                                 /* default: see zg_explicit */
    bool zg_explicit = false;
    u64 bg_size_bytes = CETRAFS_DEFAULT_BG_SIZE_BYTES; /* default 1 GiB */
    u64 inodes_total = 0;                              /* 0 => derive */
    u64 j_per_node_bytes = 2ULL * 1024 * 1024;         /* 2 MiB per node slot */
    u64 node_table_count = 64;                         /* default cluster-size cap */
    u64 align_blocks = CETRAFS_DATA_ALIGN_DEFAULT_BLOCKS; /* -A, in blocks */
    bool dry_run = false;
    bool force = false;
    bool bg_size_explicit = false;
    bool j_explicit = false;
    u64 fs_bytes = 0; /* -s: format only this much of the device (0 => all) */

    int opt;
    while ((opt = getopt(argc - 1, argv + 1, "z:b:N:J:M:A:s:nf")) != -1) {
        switch (opt) {
        case 'z': {
            /* long long, as parse_int_arg returns: a 32-bit long cut
             * "4294967297" down to 1 and accepted it (audit 2026-11-14 U11). */
            long long v = parse_int_arg(optarg, "-z");
            if (v < 1 || v > (long long) CETRAFS_MAX_ZONE_GROUPS)
                die_arg("-z out of range");
            zg_count = (u32) v;
            zg_explicit = true;
            break;
        }
        case 'b': {
            long long mib = parse_int_arg(optarg, "-b/-J");
            if (mib < 512)
                die_arg("-b too small (min 512 MiB)");
            /*
             * Bounded ABOVE by what the kernel can INDEX, not by what
             * the arithmetic survives. A Block Group's blocks are
             * tracked in core by the kernel's bitmap API, whose indices
             * are `unsigned int`; past CETRAFS_MAX_BG_SIZE_BLOCKS the
             * scrub's reference set truncated the offset and marked the
             * wrong blocks as referenced, which makes it free live
             * ones. The old ceiling was 1 PiB per group -- 2^38 blocks,
             * 64 times past the point the index stops meaning anything.
             */
            /* Compared in MiB, the unit the value ARRIVED in. The
             * first version of this cap multiplied up to bytes first --
             * and `-b 1125899906842624` makes that product 2^70, which
             * wraps u64 to exactly 0, sails under the ceiling and
             * through the 4KiB-multiple test below, leaving bg_size 0
             * to feed every geometry computation. The bound a wrap can
             * slip past is not a bound. */
            if (mib > (long long) (CETRAFS_MAX_BG_SIZE_BLOCKS * (u64) CETRAFS_BLOCK_SIZE / (1024ULL * 1024ULL)))
                die_arg("-b too large (max %llu MiB -- a Block Group's blocks must be indexable)",
                        (unsigned long long) (CETRAFS_MAX_BG_SIZE_BLOCKS * (u64) CETRAFS_BLOCK_SIZE / (1024ULL * 1024ULL)));
            bg_size_bytes = (u64) mib * 1024ULL * 1024ULL;
            if (bg_size_bytes % CETRAFS_BLOCK_SIZE)
                die_arg("-b must be multiple of 4KiB");
            bg_size_explicit = true;
            break;
        }
        case 'N': {
            long long nin = parse_int_arg(optarg, "-N");
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
            long long mib = parse_int_arg(optarg, "-b/-J");
            if (mib < 0)
                die_arg("-J invalid");
            /* Same overflow bound as -b; a journal slice has no business
             * anywhere near it either. */
            if (mib > (long long) CETRAFS_JOURNAL_MAX_BLOCKS / (1024 * 1024 / CETRAFS_BLOCK_SIZE))
                die_arg("-J too large (max 16384 MiB per node)");
            j_per_node_bytes = (u64) mib * 1024ULL * 1024ULL;
            if (j_per_node_bytes % CETRAFS_BLOCK_SIZE)
                die_arg("-J must be multiple of 4KiB");
            j_explicit = true;
            break;
        }
        case 'M': {
            long long m = parse_int_arg(optarg, "-M");
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
        case 'A': {
            long long kib = parse_int_arg(optarg, "-A");
            /* Bounded in the unit it arrived in, before any multiply. */
            if (kib < CETRAFS_BLOCK_SIZE / 1024 || kib > (long long) (CETRAFS_DATA_ALIGN_MAX_BLOCKS * CETRAFS_BLOCK_SIZE / 1024) ||
                (kib & (kib - 1)))
                die_arg("-A must be a power of two from %u to %llu KiB", CETRAFS_BLOCK_SIZE / 1024,
                        (unsigned long long) (CETRAFS_DATA_ALIGN_MAX_BLOCKS * CETRAFS_BLOCK_SIZE / 1024));
            align_blocks = (u64) kib * 1024 / CETRAFS_BLOCK_SIZE;
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
    /* Anything left is not an option: "mkfs.cetra /dev/x 8T" formatted
     * the whole LUN and dropped the 8T (M-35). The size is -s. */
    if (optind < argc - 1)
        die_arg("unexpected argument '%s' (a size is given with -s)", argv[1 + optind]);

    /* Default: one Zone Group per node that may ever write (A-13). */
    if (!zg_explicit)
        zg_count = (u32) (node_table_count > 16 ? (node_table_count < CETRAFS_MAX_ZONE_GROUPS ? node_table_count
                                                                                           : CETRAFS_MAX_ZONE_GROUPS)
                                                : 16);

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
     * stale window is the escape hatch if it really is gone.
     *
     * A real run does this AFTER block 0 is zeroed, just before the
     * first structural write (mkfs_retire_old_superblock()): probing
     * here left the gap between the verdict and the act open. A dry run writes
     * nothing, so it probes here. */
    if (dry_run) {
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
        cetrafs_superblock_t copy;
        /* Blocks 1..2047 of a cetrafs volume are empty (A-7): with block
         * 0 overwritten by zeros the first MiB reads empty, and only the
         * copy says what this is. */
        bool has_copy = mkfs_read_sb_copy(fd, &copy);
        bool nonempty = has_copy || is_device_nonempty(fd, 256 /* ~1MB */, &mg);
        if (nonempty) {
            if (mg != CETRAFS_MAGIC && has_copy)
                die("Refusing to format: this is a cetrafs volume whose block 0 was overwritten -- its copy\n"
                    "       at block %llu is intact, and fsck.cetra -r restores block 0 from it. Use -f only to\n"
                    "       destroy it; -f still refuses a volume a node is heartbeating on.",
                    (unsigned long long) CETRAFS_SB_REPLICA_NR);
            if (mg == CETRAFS_MAGIC)
                die("Refusing to overwrite existing cetrafs (use -f)");
            else
                die("Refusing to format a non-empty device: it holds data -- a partition table, another\n"
                    "       filesystem, or a cetrafs volume whose block 0 was overwritten. Check it (lsblk -f,\n"
                    "       blkid) before using -f; -f still refuses a volume a node is heartbeating on.");
        }
    }

    /* --- compute metadata footprint, auto-tune J/B, and solve B --- */
    const u64 sb_blocks = CETRAFS_SB_AREA_BLOCKS; /* block 0, the gap, the copy (A-7) */
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
     * ~5% of the device. A per-node area smaller than the format's
     * minimum (CETRAFS_JOURNAL_MIN_BLOCKS) refuses multi-block
     * boundaries, so it is "journaling disabled", said so, rather than a
     * journal that fails every fsync needing two blocks (M-24). */
    u64 j_per_node_blk = j_per_node_bytes / CETRAFS_BLOCK_SIZE;

    if (!j_explicit) {
        u64 cap_per_node_blk = (total_blocks / 20) / node_table_count;

        if (cap_per_node_blk < j_per_node_blk)
            j_per_node_blk = cap_per_node_blk;
    }
    if (j_per_node_blk > 0 && j_per_node_blk < CETRAFS_JOURNAL_MIN_BLOCKS) {
        if (j_explicit)
            die("-J too small: a journal needs at least %u blocks per node", CETRAFS_JOURNAL_MIN_BLOCKS);
        fprintf(stderr,
                "mkfs: %" PRIu64 " node slots leave %" PRIu64 " journal blocks per node, under the %u a journal "
                "needs -- formatting with no journal (a smaller -M, or an explicit -J, keeps one)\n",
                (uint64_t) node_table_count, (uint64_t) j_per_node_blk, CETRAFS_JOURNAL_MIN_BLOCKS);
        j_per_node_blk = 0;
    }

    const u64 j_total_blk = j_per_node_blk * node_table_count;

    /* zg_count feeds the footprint below (one ZG-table block and one
     * pending-free-queue reservation per ZG), which is itself one input
     * to solving B -- so a Zone Group count larger than the Block Group
     * count the device can actually back can't be caught until B comes
     * out of this very computation. So it iterates until B backs every
     * Zone Group. This used to stop after two passes on the argument
     * that a shrunk zg_count only frees room for B -- but the smaller
     * footprint can also flip the auto-tuned BG size back to 1 GiB, and
     * a larger BG size means FEWER of them: pass 2's B could undershoot
     * its own zg_count (audit L17). Each pass strictly shrinks zg_count,
     * so the loop ends; the guard is for a solver that ever stops
     * converging. */
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

    for (int pass = 0;; pass++) {
        if (pass >= 64)
            die("internal calc error: the Zone Group / Block Group solve did not converge");
        zg_blocks = zg_count; /* 1 block each */
        pending_total_blk = (u64) pending_per_zg * zg_count;
        /* + the most the first Block Group's alignment can skip. */
        fixed_wo_B = sb_blocks + zg_blocks + i_bmap_blk + i_tbl_blk + node_tbl_blk + pending_total_blk + j_total_blk +
                     (align_blocks - 1);

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
            /* Past 1 PiB the default would exceed the Block Group count
             * the mount accepts: double it until it fits. */
            while (total_blocks / (bg_size_bytes / CETRAFS_BLOCK_SIZE) > CETRAFS_MAX_BLOCK_GROUPS &&
                   bg_size_bytes / CETRAFS_BLOCK_SIZE * 2 <= CETRAFS_MAX_BG_SIZE_BLOCKS)
                bg_size_bytes *= 2;
        }

        bg_size_blocks = bg_size_bytes / CETRAFS_BLOCK_SIZE;

        /* Solve B from: B * (bg_size_blocks + 1 BG-table block per BG) <= remaining */
        B = cetrafs_solve_bg_count(total_blocks, fixed_wo_B, bg_size_blocks, &waste);
        /* Each Zone Group costs its pending-free queue, so on a small
         * device the count itself can leave no room for one Block Group
         * -- the -M-derived default of 64 on a 600 MiB volume did. Fewer
         * Zone Groups, then solve again; the clamp below and the warning
         * after the loop finish the job. */
        if (B == 0 && zg_count > 1) {
            zg_count = (zg_count + 1) / 2;
            continue;
        }
        if (B == 0)
            die("no space for any BG (increase device or reduce -b/-J/-N)");
        /* The mount refuses more (kmod/fs.c), so a volume past it would
         * be written and then unmountable. Name the -b that fits. */
        if (B > CETRAFS_MAX_BLOCK_GROUPS) {
            u64 need = (total_blocks * (u64) CETRAFS_BLOCK_SIZE / CETRAFS_MAX_BLOCK_GROUPS + (1ULL << 20) - 1) >> 20;

            die("%" PRIu64 " Block Groups of %llu MiB exceed the %u a volume may have -- pass -b %llu or more", B,
                (unsigned long long) (bg_size_blocks * CETRAFS_BLOCK_SIZE >> 20), CETRAFS_MAX_BLOCK_GROUPS,
                (unsigned long long) need);
        }

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

    /* A Zone Group is owned by one node at a time and a node allocates
     * only from groups it owns, so a node past the zg_count-th mounts
     * cleanly and fails its first allocating write ENOSPC (audit
     * 2026-11-14 A-13). Said loudly, not refused: a small volume cannot
     * back more, and a test or single-node volume does not need it. */
    if (zg_count < node_table_count)
        fprintf(stderr,
                "warning: %u Zone Group(s) for up to %llu nodes (-M): at most %u node(s) can ever write to this\n"
                "         volume. A node beyond that mounts and then fails every allocating write with ENOSPC.\n"
                "         Pass -M with the real cluster size%s.\n",
                zg_count, (unsigned long long) node_table_count, zg_count,
                zg_explicit ? ", or a larger -z" : ", or a larger device");

    /* Checked once the group size is final: -A must divide it. */
    if (!cetrafs_data_align_ok(align_blocks, bg_size_blocks))
        die_arg("-A %llu KiB does not divide the %llu MiB Block Group size",
                (unsigned long long) (align_blocks * CETRAFS_BLOCK_SIZE / 1024),
                (unsigned long long) (bg_size_blocks * CETRAFS_BLOCK_SIZE >> 20));

    const u64 bg_table_blk = B; /* one block per BG */

    /* --- lay out absolute LBAs --- */
    const u64 sb_lba = CETRAFS_SB_BLOCK_NR;      /* 0 */
    const u64 zg_lba = sb_lba + sb_blocks;       /* CETRAFS_SB_AREA_BLOCKS */
    const u64 bg_table_lba = zg_lba + zg_blocks; /* 1 + Z */
    const u64 i_bmap_lba = bg_table_lba + bg_table_blk;
    const u64 i_tbl_lba = i_bmap_lba + i_bmap_blk;
    const u64 node_tbl_lba = i_tbl_lba + i_tbl_blk;
    const u64 pending_lba = node_tbl_lba + node_tbl_blk;
    const u64 j_area_lba = pending_lba + pending_total_blk;
    /* The first group on the alignment, so every group is (it divides
     * the group size); the solve above kept room for the skip. */
    const u64 bg_regions_lba = (j_area_lba + j_total_blk + align_blocks - 1) / align_blocks * align_blocks;

    if (bg_regions_lba + B * bg_size_blocks > total_blocks)
        die("internal calc error: consumed > total");

    /* --- build superblock --- */
    cetrafs_superblock_t sb;
    memset(&sb, 0, sizeof(sb));

    sb.magic = cetrafs_cpu_to_le32(CETRAFS_MAGIC);
    sb.version = cetrafs_cpu_to_le16(CETRAFS_VERSION);
    sb.sb_bytes = cetrafs_cpu_to_le16(sizeof(sb));
    sb.block_size = cetrafs_cpu_to_le32(CETRAFS_BLOCK_SIZE);
    sb.pad0 = cetrafs_cpu_to_le32(0);
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
    sb.data_align_blocks = cetrafs_cpu_to_le32((u32) align_blocks);

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
        u64 incompat = CETRAFS_FEAT_INCOMPAT_SUPP;
        sb.features_incompat = cetrafs_cpu_to_le64(incompat);
    }


    /* The volume's identity: a random version-4 UUID per format. It was
     * never written, so every volume read as the all-zero UUID (audit
     * 2026-11-14 U11). */
    {
        int ur = open("/dev/urandom", O_RDONLY | O_CLOEXEC);

        if (ur < 0 || read(ur, sb.uuid, sizeof(sb.uuid)) != (ssize_t) sizeof(sb.uuid))
            die("cannot read random bytes for the volume UUID: %s", strerror(errno));
        close(ur);
        sb.uuid[6] = (u8) ((sb.uuid[6] & 0x0f) | 0x40);
        sb.uuid[8] = (u8) ((sb.uuid[8] & 0x3f) | 0x80);
    }

    /* SB checksum (CRC32C over full struct with checksum zeroed) */
    sb.checksum = cetrafs_cpu_to_le64(0);
    uint32_t sb_crc = crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum));
    sb.checksum = cetrafs_cpu_to_le64((u64) sb_crc);

    /* pad to a block
     *
     * NOT written here. The superblock is what makes this volume
     * mountable, and everything it points at -- the journal area above
     * all -- is written after this point. Stamped here, an mkfs that
     * stopped anywhere in between (a power cut, an I/O error, a ^C)
     * left a VALID superblock over the PREVIOUS volume's journal slots,
     * which a mount then replays into the new filesystem. The same rule
     * the kernel follows: a reference may not become durable before
     * what it refers to. See the stamp at the end of this function. */
    /* Its OWN buffer: 'blk' below is a scratch block reused for the ZG
     * table, the BG table and the BG headers, so deferring the stamp
     * while sharing it writes the last of those into block 0 (fsck:
     * "bad magic", caught the first time this ran). */
    u8 *sb_blk = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);
    u8 *blk = (u8 *) xcalloc(1, CETRAFS_BLOCK_SIZE);
    memcpy(sb_blk, &sb, sizeof(sb));

    /* Every refusal above is behind us and the first write is below:
     * the old filesystem stops being mountable here, and not before. */
    if (!dry_run) {
        mkfs_retire_old_superblock(fd, dev);
        mkfs_wipe_backup_gpt(fd, dev);
        /* The old volume's copy of block 0 goes with it, before any new
         * structure is written: a stop between here and the new copy
         * must not leave a valid copy describing the old volume over
         * half-written new tables, for fsck -r to restore (A-7). */
        {
            uint8_t zero[CETRAFS_BLOCK_SIZE];

            memset(zero, 0, sizeof(zero));
            write_block(fd, CETRAFS_SB_REPLICA_NR, zero, true);
            if (fsync(fd) != 0)
                die("fsync failed after clearing the old superblock copy: %s", strerror(errno));
        }
    }

    /* --------------------------- */
    /* --- ZG table & journals --- */
    /* --------------------------- */

    /* precompute per-BG layout -- needed here too, to compute each ZG's
     * free_data_blocks aggregate before the BG table itself is written */
    u32 off_bmap32, off_data32;
    u64 data_cnt;
    cetrafs_calc_bg_layout(bg_size_blocks, align_blocks, &off_bmap32, &off_data32, &data_cnt);

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
        zg.hot_checksum = cetrafs_cpu_to_le64(0);
        zg.hot_checksum = cetrafs_cpu_to_le64((u64) crc32c_struct((const u8 *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                                                      offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF,
                                                      sizeof(zg.hot_checksum)));
        zg.cold_checksum = cetrafs_cpu_to_le64(0);
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
        bg.checksum = cetrafs_cpu_to_le64(0);
        bg.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum), sizeof(cetrafs_le64(bg.checksum))));

        memcpy(blk, &bg, sizeof(bg));
        write_block(fd, bg_table_lba + b, blk, !dry_run);

        /* BG header at region start */
        cetrafs_bg_header_t bh;
        memset(&bh, 0, sizeof(bh));

        bh.bg_id = cetrafs_cpu_to_le32((u32) b);

        bh.length_blocks = cetrafs_cpu_to_le64(bg_size_blocks);
        bh.off_data_bmap = cetrafs_cpu_to_le32(off_bmap32);
        bh.off_data_region = cetrafs_cpu_to_le32(off_data32);
        bh.data_block_count = cetrafs_cpu_to_le64(data_cnt);

        /* plain-native, like the BG descriptor's checksum above */
        bh.checksum = cetrafs_cpu_to_le64(0);
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
    /* Every slot a DEAD record, not zeros (cetrafs_inode_dead_stamp_us()).
     * An all-zero record cannot be told from a live one read back as
     * zeros, so no walk that frees may take it as empty -- and a create
     * that stopped between its bit and its record left exactly that,
     * stopping every node's scrub until an offline fsck -r (audit
     * 2026-11-15 F-12). A dead record is what the orphan scrub reclaims.
     * Same bytes on the wire as the zeroing it replaces, batched. */
    if (!dry_run) {
        const u64 batch = 256;
        u8 *tb = (u8 *) calloc(batch, CETRAFS_BLOCK_SIZE);

        if (!tb)
            die("out of memory for the inode table");
        for (u64 b = 0; b < i_tbl_blk; b += batch) {
            u64 n = i_tbl_blk - b < batch ? i_tbl_blk - b : batch;

            memset(tb, 0, (size_t) (n * CETRAFS_BLOCK_SIZE));
            for (u64 k = 0; k < n; ++k) {
                u64 ino = b + k + 1;
                cetrafs_inode_t rec;

                if (ino > inodes_total)
                    break; /* past the last number: zeros, as before */
                cetrafs_inode_dead_stamp_us(&rec, ino);
                memcpy(tb + k * CETRAFS_BLOCK_SIZE, &rec, sizeof(rec));
            }
            pwrite_all(fd, tb, (size_t) (n * CETRAFS_BLOCK_SIZE), (off_t) ((i_tbl_lba + b) * CETRAFS_BLOCK_SIZE));
        }
        free(tb);
    }

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
    ri.uid = cetrafs_cpu_to_le32(0);
    ri.gid = cetrafs_cpu_to_le32(0);
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
    ri.eh.eh_depth = cetrafs_cpu_to_le16(0); /* leaf */
    ri.eh.eh_generation = cetrafs_cpu_to_le32(0);
    cetrafs_ee_init(&ri.et.leaf[0], 0 /* logical block 0 */, 1, 0, root_data_lba);

    /* v0x0005 two-sector record: identity echoes + per-sector CRCs
     * (plain-native, like the BG descriptor/header checksums above). */
    cetrafs_inode_stamp_crcs_us(&ri);

    /* write inode into its own whole block at slot (ino-1) -- one record
     * per block as of v0x0007 */
    off_t ino_off = (off_t) (i_tbl_lba + (CETRAFS_ROOT_INO - 1)) * CETRAFS_BLOCK_SIZE;
    if (!dry_run)
        pwrite_all(fd, &ri, sizeof(ri), ino_off);

    if (!dry_run) {
        /* Everything the superblock will point at, on the device. */
        if (fsync(fd) != 0)
            die("fsync failed before stamping the superblock: %s", strerror(errno));

        /* The copy first (A-7): a stop between the two leaves a volume
         * whose block 0 fsck -r restores from it, never a volume with a
         * superblock and no copy. */
        write_block(fd, CETRAFS_SB_REPLICA_NR, sb_blk, true);
        if (fsync(fd) != 0)
            die("fsync of the superblock copy failed: %s", strerror(errno));

        /* Only now does the volume become mountable. */
        write_block(fd, sb_lba, sb_blk, true);

        /* And an unchecked fsync is not a flush, it is a hope: on a
         * thin LUN that just ran out, or a device that is going away,
         * this is where mkfs learns the volume it is about to call
         * "completed" is not on the platter. */
        if (fsync(fd) != 0)
            die("fsync of the superblock failed: %s", strerror(errno));
    }
    /* close(2) reports errors a buffered write deferred -- EIO, ENOSPC
     * on some filesystems -- and this is the last chance to see them. */
    if (close(fd) != 0)
        die("close failed: %s", strerror(errno));

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
