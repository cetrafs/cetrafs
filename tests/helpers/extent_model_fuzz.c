// SPDX-License-Identifier: GPL-2.0-or-later
// extent_model_fuzz -- model-based fuzzer for the file data path.
//
// The workload cetrafs actually carries is a VM image: one large file hit
// with a long, random interleaving of mid-file O_DIRECT writes (guest
// I/O), hole punches (guest TRIM), overwrites and truncates. Every one of
// those runs through the extent tree (inline -> depth-1 leaf -> depth-2
// index) and the data-block allocator/bitmap -- the riskiest machinery in
// the filesystem, and the one whose bugs hide in the INTERACTIONS between
// operations, not in any single one. The per-operation suites
// (punch_hole, extent_tree_depth2, truncate_leaf_unwind, direct_io, ...)
// each check one primitive; none drives the tree deep and fragmented with
// a random mix and then proves the bytes are still exactly right.
//
// This does. It keeps a compact SHADOW MODEL -- one 32-bit write-epoch per
// 4 KiB block, 0 meaning hole -- and a block's content is a pure function
// of (block index, epoch), so the model never stores bytes yet can
// regenerate the exact expected content of any block. It then fires a
// seeded (reproducible) random stream of write/punch/overwrite/truncate,
// reads ranges back through O_DIRECT (the cache=none path a VM uses) and
// asserts every block reads back as the model says -- a written block its
// pattern, a hole zeros. fsck afterwards (the wrapper's job) proves the
// other half: that the extent tree and the block bitmap still agree, i.e.
// no block was leaked and -- the failure the scrub once had -- no LIVE
// block was freed.
//
// usage: extent_model_fuzz <file> <seed> <ops> [max_blocks]
//        extent_model_fuzz <file> selfcheck        -- negative control
//
// exit: 0 ok; 2 I/O/setup error; 3 DATA MISMATCH (a filesystem bug);
//       4 selfcheck: the verifier FAILED to catch a planted mismatch.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/falloc.h>

#define BS 4096u

/* splitmix64: a block's content and the op PRNG both derive from it, so a
 * run is fully reproducible from its seed -- a failure replays exactly. */
static uint64_t sm64(uint64_t x)
{
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

static uint64_t rng_state;
static uint64_t rnd(void) { return sm64(rng_state += 0x9E3779B97F4A7C15ULL); }
static uint64_t rnd_n(uint64_t n) { return n ? rnd() % n : 0; }

/* Content of block `blk` written in epoch `ep` (ep != 0). Pure function,
 * so verify regenerates it with no stored bytes. */
static void fill(void *buf, uint64_t blk, uint32_t ep)
{
    uint64_t *p = buf;
    uint64_t s = sm64(blk * 0xD1B54A32D192ED03ULL ^ ((uint64_t) ep << 32) ^ 0x1234567ULL);
    for (unsigned i = 0; i < BS / 8; i++) {
        p[i] = s;
        s = sm64(s);
    }
}

static void *g_buf, *g_exp; /* two aligned 4 KiB scratch blocks */
static uint32_t *shadow;    /* per-block epoch, 0 == hole/unmapped */
static uint64_t max_blocks;
static uint64_t cur_blocks; /* logical size in blocks (file may be sparse) */
static uint32_t epoch;      /* monotonic; next write's epoch */

static int fd;
static const char *path;

static void die(const char *what)
{
    fprintf(stderr, "extent_model_fuzz: %s: %s\n", what, strerror(errno));
    exit(2);
}

/* Read block `blk` and compare to what the model says it must be. Returns
 * 1 on match, 0 on mismatch (and prints the first mismatching bytes). */
static int check_block(uint64_t blk)
{
    if (pread(fd, g_buf, BS, (off_t) blk * BS) != (ssize_t) BS)
        die("pread");
    uint32_t ep = blk < max_blocks ? shadow[blk] : 0;
    if (ep == 0)
        memset(g_exp, 0, BS); /* a hole / past EOF reads zeros */
    else
        fill(g_exp, blk, ep);
    if (memcmp(g_buf, g_exp, BS) == 0)
        return 1;
    fprintf(stderr,
            "DATA MISMATCH at block %llu (epoch model=%u): got %02x%02x%02x%02x.. want %02x%02x%02x%02x..\n",
            (unsigned long long) blk, ep, ((uint8_t *) g_buf)[0], ((uint8_t *) g_buf)[1], ((uint8_t *) g_buf)[2],
            ((uint8_t *) g_buf)[3], ((uint8_t *) g_exp)[0], ((uint8_t *) g_exp)[1], ((uint8_t *) g_exp)[2],
            ((uint8_t *) g_exp)[3]);
    return 0;
}

/* Verify every block the file logically has. Returns mismatch count. */
static uint64_t verify_all(void)
{
    uint64_t bad = 0;
    for (uint64_t b = 0; b < cur_blocks; b++)
        if (!check_block(b))
            bad++;
    return bad;
}

static void do_write(void)
{
    uint64_t bo = rnd_n(max_blocks);
    uint64_t n = 1 + rnd_n(64);
    if (bo + n > max_blocks)
        n = max_blocks - bo;
    uint32_t ep = ++epoch;
    for (uint64_t i = 0; i < n; i++) {
        fill(g_buf, bo + i, ep);
        if (pwrite(fd, g_buf, BS, (off_t) (bo + i) * BS) != (ssize_t) BS)
            die("pwrite");
        shadow[bo + i] = ep;
    }
    if (bo + n > cur_blocks)
        cur_blocks = bo + n;
}

static void do_punch(void)
{
    if (!cur_blocks)
        return;
    uint64_t bo = rnd_n(cur_blocks);
    uint64_t n = 1 + rnd_n(64);
    if (bo + n > cur_blocks)
        n = cur_blocks - bo;
    if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, (off_t) bo * BS, (off_t) n * BS)) {
        if (errno == EOPNOTSUPP)
            return; /* punch unsupported: skip, not a finding */
        die("fallocate punch");
    }
    for (uint64_t i = 0; i < n; i++)
        shadow[bo + i] = 0; /* now a hole -> reads zeros */
}

static void do_truncate(void)
{
    uint64_t nb = rnd_n(max_blocks + 1);
    if (ftruncate(fd, (off_t) nb * BS))
        die("ftruncate");
    if (nb < cur_blocks) {
        for (uint64_t b = nb; b < cur_blocks; b++)
            shadow[b] = 0;
    } else {
        for (uint64_t b = cur_blocks; b < nb; b++)
            shadow[b] = 0; /* grown region is a hole */
    }
    cur_blocks = nb;
}

/* Spot-check a random run of blocks mid-stream, so a divergence is caught
 * near the op that caused it, not only at the end. */
static void do_verify_spot(void)
{
    if (!cur_blocks)
        return;
    uint64_t bo = rnd_n(cur_blocks);
    uint64_t n = 1 + rnd_n(32);
    for (uint64_t i = 0; i < n && bo + i < cur_blocks; i++)
        if (!check_block(bo + i))
            exit(3);
}

static void setup(const char *p)
{
    path = p;
    fd = open(p, O_RDWR | O_CREAT | O_DIRECT, 0644);
    if (fd < 0)
        die("open O_DIRECT");
    if (posix_memalign(&g_buf, BS, BS) || posix_memalign(&g_exp, BS, BS))
        die("posix_memalign");
    shadow = calloc(max_blocks, sizeof(*shadow));
    if (!shadow)
        die("calloc shadow");
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <file> <seed> <ops> [max_blocks] | %s <file> selfcheck\n", argv[0], argv[0]);
        return 2;
    }

    /* Negative control: build some state, then corrupt ONE block on the
     * device WITHOUT telling the model, and require verify_all() to catch
     * it. If it does not, the verifier is blind and every "pass" above is
     * worthless -- so that is the failure (exit 4), caught by the wrapper. */
    if (strcmp(argv[2], "selfcheck") == 0) {
        max_blocks = 2048;
        rng_state = 0xC0FFEEULL;
        setup(argv[1]);
        for (int i = 0; i < 200; i++)
            do_write();
        if (verify_all() != 0) {
            fprintf(stderr, "selfcheck: clean state already mismatched?!\n");
            return 2;
        }
        /* pick a written block and overwrite it with a DIFFERENT epoch's
         * bytes, leaving the model as-is. */
        uint64_t b = 0;
        while (b < cur_blocks && shadow[b] == 0)
            b++;
        if (b >= cur_blocks)
            return 2;
        fill(g_buf, b, shadow[b] + 1000); /* wrong content for this block */
        if (pwrite(fd, g_buf, BS, (off_t) b * BS) != (ssize_t) BS)
            die("pwrite selfcheck");
        if (verify_all() == 0) {
            fprintf(stderr, "selfcheck: verifier MISSED a planted mismatch at block %llu\n",
                    (unsigned long long) b);
            return 4; /* detector is broken */
        }
        fprintf(stderr, "selfcheck: planted mismatch correctly caught\n");
        return 0;
    }

    if (argc < 4) {
        fprintf(stderr, "need <ops>\n");
        return 2;
    }
    rng_state = strtoull(argv[2], NULL, 0) ^ 0x5DEECE66DULL;
    uint64_t ops = strtoull(argv[3], NULL, 0);
    max_blocks = argc > 4 ? strtoull(argv[4], NULL, 0) : 16384; /* 64 MiB default */
    setup(argv[1]);

    for (uint64_t i = 0; i < ops; i++) {
        uint64_t r = rnd_n(100);
        if (r < 45)
            do_write();
        else if (r < 70)
            do_punch();
        else if (r < 85)
            do_truncate();
        else
            do_verify_spot();
    }

    if (fsync(fd))
        die("fsync");

    /* Model vs device: file size and every logical block. */
    struct stat st;
    if (fstat(fd, &st))
        die("fstat");
    if ((uint64_t) st.st_size != cur_blocks * BS) {
        fprintf(stderr, "SIZE MISMATCH: st_size=%llu model=%llu\n", (unsigned long long) st.st_size,
                (unsigned long long) (cur_blocks * BS));
        return 3;
    }
    uint64_t bad = verify_all();
    if (bad) {
        fprintf(stderr, "FAILED: %llu block(s) read back wrong after %llu ops\n", (unsigned long long) bad,
                (unsigned long long) ops);
        return 3;
    }
    fprintf(stderr, "ok: %llu ops, %llu logical blocks, all content verified\n", (unsigned long long) ops,
            (unsigned long long) cur_blocks);
    return 0;
}
