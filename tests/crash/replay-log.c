// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * replay-log -- minimal dm-log-writes replayer for cetrafs crash testing.
 *
 * dm-log-writes records every bio a filesystem issues, in submission order,
 * with its barrier flags (FLUSH/FUA). Replaying the log onto a scratch
 * device up to a chosen barrier reconstructs exactly what the platter would
 * hold if power were cut right after that point -- the basis for testing
 * that cetrafs, after a crash at ANY durability boundary, still mounts,
 * fscks clean, and has not lost acknowledged data.
 *
 * The xfstests `replay-log` does this and much more; this is the small
 * subset the cetrafs crash rig needs, with the on-disk format reconstructed
 * and verified empirically (see tests/crash/README.md).
 *
 * On-disk format (little-endian), sector size S (512 here):
 *   sector 0: { u64 magic, u64 version, u64 nr_entries, u32 sectorsize }
 *   then, for each entry, at a sector-aligned offset:
 *     { u64 sector, u64 nr_sectors, u64 flags, u64 data_len }   (32-byte header)
 *     data_len bytes of inline metadata (e.g. a mark string), within the
 *       header region, which is roundup(32 + data_len, S) bytes
 *     nr_sectors * S bytes of block data, immediately after the header region
 *   flags: FLUSH=1 FUA=2 DISCARD=4 MARK=8 METADATA=16
 *
 * Usage:
 *   replay-log --log <logdev> --count-fua
 *       print the number of FLUSH/FUA barriers in the log
 *   replay-log --log <logdev> --count-marks
 *       print each mark's name and its barrier ordinal
 *   replay-log --log <logdev> --entry-of-mark NAME
 *       print the log entry index of mark NAME (the prefix bound for it)
 *   replay-log --log <logdev> --count-entries
 *       print the number of log entries (one per bio)
 *   replay-log --log <logdev> --replay <dev> --limit-entries N
 *       replay the first N entries: a power cut between two WRITES, not
 *       only between barriers (the grow crash rig needs that granularity)
 *   replay-log --log <logdev> --replay <dev> [--limit-fua N | --end-mark NAME]
 *       replay onto <dev>: all entries, or up to and including the Nth
 *       FLUSH/FUA barrier, or up to the entry just before mark NAME
 *   replay-log --log <logdev> --check-flushed-after-mark NAME
 *              --data-start LBA --journal-start LBA --journal-blocks N
 *       order check, no replay: from mark NAME on, at the FIRST write into
 *       the journal area, print how many data-region writes (file data
 *       and the bitmaps that live in the Block Groups) were issued since
 *       the last FLUSH -- i.e. are not yet durable. A batch's entries name
 *       data and bits that must already be on the platter, so the answer
 *       must be 0. Prints "pending=<n> first=<lba>" (or "no-journal-write")
 *   replay-log --log <logdev> --replay <dev> --reorder-after-fua N
 *              --data-start LBA --journal-start LBA --journal-blocks N
 *       model a volatile-cache power cut: everything through barrier N durable,
 *       the next window's journal-area writes dropped and its last data-region
 *       (target) block torn -- see replay_reorder() below
 *   replay-log --log <logdev> --replay <dev> --volatile-cut-mark NAME
 *              | --volatile-cut-token STR | --volatile-cut-fua N
 *              [--volatile-mode drop|random] [--volatile-seed S]
 *       (a token is the data prefix of a write the workload issued after the
 *       writes it acknowledges: marks are not ordered against data bios)
 *       a volatile write cache at the cut: every write covered by a later
 *       FLUSH/FUA is applied; the writes after the last barrier before the
 *       cut are dropped (drop) or a seeded random subset is kept (random)
 *       -- see replay_volatile() below
 */
#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define WRITE_LOG_MAGIC 0x6a736677736872ULL
#define WRITE_LOG_VERSION 1ULL
#define LOG_FLUSH_FLAG (1ULL << 0)
#define LOG_FUA_FLAG (1ULL << 1)
#define LOG_DISCARD_FLAG (1ULL << 2)
#define LOG_MARK_FLAG (1ULL << 3)
#define LOG_METADATA_FLAG (1ULL << 4)

static uint64_t rd64(const uint8_t *p) { return le64toh(*(const uint64_t *) p); }
static uint32_t rd32(const uint8_t *p) { return le32toh(*(const uint32_t *) p); }
static uint64_t roundup(uint64_t v, uint64_t a) { return (v + a - 1) / a * a; }

static int read_at(int fd, void *buf, size_t n, off_t off)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = pread(fd, (char *) buf + done, n - done, off + done);
        if (r <= 0)
            return -1;
        done += r;
    }
    return 0;
}
static int write_at(int fd, const void *buf, size_t n, off_t off)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = pwrite(fd, (const char *) buf + done, n - done, off + done);
        if (r < 0)
            return -1;
        done += r;
    }
    return 0;
}

/*
 * Reorder replay: model a volatile write cache at a power cut, to exercise the
 * ONE thing ordered replay (Phases 1-3) cannot -- a cache persisting the
 * in-place target write while LOSING the journal commit that protects it.
 *
 * Everything through barrier N is durable (the cache was flushed there) and is
 * applied in full. The window AFTER barrier N (writes with fua_seen == N) is
 * the in-flight window the cut tears into. Within it we apply the single
 * adversarial reordering the journal exists to survive:
 *
 *   - DROP only the writes that land in the per-node JOURNAL area
 *     ([journal_start, journal_start + journal_blocks) in 4 KiB blocks) --
 *     "the journal commit for the in-flight op was lost in the cache";
 *   - APPLY every other write of the window in order (inode records, bitmaps,
 *     ZG/BG records -- so allocation stays self-consistent and the only thing
 *     missing is the journal), with the LAST data-region write TORN to its
 *     first half of sectors -- "the target block was caught half-written".
 *
 * A torn target block with no journal entry is unrecoverable -- UNLESS the
 * journal commit was in an earlier, already-durable window, which is exactly
 * what cetrafs_journal_write_block()'s flush between the commit and the target
 * guarantees. With the flush the journal sits before barrier N (durable here,
 * never in the dropped set), so mount's replay restores the torn target; without
 * it the journal shared the crash window and was just dropped, so the tear is
 * permanent corruption. The test passes with the flush and fails without.
 *
 * Dropping ONLY the journal area (not the whole metadata region) is load-bearing:
 * an earlier version dropped every metadata write, which also dropped inode
 * records and desynced the allocator (a block referenced by a kept record but
 * with its bitmap bit torn) -- corruption on BOTH builds, discriminating
 * nothing. Keep allocation consistent; isolate the journal.
 *
 * Only meaningful when the crash window's data writes are journaled metadata
 * blocks, so the workload must be metadata-only (regular file data carries no
 * checksum -- a torn data block is a legitimate unacknowledged loss, not
 * corruption, and would not discriminate).
 */
struct dwrite {
    off_t at;        /* byte offset on the replay device */
    uint64_t nr;     /* sectors */
    off_t data_off;  /* byte offset of the block data in the log */
};

/* Tearing shape, from --tear-sectors / --tear-blocks.
 *
 * The original model tore exactly one block (the window's last) to its
 * first HALF of sectors. That is one point in a space the README records
 * as an honest gap, and it is the easy point: half a 4 KiB block leaves
 * the tail (the last 8 bytes of the last sector) holding its OLD image,
 * so "the block fails its own tail checksum" is trivially true.
 *
 * The adversarial points are at the edges. tear_sectors = nr - 1 lands
 * every sector but the last: all-new data under an OLD tail. tear_sectors
 * = 1 lands only the first: one new sector under an otherwise old block.
 * Both must still read as torn, because journal replay decides
 * whether to redo a target on exactly that tail checksum -- and a tear
 * that produced a self-consistent block would be redone or refused on a
 * coin flip. Sweeping the sector count is how that claim gets tested
 * rather than asserted (CLAUDE.md rule 7).
 *
 * tear_blocks > 1 tears the last N of the window instead of just one:
 * a real power loss does not politely land every block but the last. */
static long opt_tear_sectors; /* 0 = the historical "first half" */
static long opt_tear_blocks = 1;

static int replay_reorder(int logfd, int replayfd, uint64_t nr_entries, uint32_t ss,
                          long N, uint64_t data_start_lba, uint64_t jstart_lba,
                          uint64_t jblocks)
{
    off_t data_start_bytes = (off_t) data_start_lba * 4096;
    off_t jlo = (off_t) jstart_lba * 4096;
    off_t jhi = jlo + (off_t) jblocks * 4096;
    off_t pos = ss;
    uint64_t fua_seen = 0, applied = 0, dropped = 0;
    uint8_t hdr[32];
    uint8_t *data = NULL;
    size_t data_cap = 0;
    struct dwrite *cw = NULL;
    size_t cw_n = 0, cw_cap = 0;

    for (uint64_t i = 0; i < nr_entries; i++) {
        if (read_at(logfd, hdr, sizeof(hdr), pos))
            break;
        uint64_t sector = rd64(hdr);
        uint64_t nr = rd64(hdr + 8);
        uint64_t flags = rd64(hdr + 16);
        uint64_t data_len = rd64(hdr + 24);
        off_t data_off = pos + (off_t) roundup(32 + data_len, ss);
        off_t blk_bytes = (off_t) nr * ss;
        int is_barrier = (flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG)) != 0;
        int is_discard = (flags & LOG_DISCARD_FLAG) != 0;
        off_t next = data_off + (is_discard ? 0 : blk_bytes);
        off_t at = (off_t) sector * ss;

        if (is_barrier) {
            if ((long) fua_seen == N)
                break; /* barrier ending the crash window: stop (crash before it) */
            fua_seen++;
            pos = next;
            continue;
        }
        if (nr == 0) { /* a pure mark / flush-less metadata-only entry */
            pos = next;
            continue;
        }
        if (is_discard) { /* mkfs TRIM in a durable window -> model as zeroed */
            if ((long) fua_seen < N) {
                static uint8_t z[1 << 16];
                off_t left = blk_bytes, a = at;
                while (left > 0) {
                    off_t chunk = left < (off_t) sizeof(z) ? left : (off_t) sizeof(z);
                    if (write_at(replayfd, z, chunk, a)) { perror("discard zero"); return 1; }
                    a += chunk; left -= chunk;
                }
            }
            pos = next;
            continue;
        }

        int in_journal = (at >= jlo && at < jhi);
        int in_data = (at >= data_start_bytes);

        if ((long) fua_seen < N) {
            /* durable window: apply in full */
            if ((size_t) blk_bytes > data_cap) {
                free(data); data = malloc(blk_bytes);
                if (!data) { fprintf(stderr, "oom\n"); return 1; }
                data_cap = blk_bytes;
            }
            if (read_at(logfd, data, blk_bytes, data_off)) break;
            if (write_at(replayfd, data, blk_bytes, at)) { perror("write"); return 1; }
            applied++;
        } else { /* crash window (fua_seen == N) */
            /* Is this a JOURNALED target block? Only dirent / extent-leaf /
             * extent-index blocks go through cetrafs_journal_write_block(), and
             * each carries a tail magic at CETRAFS_*_TAIL_OFF (4096-8). The data
             * region also holds NON-journaled blocks -- BG bitmaps and headers
             * and regular file data -- which the journal does not protect and
             * which must NOT be torn (tearing a bitmap desyncs the allocator on
             * every build, discriminating nothing: that was the bug here before
             * this magic check). So only a tail-magic block is a tear candidate;
             * everything else is applied in full. */
            int is_target = 0;
            if (blk_bytes == 4096) {
                uint8_t mg[4];
                if (!read_at(logfd, mg, 4, data_off + 4096 - 8)) {
                    uint32_t m = rd32(mg);
                    is_target = (m == 0x44424c4bu /*DBLK dirent*/
                                 || m == 0x4c424c4bu /*LBLK extent leaf*/
                                 || m == 0x58424c4bu /*XBLK xattr*/
                                 || m == 0x49424c4bu /*IBLK extent index*/);
                }
            }
            if (in_journal) {
                dropped++; /* the journal commit, lost in the cache */
            } else if (in_data && is_target) {
                /* a journaled target block: defer so the last can be torn */
                if (cw_n == cw_cap) {
                    cw_cap = cw_cap ? cw_cap * 2 : 64;
                    cw = realloc(cw, cw_cap * sizeof(*cw));
                    if (!cw) { fprintf(stderr, "oom\n"); return 1; }
                }
                cw[cw_n].at = at;
                cw[cw_n].nr = nr;
                cw[cw_n].data_off = data_off;
                cw_n++;
            } else {
                /* non-journal metadata or a non-target data block (inode record,
                 * bitmap, BG header, ZG record): APPLY in full so the allocator
                 * stays consistent and the journal is the only thing missing. */
                if ((size_t) blk_bytes > data_cap) {
                    free(data); data = malloc(blk_bytes);
                    if (!data) { fprintf(stderr, "oom\n"); return 1; }
                    data_cap = blk_bytes;
                }
                if (read_at(logfd, data, blk_bytes, data_off)) break;
                if (write_at(replayfd, data, blk_bytes, at)) { perror("write"); return 1; }
                applied++;
            }
        }
        pos = next;
    }

    /* Apply the crash window's data writes. The last opt_tear_blocks of
     * them are torn -- each landing only its first `sectors` sectors, the
     * block caught mid-write -- and everything before them lands whole. */
    uint64_t torn = 0;
    size_t tear_from = (size_t) opt_tear_blocks >= cw_n ? 0 : cw_n - (size_t) opt_tear_blocks;
    for (size_t k = 0; k < cw_n; k++) {
        uint64_t sectors = cw[k].nr;
        if (k >= tear_from && sectors > 1) {
            if (opt_tear_sectors > 0 && (uint64_t) opt_tear_sectors < sectors)
                sectors = (uint64_t) opt_tear_sectors;
            else
                sectors = (sectors + 1) / 2; /* historical default: first half */
            torn++;
        }
        off_t nbytes = (off_t) sectors * ss;
        if ((size_t) nbytes > data_cap) {
            free(data); data = malloc(nbytes);
            if (!data) { fprintf(stderr, "oom\n"); return 1; }
            data_cap = nbytes;
        }
        if (read_at(logfd, data, nbytes, cw[k].data_off)) break;
        if (write_at(replayfd, data, nbytes, cw[k].at)) { perror("write torn"); return 1; }
    }

    fsync(replayfd);
    free(data);
    free(cw);
    fprintf(stderr,
            "reorder crash after barrier %ld: %llu applied, crash window %zu data "
            "write[s] (%llu torn), %llu journal write[s] dropped\n",
            N, (unsigned long long) applied, cw_n, (unsigned long long) torn,
            (unsigned long long) dropped);
    return 0;
}

/*
 * Volatile-window model: a power cut through a WRITE CACHE, not a
 * barrier-ordered log. Every write is durable only once a FLUSH or FUA
 * barrier covers it. So: each barrier makes every write issued before it
 * durable (applied in full, in log order); the cut is at a named mark or
 * before barrier cut_fua; the writes issued after the last barrier and
 * before the cut were never covered by a flush, and each is then either
 * dropped (drop) or kept with probability 1/2 by a seeded PRNG (random),
 * in log order -- a cache may persist any subset, not a prefix. Unlike
 * the journal-area model above this does not single out what is lost:
 * any acknowledged write that lacks a later flush is lost, and the rig's
 * reads of acknowledged data are what catch it.
 *
 * The cut must not flush: replay-log only applies the log, so the window
 * is exactly what the workload left volatile.
 */
enum volatile_mode { VOL_DROP, VOL_RANDOM };
struct vwrite {
    off_t at;
    uint64_t nr;
    off_t data_off;
};

static uint64_t vol_rng;
static int vol_keep(void)
{
    /* xorshift64: one bit per window write */
    vol_rng ^= vol_rng << 13;
    vol_rng ^= vol_rng >> 7;
    vol_rng ^= vol_rng << 17;
    return (int) (vol_rng & 1);
}

static int replay_volatile(int logfd, int replayfd, uint64_t nr_entries, uint32_t ss, const char *cut_mark,
                           long cut_fua, const char *cut_token, enum volatile_mode mode)
{
    off_t pos = ss;
    uint64_t fua_seen = 0, applied = 0, kept = 0, dropped = 0;
    uint8_t hdr[32];
    uint8_t *data = NULL;
    size_t data_cap = 0;
    struct vwrite *pw = NULL;
    size_t pw_n = 0, pw_cap = 0;
    int rc = 0, cut_found = 0;

    /* apply one write from the log to the replay device */
    #define VOL_APPLY(W)                                                                              \
        do {                                                                                          \
            off_t bytes_ = (off_t) (W).nr * ss;                                                       \
            if ((size_t) bytes_ > data_cap) {                                                         \
                free(data);                                                                           \
                data = malloc(bytes_);                                                                \
                if (!data) { fprintf(stderr, "oom\n"); rc = 1; goto out; }                             \
                data_cap = bytes_;                                                                    \
            }                                                                                         \
            if (read_at(logfd, data, bytes_, (W).data_off) || write_at(replayfd, data, bytes_, (W).at)) { \
                fprintf(stderr, "volatile: write at entry failed\n"); rc = 1; goto out;               \
            }                                                                                         \
        } while (0)

    for (uint64_t i = 0; i < nr_entries; i++) {
        if (read_at(logfd, hdr, sizeof(hdr), pos))
            break;
        uint64_t sector = rd64(hdr), nr = rd64(hdr + 8), flags = rd64(hdr + 16), data_len = rd64(hdr + 24);
        off_t data_off = pos + (off_t) roundup(32 + data_len, ss);
        int is_discard = (flags & LOG_DISCARD_FLAG) != 0;
        int is_barrier = (flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG)) != 0;
        off_t next = data_off + (is_discard ? 0 : (off_t) nr * ss);

        if ((flags & LOG_MARK_FLAG) && data_len && cut_mark) {
            char name[256];
            size_t n = data_len < sizeof(name) - 1 ? data_len : sizeof(name) - 1;
            if (!read_at(logfd, name, n, pos + 32)) {
                name[n] = '\0';
                if (!strcmp(name, cut_mark)) {
                    cut_found = 1;
                    break; /* the cut: everything before the mark is in the window or durable */
                }
            }
        }
        if (is_barrier && cut_fua >= 0 && (long) fua_seen == cut_fua)
            break; /* the cut: before barrier cut_fua */
        if (cut_token && nr && !is_discard && !is_barrier) {
            /* A token write: the workload's in-band marker. Data bios are
             * logged in the order they were issued, marks are not (dm-log-
             * writes writes a mark straight to the log), so the token -- a
             * data write issued after an fsync returned -- orders the cut. */
            char tok[64];
            size_t tl = strlen(cut_token);
            if (tl < sizeof(tok) && !read_at(logfd, tok, tl, data_off) && !memcmp(tok, cut_token, tl)) {
                cut_found = 1;
                break;
            }
        }
        if (is_barrier) {
            /* Everything issued before this barrier is durable now. */
            for (size_t k = 0; k < pw_n; k++) {
                if (pw[k].nr) { VOL_APPLY(pw[k]); applied++; }
            }
            pw_n = 0;
            fua_seen++;
        }
        if (nr && !is_discard) {
            struct vwrite w = {.at = (off_t) sector * ss, .nr = nr, .data_off = data_off};
            if (flags & LOG_FUA_FLAG) {
                /* A FUA write is durable by its own completion. A FLUSH
                 * (PREFLUSH) entry's data is not: the flush precedes it. */
                VOL_APPLY(w);
                applied++;
            } else {
                if (pw_n == pw_cap) {
                    pw_cap = pw_cap ? pw_cap * 2 : 64;
                    pw = realloc(pw, pw_cap * sizeof(*pw));
                    if (!pw) { fprintf(stderr, "oom\n"); rc = 1; goto out; }
                }
                pw[pw_n++] = w;
            }
        }
        pos = next;
    }

    if ((cut_mark || cut_token) && !cut_found) {
        /* Without the cut the walk ran to the end of the log: not a cut. */
        fprintf(stderr, "no %s in the log\n", cut_mark ? "mark" : "token");
        rc = 1;
        goto out;
    }
    /* The cut: the window's writes are volatile. */
    for (size_t k = 0; k < pw_n; k++) {
        int keep = mode == VOL_RANDOM ? vol_keep() : 0;
        if (keep) {
            VOL_APPLY(pw[k]);
            kept++;
        } else {
            dropped++;
        }
    }
    fsync(replayfd);
out:
    #undef VOL_APPLY
    free(data);
    free(pw);
    if (rc == 0)
        fprintf(stderr, "volatile cut (%s): %llu barrier[s] durable, %llu window write[s] kept, %llu dropped\n",
                mode == VOL_RANDOM ? "random" : "drop", (unsigned long long) fua_seen,
                (unsigned long long) kept, (unsigned long long) dropped);
    return rc;
}

static int check_flushed(int logfd, uint64_t nr_entries, uint32_t ss, const char *mark,
                         uint64_t data_start_lba, uint64_t jstart_lba, uint64_t jblocks)
{
    off_t pos = ss;
    off_t dlo = (off_t) data_start_lba * 4096, jlo = (off_t) jstart_lba * 4096;
    off_t jhi = jlo + (off_t) jblocks * 4096;
    uint64_t pending = 0, first_pending = 0;
    int started = 0;
    uint8_t hdr[32];

    for (uint64_t i = 0; i < nr_entries; i++) {
        if (read_at(logfd, hdr, sizeof(hdr), pos)) {
            fprintf(stderr, "truncated log at entry %llu\n", (unsigned long long) i);
            return 1;
        }
        uint64_t sector = rd64(hdr), nr = rd64(hdr + 8), flags = rd64(hdr + 16), data_len = rd64(hdr + 24);
        off_t hdr_region = (off_t) roundup(32 + data_len, ss);
        int is_discard = (flags & LOG_DISCARD_FLAG) != 0;
        off_t next = pos + hdr_region + (is_discard ? 0 : (off_t) nr * ss);
        off_t at = (off_t) sector * 512;

        if (flags & LOG_MARK_FLAG) {
            if (!started && data_len) {
                char name[256];
                size_t n = data_len < sizeof(name) - 1 ? data_len : sizeof(name) - 1;
                if (!read_at(logfd, name, n, pos + 32)) {
                    name[n] = '\0';
                    started = !strcmp(name, mark);
                }
            }
            pos = next;
            continue;
        }
        /* A FLUSH makes everything completed before it durable. */
        if (flags & LOG_FLUSH_FLAG)
            pending = 0;
        if (started && nr && !is_discard) {
            if (at >= jlo && at < jhi) {
                printf("pending=%llu first=%llu\n", (unsigned long long) pending,
                       (unsigned long long) (first_pending));
                return 0;
            }
            if (at >= dlo && !(flags & LOG_FUA_FLAG)) {
                if (!pending)
                    first_pending = (uint64_t) (at / 4096);
                pending++;
            }
        }
        pos = next;
    }
    printf("no-journal-write\n");
    return 3;
}

int main(int argc, char **argv)
{
    const char *logpath = NULL, *replaypath = NULL, *end_mark = NULL;
    long limit_fua = -1, reorder_after = -1, limit_entries = -1;
    uint64_t data_start_lba = 0, journal_start_lba = 0, journal_blocks = 0;
    int count_fua = 0, count_marks = 0, count_entries = 0;
    const char *entry_of_mark = NULL;
    const char *check_mark = NULL;
    const char *vol_mark = NULL, *vol_token = NULL;
    long vol_fua = -1;
    enum volatile_mode vol_mode = VOL_DROP;
    uint64_t vol_seed = 1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--log") && i + 1 < argc)
            logpath = argv[++i];
        else if (!strcmp(argv[i], "--replay") && i + 1 < argc)
            replaypath = argv[++i];
        else if (!strcmp(argv[i], "--limit-fua") && i + 1 < argc)
            limit_fua = strtol(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--limit-entries") && i + 1 < argc)
            limit_entries = strtol(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--count-entries"))
            count_entries = 1;
        else if (!strcmp(argv[i], "--entry-of-mark") && i + 1 < argc)
            entry_of_mark = argv[++i];
        else if (!strcmp(argv[i], "--end-mark") && i + 1 < argc)
            end_mark = argv[++i];
        else if (!strcmp(argv[i], "--reorder-after-fua") && i + 1 < argc)
            reorder_after = strtol(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--data-start") && i + 1 < argc)
            data_start_lba = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--journal-start") && i + 1 < argc)
            journal_start_lba = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--journal-blocks") && i + 1 < argc)
            journal_blocks = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--tear-sectors") && i + 1 < argc)
            opt_tear_sectors = atol(argv[++i]);
        else if (!strcmp(argv[i], "--tear-blocks") && i + 1 < argc)
            opt_tear_blocks = atol(argv[++i]);
        else if (!strcmp(argv[i], "--check-flushed-after-mark") && i + 1 < argc)
            check_mark = argv[++i];
        else if (!strcmp(argv[i], "--volatile-cut-mark") && i + 1 < argc)
            vol_mark = argv[++i];
        else if (!strcmp(argv[i], "--volatile-cut-token") && i + 1 < argc)
            vol_token = argv[++i];
        else if (!strcmp(argv[i], "--volatile-cut-fua") && i + 1 < argc)
            vol_fua = strtol(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--volatile-mode") && i + 1 < argc) {
            const char *m = argv[++i];
            if (!strcmp(m, "drop"))
                vol_mode = VOL_DROP;
            else if (!strcmp(m, "random"))
                vol_mode = VOL_RANDOM;
            else {
                fprintf(stderr, "--volatile-mode is drop or random\n");
                return 2;
            }
        } else if (!strcmp(argv[i], "--volatile-seed") && i + 1 < argc)
            vol_seed = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--count-fua"))
            count_fua = 1;
        else if (!strcmp(argv[i], "--count-marks"))
            count_marks = 1;
        else {
            fprintf(stderr, "unknown/incomplete arg: %s\n", argv[i]);
            return 2;
        }
    }
    if (!logpath) {
        fprintf(stderr, "usage: see header\n");
        return 2;
    }

    int logfd = open(logpath, O_RDONLY);
    if (logfd < 0) {
        perror("open log");
        return 1;
    }

    uint8_t super[512];
    if (read_at(logfd, super, sizeof(super), 0)) {
        fprintf(stderr, "cannot read super\n");
        return 1;
    }
    if (rd64(super) != WRITE_LOG_MAGIC) {
        fprintf(stderr, "bad log magic 0x%llx\n", (unsigned long long) rd64(super));
        return 1;
    }
    uint64_t version = rd64(super + 8);
    uint64_t nr_entries = rd64(super + 16);
    uint32_t ss = rd32(super + 24);
    if (version != WRITE_LOG_VERSION || (ss != 512 && ss != 4096)) {
        fprintf(stderr, "unsupported log version %llu / sectorsize %u\n",
                (unsigned long long) version, ss);
        return 1;
    }

    if (check_mark) {
        if (!data_start_lba || !journal_start_lba || !journal_blocks) {
            fprintf(stderr, "--check-flushed-after-mark needs --data-start, --journal-start, --journal-blocks\n");
            return 2;
        }
        int rc = check_flushed(logfd, nr_entries, ss, check_mark, data_start_lba, journal_start_lba,
                               journal_blocks);
        close(logfd);
        return rc;
    }

    int replayfd = -1;
    if (replaypath) {
        replayfd = open(replaypath, O_RDWR);
        if (replayfd < 0) {
            perror("open replay");
            return 1;
        }
    }

    if (vol_mark || vol_token || vol_fua >= 0) {
        if (replayfd < 0) {
            fprintf(stderr, "--volatile-cut-* needs --replay <dev>\n");
            return 2;
        }
        if ((vol_mark != NULL) + (vol_token != NULL) + (vol_fua >= 0) > 1) {
            fprintf(stderr, "--volatile-cut-mark, -token and -fua are one cut\n");
            return 2;
        }
        vol_rng = vol_seed ? vol_seed : 1; /* xorshift state must be nonzero */
        int rc = replay_volatile(logfd, replayfd, nr_entries, ss, vol_mark, vol_fua, vol_token, vol_mode);
        close(replayfd);
        close(logfd);
        return rc;
    }
    if (reorder_after >= 0) {
        if (replayfd < 0) {
            fprintf(stderr, "--reorder-after-fua needs --replay <dev>\n");
            return 2;
        }
        if (!data_start_lba || !journal_start_lba || !journal_blocks) {
            fprintf(stderr, "--reorder-after-fua needs --data-start, --journal-start, --journal-blocks\n");
            return 2;
        }
        int rc = replay_reorder(logfd, replayfd, nr_entries, ss, reorder_after,
                                data_start_lba, journal_start_lba, journal_blocks);
        close(replayfd);
        close(logfd);
        return rc;
    }

    off_t pos = ss; /* entries start after the super sector */
    uint64_t fua_seen = 0, applied = 0;
    uint8_t hdr[32];
    uint8_t *data = NULL;
    size_t data_cap = 0;

    for (uint64_t i = 0; i < nr_entries; i++) {
        if (read_at(logfd, hdr, sizeof(hdr), pos)) {
            fprintf(stderr, "truncated log at entry %llu\n", (unsigned long long) i);
            break;
        }
        uint64_t sector = rd64(hdr);
        uint64_t nr = rd64(hdr + 8);
        uint64_t flags = rd64(hdr + 16);
        uint64_t data_len = rd64(hdr + 24);

        off_t hdr_region = (off_t) roundup(32 + data_len, ss);
        off_t data_off = pos + hdr_region;
        off_t blk_bytes = (off_t) nr * ss;
        int is_barrier = (flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG)) != 0;

        if (entry_of_mark && (flags & LOG_MARK_FLAG) && data_len) {
            char name[256];
            size_t n = data_len < sizeof(name) - 1 ? data_len : sizeof(name) - 1;
            if (!read_at(logfd, name, n, pos + 32)) {
                name[n] = '\0';
                if (!strcmp(name, entry_of_mark)) {
                    printf("%llu\n", (unsigned long long) i);
                    close(logfd);
                    return 0;
                }
            }
        }

        if (count_marks && (flags & LOG_MARK_FLAG) && data_len) {
            char name[256];
            size_t n = data_len < sizeof(name) - 1 ? data_len : sizeof(name) - 1;
            if (!read_at(logfd, name, n, pos + 32)) {
                name[n] = '\0';
                printf("%llu %s\n", (unsigned long long) fua_seen, name);
            }
        }

        /* Stop point: --end-mark replays everything BEFORE the named mark. */
        if (end_mark && (flags & LOG_MARK_FLAG) && data_len) {
            char name[256];
            size_t n = data_len < sizeof(name) - 1 ? data_len : sizeof(name) - 1;
            if (!read_at(logfd, name, n, pos + 32)) {
                name[n] = '\0';
                if (!strcmp(name, end_mark))
                    break;
            }
        }

        /* Apply block data (a real write, or a FUA write that also barriers).
         * DISCARD carries no data; MARK/FLUSH-only have nr==0. */
        if (replayfd >= 0 && (flags & LOG_DISCARD_FLAG) && nr > 0) {
            /* model a completed discard as zeroed blocks */
            static uint8_t z[1 << 16];
            off_t left = blk_bytes, at = (off_t) sector * ss;
            while (left > 0) {
                off_t chunk = left < (off_t) sizeof(z) ? left : (off_t) sizeof(z);
                if (write_at(replayfd, z, chunk, at)) { perror("discard zero"); return 1; }
                at += chunk; left -= chunk;
            }
        }
        if (replayfd >= 0 && nr > 0 && !(flags & LOG_DISCARD_FLAG)) {
            if ((size_t) blk_bytes > data_cap) {
                free(data);
                data = malloc(blk_bytes);
                if (!data) {
                    fprintf(stderr, "oom\n");
                    return 1;
                }
                data_cap = blk_bytes;
            }
            if (read_at(logfd, data, blk_bytes, data_off)) {
                fprintf(stderr, "truncated data at entry %llu\n", (unsigned long long) i);
                break;
            }
            if (write_at(replayfd, data, blk_bytes, (off_t) sector * ss)) {
                perror("write replay");
                return 1;
            }
            applied++;
        }

        if (is_barrier) {
            fua_seen++;
            if (limit_fua >= 0 && (long) fua_seen >= limit_fua)
                break; /* replayed up to and including this barrier */
        }

        /* DISCARD carries a range (nr_sectors) but NO data bytes in the log,
         * so it does not advance past any data -- only the header region.
         * Treating it like a write desyncs the whole log (mkfs issues TRIM). */
        pos = data_off + ((flags & LOG_DISCARD_FLAG) ? 0 : blk_bytes);
        if (limit_entries >= 0 && (long) (i + 1) >= limit_entries)
            break; /* replayed the first N entries, a cut between two writes */
    }

    if (replayfd >= 0) {
        fsync(replayfd);
        close(replayfd);
    }
    free(data);
    close(logfd);

    if (entry_of_mark) {
        fprintf(stderr, "no mark named '%s' in the log\n", entry_of_mark);
        return 1;
    }
    if (count_fua)
        printf("%llu\n", (unsigned long long) fua_seen);
    else if (count_entries)
        printf("%llu\n", (unsigned long long) nr_entries);
    else if (replaypath)
        fprintf(stderr, "replayed %llu block-write entries (through %llu barrier[s])\n",
                (unsigned long long) applied, (unsigned long long) fua_seen);
    return 0;
}
