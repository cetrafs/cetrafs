// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * churn_io.c -- test-only helper: a randomized concurrent filesystem
 * workload with a CONTENT ORACLE.
 *
 * Why this exists
 * ---------------
 * Two corruptions shipped past the whole of tests/kernel/ in one week:
 * a defrag abort that freed blocks it had already committed (so two
 * inodes referenced one block), and a torn read of an inode record that
 * dropped whole extents out of a written file. Neither was reachable by
 * a serial, scripted workload, and neither was visible to fsck alone --
 * the second one left the filesystem perfectly CONSISTENT and merely
 * wrong, with a 223-block hole where data used to be.
 *
 * What catches that class is not another targeted suite; it is a
 * workload that (a) runs several writers at once, (b) reuses freed
 * space, and (c) can state what every byte of every file is SUPPOSED to
 * be. This helper is (c), and running several of it is (a) and (b).
 *
 * The oracle: every 4 KiB block is self-identifying
 * -------------------------------------------------
 * A block's content is a pure function of (seed, file id, generation,
 * block index), and the first 32 bytes spell that tuple out. So a
 * mismatch does not just say "corrupt" -- it says which bug happened:
 *
 *   tag names ANOTHER FILE          -> cross-file block overlap
 *   tag names this file, older gen  -> a lost publish / stale extent
 *   block is all zeros              -> a dropped extent (data loss)
 *   tag right, payload sum wrong    -> a torn write
 *   tag magic absent, not zero      -> wild write
 *
 * That turns a failing soak into a diagnosis instead of a bisect.
 *
 * State lives OUTSIDE the filesystem under test (<state-dir>, on the
 * host fs): one record per file holding its current name, its size, and
 * a per-block generation array (0 = hole, expect zeros). Every op
 * updates it, so holes, truncates, punches and partial tails are all
 * expressible -- and `verify` can run as a separate process after an
 * unmount/remount, which is the only way to catch a publish that never
 * reached the platter.
 *
 * Usage:
 *   churn_io churn  <root> <state-dir> <seed> <actor-id> <secs> <files> <maxblk>
 *   churn_io verify <root> <state-dir> <actor-id>
 *
 * Exit: 0 ok, 1 a verification failed (details on stdout), 2 fatal.
 */
#define _GNU_SOURCE
#include <cetrafs.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/falloc.h>
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

#define BS 4096u
#define NDIRS 4
#define TAG_MAGIC 0x434855524e424c4bULL /* "CHURNBLK" */
#define MAX_FILES 256
#define RING 256

struct blktag {
    uint64_t magic;
    uint32_t file_id; /* actor_id << 16 | slot -- unique across actors */
    uint32_t gen;
    uint64_t blkidx;
    uint32_t seed;
    uint32_t sum; /* fold of the payload after this tag */
};

/*
 * A file's content model.
 *
 * size is exact (truncate(2) does not respect block boundaries), and
 * each block carries TWO numbers rather than one, because a block can
 * legitimately be half pattern and half zeros: truncate a file down to
 * a byte offset inside block X and then grow it again, and X's bytes
 * past that offset are zeros for ever after while its prefix keeps the
 * pattern it always had. A single per-block generation cannot say that,
 * and the first version of this oracle reported it as "TORN BLOCK" --
 * the model's bug, not the filesystem's.
 *
 *   gen[b] == 0            -> the whole block reads zeros (hole)
 *   gen[b] > 0, plen[b]==0 -> the whole block is pattern(gen)
 *   gen[b] > 0, plen[b]>0  -> pattern for [0,plen), zeros for [plen,BS)
 */
struct fstate {
    uint32_t present;
    uint64_t size; /* exact, in bytes */
    uint32_t nblocks;
    uint32_t gen_ctr;
    uint32_t xattr_len; /* 0 == no xattr set */
    char name[96];      /* path relative to <root> */
    uint32_t *gen;      /* nblocks entries, 0 == hole */
    uint32_t *plen;     /* valid pattern prefix per block, 0 == whole block */
};

static struct fstate files[MAX_FILES];
static unsigned n_files, max_blocks, actor_id;
static uint32_t seed;
static char root[512], statedir[512];
/*
 * CHURN_DISABLE: comma-separated op names to leave out of the mix
 * (punch, truncate, fallocate, odirect, defrag, rename, link, xattr).
 * A bisection handle, not a way to make a run pass -- the point is to
 * find the smallest op set that still corrupts.
 */
static const char *disabled = "";
static int op_off(const char *name)
{
    const char *p = strstr(disabled, name);
    return p != NULL;
}
static uint64_t rng_state;

/* a bounded op history, dumped when something goes wrong -- the whole
 * run's log would be megabytes and the last few hundred ops are what
 * actually explain a corrupted block. */
static char ring[RING][160];
static unsigned ring_n;

static void note(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(ring[ring_n % RING], sizeof(ring[0]), fmt, ap);
    va_end(ap);
    ring_n++;
}

static void dump_ring(void)
{
    unsigned i, start = ring_n > RING ? ring_n - RING : 0;
    printf("---- actor %u: last %u ops ----\n", actor_id, ring_n - start);
    for (i = start; i < ring_n; i++)
        printf("  %s\n", ring[i % RING]);
}

static uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

static uint32_t rnd(uint32_t n)
{
    rng_state = rng_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return n ? (uint32_t) (mix64(rng_state) % n) : 0;
}

/* ---------------------------------------------------------- the oracle */

static void fill_block(unsigned char *b, uint32_t file_id, uint32_t gen, uint64_t blkidx)
{
    struct blktag *t = (struct blktag *) b;
    uint64_t base = mix64(seed ^ mix64(((uint64_t) file_id << 32) ^ mix64(((uint64_t) gen << 24) ^ blkidx)));
    uint64_t *w = (uint64_t *) (b + sizeof(*t));
    unsigned i, nw = (BS - sizeof(*t)) / 8;
    uint64_t sum = 0;

    for (i = 0; i < nw; i++) {
        w[i] = mix64(base + i);
        sum ^= w[i] + i;
    }
    t->magic = TAG_MAGIC;
    t->file_id = file_id;
    t->gen = gen;
    t->blkidx = blkidx;
    t->seed = seed;
    t->sum = (uint32_t) (sum ^ (sum >> 32));
}

static int is_zero(const unsigned char *b, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++)
        if (b[i])
            return 0;
    return 1;
}

/*
 * Compare one block against what it must contain, and say what KIND of
 * damage a mismatch is. The classification is the point: the same
 * byte-level "wrong" means a different bug depending on what the block
 * claims to be.
 */
static int check_block(const unsigned char *got, uint32_t file_id, uint32_t gen, uint32_t plen, uint64_t blkidx,
                       size_t valid, const char *path, char *why, size_t whysz)
{
    unsigned char want[BS];
    const struct blktag *g = (const struct blktag *) got;

    if (gen == 0) { /* a hole: the filesystem owes us zeros */
        if (is_zero(got, valid))
            return 0;
        if (valid >= sizeof(*g) && g->magic == TAG_MAGIC)
            snprintf(why, whysz, "HOLE HOLDS DATA: %s block %llu should read zeros, holds file_id=%u gen=%u blk=%llu "
                                 "-- a punched/sparse range was handed live blocks",
                     path, (unsigned long long) blkidx, g->file_id, g->gen, (unsigned long long) g->blkidx);
        else
            snprintf(why, whysz, "HOLE HOLDS GARBAGE: %s block %llu should read zeros", path,
                     (unsigned long long) blkidx);
        return 1;
    }

    fill_block(want, file_id, gen, blkidx);
    if (plen && plen < BS)
        memset(want + plen, 0, BS - plen);
    if (memcmp(got, want, valid) == 0)
        return 0;

    if (plen && plen < sizeof(*g)) {
        /* Too short to carry the tag -- nothing to classify by. */
        snprintf(why, whysz, "PARTIAL BLOCK MISMATCH: %s block %llu (only %u pattern bytes) does not match", path,
                 (unsigned long long) blkidx, plen);
        return 1;
    }
    if (valid >= sizeof(*g) && is_zero(got, valid))
        snprintf(why, whysz,
                 "DATA LOSS (zeros): %s block %llu should hold file_id=%u gen=%u -- the extent is gone, the read "
                 "fell into a hole",
                 path, (unsigned long long) blkidx, file_id, gen);
    else if (valid < sizeof(*g) || g->magic != TAG_MAGIC)
        snprintf(why, whysz, "WILD CONTENT: %s block %llu holds no churn tag at all", path,
                 (unsigned long long) blkidx);
    else if (g->file_id != file_id)
        snprintf(why, whysz,
                 "CROSS-FILE OVERLAP: %s block %llu holds file_id=%u (gen=%u, its block %llu) -- two inodes "
                 "reference this block; we are file_id=%u",
                 path, (unsigned long long) blkidx, g->file_id, g->gen, (unsigned long long) g->blkidx, file_id);
    else if (g->blkidx != blkidx)
        snprintf(why, whysz, "MISPLACED BLOCK: %s block %llu holds OUR block %llu -- an extent maps the wrong offset",
                 path, (unsigned long long) blkidx, (unsigned long long) g->blkidx);
    else if (g->gen != gen)
        snprintf(why, whysz,
                 "STALE BLOCK: %s block %llu holds gen=%u, expected gen=%u -- a write was lost or an old extent "
                 "is still mapped",
                 path, (unsigned long long) blkidx, g->gen, gen);
    else
        snprintf(why, whysz, "TORN BLOCK: %s block %llu has the right tag but the payload does not match", path,
                 (unsigned long long) blkidx);
    return 1;
}

/* ------------------------------------------------------------- plumbing */

static uint32_t fid(unsigned slot) { return (actor_id << 16) | slot; }

static void fullpath(char *out, size_t n, const char *rel) { snprintf(out, n, "%s/%s", root, rel); }

static uint64_t fsize(const struct fstate *f) { return f->size; }

/* Keep nblocks the derived truth about size, in one place. */
static void set_size(struct fstate *f, uint64_t sz)
{
    f->size = sz;
    f->nblocks = (uint32_t) ((sz + BS - 1) / BS);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ----------------------------------------------------------- state file */

static void state_path(char *out, size_t n) { snprintf(out, n, "%s/a%u.state", statedir, actor_id); }

static int state_save(void)
{
    char p[600], tmp[620];
    FILE *fp;
    unsigned i;

    state_path(p, sizeof(p));
    snprintf(tmp, sizeof(tmp), "%s.tmp", p);
    fp = fopen(tmp, "wb");
    if (!fp)
        return -1;
    fwrite(&n_files, sizeof(n_files), 1, fp);
    fwrite(&seed, sizeof(seed), 1, fp);
    for (i = 0; i < n_files; i++) {
        struct fstate *f = &files[i];
        fwrite(f, offsetof(struct fstate, gen), 1, fp);
        if (f->present && f->nblocks) {
            fwrite(f->gen, sizeof(uint32_t), f->nblocks, fp);
            fwrite(f->plen, sizeof(uint32_t), f->nblocks, fp);
        }
    }
    if (fclose(fp) != 0)
        return -1;
    return rename(tmp, p);
}

static int state_load(void)
{
    char p[600];
    FILE *fp;
    unsigned i;

    state_path(p, sizeof(p));
    fp = fopen(p, "rb");
    if (!fp)
        return -1;
    if (fread(&n_files, sizeof(n_files), 1, fp) != 1 || fread(&seed, sizeof(seed), 1, fp) != 1 ||
        n_files > MAX_FILES) {
        fclose(fp);
        return -1;
    }
    for (i = 0; i < n_files; i++) {
        struct fstate *f = &files[i];
        if (fread(f, offsetof(struct fstate, gen), 1, fp) != 1) {
            fclose(fp);
            return -1;
        }
        f->gen = calloc(f->nblocks + 1, sizeof(uint32_t));
        f->plen = calloc(f->nblocks + 1, sizeof(uint32_t));
        if (!f->gen || !f->plen) {
            fclose(fp);
            return -1;
        }
        if (f->present && f->nblocks &&
            (fread(f->gen, sizeof(uint32_t), f->nblocks, fp) != f->nblocks ||
             fread(f->plen, sizeof(uint32_t), f->nblocks, fp) != f->nblocks)) {
            fclose(fp);
            return -1;
        }
    }
    fclose(fp);
    return 0;
}

/* ------------------------------------------------------------ verifying */

static int verify_file(struct fstate *f, unsigned slot)
{
    char path[700], why[400];
    unsigned char buf[BS];
    struct stat st;
    int fd, bad = 0;
    uint64_t b;

    if (!f->present)
        return 0;
    fullpath(path, sizeof(path), f->name);
    if (stat(path, &st) != 0) {
        printf("MISSING FILE: %s (%s) -- a live file vanished\n", f->name, strerror(errno));
        return 1;
    }
    if ((uint64_t) st.st_size != fsize(f)) {
        printf("SIZE MISMATCH: %s is %llu bytes, should be %llu -- a truncate or an extent was lost\n", f->name,
               (unsigned long long) st.st_size, (unsigned long long) fsize(f));
        bad++;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("OPEN FAILED: %s (%s)\n", f->name, strerror(errno));
        return bad + 1;
    }
    for (b = 0; b < f->nblocks; b++) {
        uint64_t left = f->size - b * (uint64_t) BS;
        size_t valid = left < BS ? (size_t) left : BS;
        ssize_t n = pread(fd, buf, valid, (off_t) b * BS);
        if (n < 0 || (size_t) n != valid) {
            printf("SHORT READ: %s block %llu got %zd of %zu (%s)\n", f->name, (unsigned long long) b, n, valid,
                   strerror(errno));
            bad++;
            break;
        }
        if (check_block(buf, fid(slot), f->gen[b], f->plen[b], b, valid, f->name, why, sizeof(why))) {
            printf("%s\n", why);
            if (++bad >= 4) { /* four is enough to classify; the rest is noise */
                printf("  (further mismatches in %s suppressed)\n", f->name);
                break;
            }
        }
    }
    if (f->xattr_len) {
        unsigned char want[BS], got[BS];
        ssize_t n = fgetxattr(fd, "user.churn", got, sizeof(got));
        fill_block(want, fid(slot), 0xffffffffu, 0);
        if (n < 0 || (uint32_t) n != f->xattr_len || memcmp(got, want + sizeof(struct blktag), f->xattr_len) != 0) {
            printf("XATTR MISMATCH: %s user.churn is %zd bytes, should be %u\n", f->name, n, f->xattr_len);
            bad++;
        }
    }
    close(fd);
    return bad;
}

static int verify_all(void)
{
    unsigned i;
    int bad = 0, live = 0;
    for (i = 0; i < n_files; i++) {
        if (!files[i].present)
            continue;
        live++;
        bad += verify_file(&files[i], i);
    }
    printf("actor %u: verified %d live file(s), %d problem(s)\n", actor_id, live, bad);
    return bad;
}

/* --------------------------------------------------------------- the ops */

static int wr_range(struct fstate *f, unsigned slot, uint32_t start, uint32_t count, int direct)
{
    char path[700];
    unsigned char *buf;
    int fd, flags = O_WRONLY | O_CREAT;
    uint32_t i, g;

    if (!count)
        return 0;
    fullpath(path, sizeof(path), f->name);
    if (direct)
        flags |= O_DIRECT;
    fd = open(path, flags, 0644);
    if (fd < 0 && direct) {
        flags &= ~O_DIRECT;
        direct = 0;
        fd = open(path, flags, 0644);
    }
    if (fd < 0)
        return -1;
    if (posix_memalign((void **) &buf, BS, BS) != 0) {
        close(fd);
        return -1;
    }

    g = ++f->gen_ctr;
    /* A write past EOF leaves a hole behind it; record that before the
     * blocks themselves, so a crash in the middle still describes a
     * file the oracle can check. */
    for (i = f->nblocks; i < start && i < max_blocks; i++) {
        f->gen[i] = 0;
        f->plen[i] = 0;
    }

    for (i = 0; i < count; i++) {
        uint64_t b = start + i;
        ssize_t n;
        if (b >= max_blocks)
            break;
        fill_block(buf, fid(slot), g, b);
        n = pwrite(fd, buf, BS, (off_t) b * BS);
        if (n != (ssize_t) BS) {
            /* ENOSPC can land INSIDE a block. A partial block is not
             * something a per-block map can describe, so put the file
             * back to the size the map already claims -- otherwise the
             * next verify reports a size mismatch that is ours, not the
             * filesystem's. */
            if (n > 0)
                (void) ftruncate(fd, (off_t) fsize(f));
            break;
        }
        f->gen[b] = g;
        f->plen[b] = 0; /* the whole block was just written */
        if ((b + 1) * (uint64_t) BS > f->size)
            set_size(f, (b + 1) * (uint64_t) BS);
    }
    free(buf);
    close(fd);
    note("wr%s slot=%u gen=%u [%u,+%u) -> nblk=%u", direct ? "(O_DIRECT)" : "", slot, g, start, i, f->nblocks);
    return 0;
}

static void op_create(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700], rel[96];
    uint32_t nb;

    if (f->present)
        return;
    snprintf(rel, sizeof(rel), "d%u/a%uf%u", rnd(NDIRS), actor_id, slot);
    fullpath(path, sizeof(path), rel);
    unlink(path);
    snprintf(f->name, sizeof(f->name), "%s", rel);
    f->present = 1;
    set_size(f, 0);
    f->xattr_len = 0;
    memset(f->gen, 0, max_blocks * sizeof(uint32_t));
    memset(f->plen, 0, max_blocks * sizeof(uint32_t));
    nb = 1 + rnd(max_blocks / 2);
    if (wr_range(f, slot, 0, nb, 0) != 0)
        f->present = 0;
}

static void op_delete(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700];
    if (!f->present)
        return;
    fullpath(path, sizeof(path), f->name);
    if (unlink(path) == 0 || errno == ENOENT) {
        f->present = 0;
        note("unlink slot=%u %s", slot, f->name);
    }
}

static void op_truncate(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700];
    uint64_t newsz;
    uint32_t nb, tail, i;

    if (!f->present)
        return;
    fullpath(path, sizeof(path), f->name);
    newsz = (uint64_t) rnd(max_blocks) * BS + rnd(BS);
    nb = (uint32_t) ((newsz + BS - 1) / BS);
    tail = (uint32_t) (newsz % BS);
    if (truncate(path, (off_t) newsz) != 0)
        return;
    for (i = f->nblocks; i < nb; i++) { /* grown: the gap reads zeros */
        f->gen[i] = 0;
        f->plen[i] = 0;
    }
    /* Shrinking into the middle of a block discards that block's tail
     * FOR GOOD: grow the file again and those bytes read zeros, not the
     * pattern they held. Record the surviving prefix now -- by the time
     * the file grows there is nothing left to deduce it from. */
    if (tail && nb && nb <= f->nblocks && f->gen[nb - 1]) {
        uint32_t cur = f->plen[nb - 1];
        f->plen[nb - 1] = (cur && cur < tail) ? cur : tail;
    }
    set_size(f, newsz);
    note("truncate slot=%u -> %llu (nblk=%u tail=%u)", slot, (unsigned long long) newsz, nb, tail);
}

static void op_punch(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700];
    uint32_t start, count, i;
    int fd;

    if (!f->present || f->nblocks < 2)
        return;
    start = rnd(f->nblocks - 1);
    count = 1 + rnd(f->nblocks - start);
    if (!count)
        return;
    fullpath(path, sizeof(path), f->name);
    fd = open(path, O_WRONLY);
    if (fd < 0)
        return;
    if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, (off_t) start * BS, (off_t) count * BS) == 0) {
        for (i = start; i < start + count; i++) {
            f->gen[i] = 0;
            f->plen[i] = 0;
        }
        note("punch slot=%u [%u,+%u)", slot, start, count);
    }
    close(fd);
}

static void op_fallocate(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700];
    int fd;
    uint32_t start, count;

    if (!f->present)
        return;
    fullpath(path, sizeof(path), f->name);
    fd = open(path, O_WRONLY);
    if (fd < 0)
        return;
    start = rnd(max_blocks / 2);
    count = 1 + rnd(16);
    /* KEEP_SIZE: preallocation must change neither the size nor a single
     * byte that can be read back. The oracle's map is untouched on
     * purpose -- if preallocating alters content, that is the finding. */
    (void) fallocate(fd, FALLOC_FL_KEEP_SIZE, (off_t) start * BS, (off_t) count * BS);
    close(fd);
    note("fallocate(KEEP_SIZE) slot=%u [%u,+%u)", slot, start, count);
}

static void op_rename(unsigned slot)
{
    struct fstate *f = &files[slot];
    char from[700], to[700], rel[96];
    if (!f->present)
        return;
    snprintf(rel, sizeof(rel), "d%u/a%uf%u.r%u", rnd(NDIRS), actor_id, slot, f->gen_ctr & 0xff);
    fullpath(from, sizeof(from), f->name);
    fullpath(to, sizeof(to), rel);
    if (rename(from, to) == 0) {
        note("rename slot=%u %s -> %s", slot, f->name, rel);
        snprintf(f->name, sizeof(f->name), "%s", rel);
    }
}

static void op_link(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700], lnk[700];
    if (!f->present)
        return;
    fullpath(path, sizeof(path), f->name);
    snprintf(lnk, sizeof(lnk), "%s/d%u/a%uf%u.lnk", root, rnd(NDIRS), actor_id, slot);
    unlink(lnk);
    if (link(path, lnk) == 0) {
        /* Dropping the extra link again is the half that exercises
         * nlink decrement and the orphan path; leaving it would just
         * accumulate names. */
        unlink(lnk);
        note("link+unlink slot=%u", slot);
    }
}

static void op_xattr(unsigned slot)
{
    struct fstate *f = &files[slot];
    unsigned char want[BS];
    char path[700];
    uint32_t len;

    if (!f->present)
        return;
    fullpath(path, sizeof(path), f->name);
    len = 1 + rnd(200);
    fill_block(want, fid(slot), 0xffffffffu, 0);
    if (setxattr(path, "user.churn", want + sizeof(struct blktag), len, 0) == 0) {
        f->xattr_len = len;
        note("setxattr slot=%u len=%u", slot, len);
    }
}

static void op_fsync(unsigned slot)
{
    struct fstate *f = &files[slot];
    char path[700];
    int fd;
    if (!f->present)
        return;
    fullpath(path, sizeof(path), f->name);
    fd = open(path, O_WRONLY);
    if (fd < 0)
        return;
    fsync(fd);
    close(fd);
    note("fsync slot=%u", slot);
}

static void op_defrag(unsigned slot)
{
    struct fstate *f = &files[slot];
    struct cetrafs_defrag_stats st;
    char path[700];
    int fd;

    if (!f->present || !f->nblocks)
        return;
    fullpath(path, sizeof(path), f->name);
    fd = open(path, O_RDWR);
    if (fd < 0)
        return;
    if (ioctl(fd, CETRAFS_IOC_DEFRAG, &st) == 0)
        note("defrag slot=%u %llu -> %llu extents, %llu blocks moved", slot, (unsigned long long) st.extents_before,
             (unsigned long long) st.extents_after, (unsigned long long) st.blocks_moved);
    close(fd);
}

/* ----------------------------------------------------------- the actor */

static int churn(double secs)
{
    double end = now_s() + secs;
    unsigned long ops = 0;

    while (now_s() < end) {
        unsigned slot = rnd(n_files);
        struct fstate *f = &files[slot];
        uint32_t r = rnd(100);

        ops++;
        if (!f->present) {
            /* Skew an empty slot toward creation, but not always -- a
             * run where every slot is full all the time never exercises
             * allocation into just-freed space. */
            if (r < 70)
                op_create(slot);
            continue;
        }
        if (r < 14) { /* partial rewrite: the commonest real workload */
            uint32_t start = f->nblocks ? rnd(f->nblocks) : 0;
            wr_range(f, slot, start, 1 + rnd(32), 0);
        } else if (r < 22) { /* append */
            wr_range(f, slot, f->nblocks, 1 + rnd(24), 0);
        } else if (r < 28) { /* whole-file overwrite */
            wr_range(f, slot, 0, f->nblocks ? f->nblocks : 1, 0);
        } else if (r < 34) { /* O_DIRECT, block aligned */
            uint32_t start = f->nblocks ? rnd(f->nblocks) : 0;
            wr_range(f, slot, start, 1 + rnd(8), op_off("odirect") ? 0 : 1);
        } else if (r < 40) {
            if (!op_off("truncate"))
                op_truncate(slot);
        } else if (r < 46) {
            if (!op_off("punch"))
                op_punch(slot);
        } else if (r < 50) {
            if (!op_off("fallocate"))
                op_fallocate(slot);
        } else if (r < 55) {
            op_rename(slot);
        } else if (r < 58) {
            op_link(slot);
        } else if (r < 62) {
            op_xattr(slot);
        } else if (r < 70) {
            op_fsync(slot);
        } else if (r < 74) {
            if (!op_off("defrag"))
                op_defrag(slot);
        } else if (r < 84) {
            /* Verify DURING the run, not only at the end: a block that
             * is wrong now and overwritten later leaves no trace in a
             * final sweep. Fail at the first one -- a distribution of a
             * known failure is worth nothing next to its first instance
             * with the op log still attached. */
            if (verify_file(f, slot)) {
                printf("FIRST FAILURE after %lu ops (mid-run verify of slot %u)\n", ops, slot);
                dump_ring();
                state_save();
                return 1;
            }
        } else {
            op_delete(slot);
        }
    }
    if (state_save() != 0) {
        fprintf(stderr, "churn_io: could not save state: %s\n", strerror(errno));
        return 2;
    }
    /* Always persist the op ring, not only on failure: a post-mortem
     * (e.g. fsck naming leaked blocks by fid/gen) needs the op history
     * of a run whose actors all exited CLEAN. */
    {
        char rp[600];
        FILE *rf;

        snprintf(rp, sizeof(rp), "%s/a%u.ring", statedir, actor_id);
        rf = fopen(rp, "w");
        if (rf) {
            unsigned i, start = ring_n > RING ? ring_n - RING : 0;

            for (i = start; i < ring_n; i++)
                fprintf(rf, "%s\n", ring[i % RING]);
            fclose(rf);
        }
    }
    printf("actor %u: %lu ops\n", actor_id, ops);
    return 0;
}

int main(int argc, char **argv)
{
    unsigned i;

    if (argc < 5) {
        fprintf(stderr, "usage: %s churn  <root> <state> <seed> <actor> <secs> <files> <maxblk>\n", argv[0]);
        fprintf(stderr, "       %s verify <root> <state> <actor>\n", argv[0]);
        return 2;
    }
    snprintf(root, sizeof(root), "%s", argv[2]);
    snprintf(statedir, sizeof(statedir), "%s", argv[3]);

    if (strcmp(argv[1], "verify") == 0) {
        actor_id = (unsigned) strtoul(argv[4], NULL, 0);
        max_blocks = 4096;
        if (state_load() != 0) {
            fprintf(stderr, "churn_io: no state for actor %u\n", actor_id);
            return 2;
        }
        return verify_all() ? 1 : 0;
    }
    if (strcmp(argv[1], "churn") != 0 || argc < 9)
        return 2;

    if (getenv("CHURN_DISABLE"))
        disabled = getenv("CHURN_DISABLE");
    seed = (uint32_t) strtoul(argv[4], NULL, 0);
    actor_id = (unsigned) strtoul(argv[5], NULL, 0);
    n_files = (unsigned) strtoul(argv[7], NULL, 0);
    max_blocks = (unsigned) strtoul(argv[8], NULL, 0);
    if (n_files > MAX_FILES)
        n_files = MAX_FILES;
    /* Each actor gets its own stream, but one derived from the run seed:
     * the whole run replays from a single number. */
    rng_state = mix64(seed ^ ((uint64_t) actor_id << 40) ^ 0x5deece66dULL);

    for (i = 0; i < n_files; i++) {
        files[i].gen = calloc(max_blocks, sizeof(uint32_t));
        files[i].plen = calloc(max_blocks, sizeof(uint32_t));
        if (!files[i].gen || !files[i].plen)
            return 2;
    }
    return churn(strtod(argv[6], NULL));
}
