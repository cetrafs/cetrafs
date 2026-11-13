// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * fsx_cetra -- a seeded random stream of data operations on ONE file,
 * checked against an in-memory model of what the file must contain.
 *
 * The operation mix is the fsx family's: buffered read and write, mapped
 * read and write, truncate, fallocate (allocate, keep-size, punch-hole,
 * zero-range with and without keep-size), O_DIRECT read and write, fsync,
 * and close-and-reopen. Every read is compared with the model as it is
 * made, the file's size is compared after every operation, and the whole
 * file is compared every check_every operations and once more at the end.
 *
 * Written here rather than vendored: the project does not carry
 * third-party test code, and the model is the part that has to be right.
 *
 * usage: fsx_cetra <file> <seed> <ops> [maxsize=4194304] [check_every=500]
 *
 * Replay: the operation stream is a pure function of <seed> and the
 * arguments, so a run that fails at op N with seed S fails at op N again
 * when re-run with the same arguments. The failure report names all of
 * them, and the last RING operations leading to it.
 *
 * Environment:
 *   FSX_NEGATIVE=N   the NEGATIVE CONTROL. From op N on, the first
 *                    write-class operation corrupts one byte of the MODEL
 *                    (never the file) and reads that byte back at once.
 *                    The run must then fail with exit 1. Exit 3 means the
 *                    control never fired, which is a setup failure, not a
 *                    pass.
 *   FSX_DUMP=path    write the model's final contents to path, outside the
 *                    filesystem under test, for a byte compare after a
 *                    remount.
 *   FSX_DROPCACHE=1  as root, drop the page cache before each full check,
 *                    so the check reads back off the device.
 *
 * Exit: 0 pass, 1 mismatch (the model and the filesystem disagree), 2 usage
 * or an I/O error on an operation that must succeed, 3 negative control
 * did not fire.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/falloc.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define BLK 4096ULL
#define CHUNK 65536ULL
#define RING 16

enum kind {
	K_READ,
	K_WRITE,
	K_MREAD,
	K_MWRITE,
	K_TRUNC,
	K_FALLOC,
	K_PUNCH,
	K_ZERO,
	K_DREAD,
	K_DWRITE,
	K_FSYNC,
	K_REOPEN,
	K_VERIFY,
	K_N
};
static const char *kname[K_N] = {
	"read", "write", "mread", "mwrite", "trunc", "falloc", "punch",
	"zero", "dread", "dwrite", "fsync", "reopen", "verify",
};

static const char *g_path, *g_seed_s;
static unsigned long long g_ops, g_maxsize, g_check_every;
static uint8_t *model;	/* bytes at and beyond msize are always zero */
static uint64_t msize, maxsize;
static uint64_t counts[K_N];
static struct {
	uint64_t op;
	char text[128];
} ring[RING];
static uint64_t nring, op;
static int fd = -1, dfd = -1;
static uint64_t rs;
static int64_t neg_from = -1;
static int neg_done;
static int dropcache;

static uint64_t rnd(void)
{
	/* splitmix64: deterministic across hosts, unlike rand(). */
	uint64_t z = (rs += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

static uint64_t below(uint64_t n)
{
	return n ? rnd() % n : 0;
}

/* A length in [1, min(avail, CHUNK)]; avail must be >= 1. */
static uint64_t span(uint64_t avail)
{
	return 1 + below(avail < CHUNK ? avail : CHUNK);
}

static void fillrnd(uint8_t *b, uint64_t n)
{
	for (uint64_t i = 0; i < n; i++)
		b[i] = (uint8_t)rnd();
}

static void record(int kind, const char *fmt, ...)
{
	va_list ap;
	int i = (int)(nring % RING);

	(void)kind;
	ring[i].op = op;
	va_start(ap, fmt);
	vsnprintf(ring[i].text, sizeof(ring[i].text), fmt, ap);
	va_end(ap);
	nring++;
}

static void fail(const char *fmt, ...)
{
	va_list ap;
	uint64_t first = nring > RING ? nring - RING : 0;

	printf("FSX MISMATCH seed=%s op=%llu: ", g_seed_s, (unsigned long long)op);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\nFSX replay: fsx_cetra %s %s %llu %llu %llu\n", g_path, g_seed_s,
	       g_ops, g_maxsize, g_check_every);
	printf("FSX last ops (oldest first):\n");
	for (uint64_t k = first; k < nring; k++)
		printf("  op %llu: %s\n", (unsigned long long)ring[k % RING].op,
		       ring[k % RING].text);
	fflush(stdout);
	exit(1);
}

static void ioerr(const char *what)
{
	printf("FSX I/O ERROR at op %llu: %s: %s\n", (unsigned long long)op, what,
	       strerror(errno));
	fflush(stdout);
	exit(2);
}

static void check_bytes(const char *what, uint64_t off, const uint8_t *got,
			uint64_t len)
{
	for (uint64_t i = 0; i < len; i++)
		if (got[i] != model[off + i])
			fail("%s: byte %llu differs: model 0x%02x, file 0x%02x", what,
			     (unsigned long long)(off + i), model[off + i], got[i]);
}

static void check_size(void)
{
	struct stat st;

	if (fstat(fd, &st))
		ioerr("fstat");
	if ((uint64_t)st.st_size != msize)
		fail("size: model %llu, file %llu", (unsigned long long)msize,
		     (unsigned long long)st.st_size);
}

static void full_check(void)
{
	uint8_t *buf = malloc(CHUNK);

	record(K_VERIFY, "full check of %llu bytes", (unsigned long long)msize);
	if (dropcache) {
		int c = open("/proc/sys/vm/drop_caches", O_WRONLY);

		if (c >= 0) {
			if (write(c, "1\n", 2) != 2) {
				/* best effort: the check is still valid, just warmer */
			}
			close(c);
		}
	}
	for (uint64_t off = 0; off < msize; off += CHUNK) {
		uint64_t len = msize - off < CHUNK ? msize - off : CHUNK;
		ssize_t n = pread(fd, buf, len, off);

		if (n < 0)
			ioerr("full check read");
		if ((uint64_t)n != len)
			fail("full check read at %llu returned %zd of %llu",
			     (unsigned long long)off, n, (unsigned long long)len);
		check_bytes("full check", off, buf, len);
	}
	free(buf);
	counts[K_VERIFY]++;
}

/* The negative control: corrupt one MODEL byte, then read it back. */
static void negative_point(uint64_t off)
{
	uint8_t b;

	if (neg_done || neg_from < 0 || (int64_t)op < neg_from || off >= msize)
		return;
	neg_done = 1;
	model[off] ^= 0x5a;
	record(-1, "NEGATIVE CONTROL: model byte %llu corrupted on purpose",
	       (unsigned long long)off);
	if (pread(fd, &b, 1, off) != 1)
		ioerr("negative control read");
	check_bytes("negative control", off, &b, 1);
}

static void op_read(void)
{
	uint8_t *buf;
	uint64_t off, len;
	ssize_t n;

	if (!msize)
		return;
	off = below(msize);
	len = span(msize - off);
	record(K_READ, "read off=%llu len=%llu", (unsigned long long)off,
	       (unsigned long long)len);
	buf = malloc(len);
	n = pread(fd, buf, len, off);
	if (n < 0)
		ioerr("read");
	if ((uint64_t)n != len)
		fail("read at %llu returned %zd of %llu", (unsigned long long)off, n,
		     (unsigned long long)len);
	check_bytes("read", off, buf, len);
	free(buf);
	counts[K_READ]++;
}

static void op_write(void)
{
	uint64_t off = below(maxsize), len = span(maxsize - off);
	uint8_t *buf;
	ssize_t n;

	if (off + len > maxsize)
		len = maxsize - off;
	record(K_WRITE, "write off=%llu len=%llu", (unsigned long long)off,
	       (unsigned long long)len);
	buf = malloc(len);
	fillrnd(buf, len);
	n = pwrite(fd, buf, len, off);
	if (n < 0)
		ioerr("write");
	if ((uint64_t)n != len)
		fail("write at %llu returned %zd of %llu", (unsigned long long)off, n,
		     (unsigned long long)len);
	memcpy(model + off, buf, len);
	if (off + len > msize)
		msize = off + len;
	free(buf);
	counts[K_WRITE]++;
	negative_point(off);
}

/* Mapped read, or mapped write (MAP_SHARED, then the store is coherent with
 * read(2) through the page cache). The mapping covers whole pages, but only
 * bytes below msize are touched, so no access lands past EOF. */
static void op_mmap(int write)
{
	uint64_t off, len, pg, end, maplen;
	uint8_t *p, *buf;
	int kind = write ? K_MWRITE : K_MREAD;

	if (!msize)
		return;
	off = below(msize);
	len = span(msize - off);
	pg = off & ~(BLK - 1);
	end = off + len;
	maplen = ((end + BLK - 1) & ~(BLK - 1)) - pg;
	record(kind, "%s off=%llu len=%llu", write ? "mmap write" : "mmap read",
	       (unsigned long long)off, (unsigned long long)len);
	p = mmap(NULL, maplen, write ? (PROT_READ | PROT_WRITE) : PROT_READ,
		 MAP_SHARED, fd, (off_t)pg);
	if (p == MAP_FAILED)
		ioerr("mmap");
	if (write) {
		buf = malloc(len);
		fillrnd(buf, len);
		memcpy(p + (off - pg), buf, len);
		memcpy(model + off, buf, len);
		free(buf);
		if (below(2) && msync(p, maplen, MS_SYNC))
			ioerr("msync");
		counts[kind]++;
	} else {
		check_bytes("mapped read", off, p + (off - pg), len);
		counts[kind]++;
	}
	munmap(p, maplen);
}

static void op_trunc(void)
{
	uint64_t n = below(maxsize + 1);

	record(K_TRUNC, "truncate to %llu (was %llu)", (unsigned long long)n,
	       (unsigned long long)msize);
	if (ftruncate(fd, (off_t)n))
		ioerr("ftruncate");
	if (n < msize)
		memset(model + n, 0, msize - n);
	msize = n;
	counts[K_TRUNC]++;
}

static void op_falloc(void)
{
	uint64_t off = below(maxsize), len = 1 + below(4 * CHUNK);
	int keep = below(2) ? FALLOC_FL_KEEP_SIZE : 0;

	if (off + len > maxsize)
		len = maxsize - off;
	record(K_FALLOC, "fallocate mode=%s off=%llu len=%llu",
	       keep ? "keep" : "allocate", (unsigned long long)off,
	       (unsigned long long)len);
	if (fallocate(fd, keep, (off_t)off, (off_t)len))
		ioerr("fallocate");
	if (!keep && off + len > msize)
		msize = off + len;
	counts[K_FALLOC]++;
}

/* PUNCH_HOLE is always KEEP_SIZE: the bytes read back as zero, the size
 * does not move. */
static void op_punch(void)
{
	uint64_t off = below(maxsize), len = span(maxsize - off);

	if (off + len > maxsize)
		len = maxsize - off;
	record(K_PUNCH, "punch off=%llu len=%llu", (unsigned long long)off,
	       (unsigned long long)len);
	if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, (off_t)off,
		      (off_t)len))
		ioerr("punch");
	memset(model + off, 0, len);
	counts[K_PUNCH]++;
	negative_point(off);
}

/* ZERO_RANGE extends the file unless KEEP_SIZE is given, like allocate. */
static void op_zero(void)
{
	uint64_t off = below(maxsize), len = span(maxsize - off);
	int keep = below(2) ? FALLOC_FL_KEEP_SIZE : 0;

	if (off + len > maxsize)
		len = maxsize - off;
	record(K_ZERO, "zero-range %s off=%llu len=%llu", keep ? "keep" : "extend",
	       (unsigned long long)off, (unsigned long long)len);
	if (fallocate(fd, FALLOC_FL_ZERO_RANGE | keep, (off_t)off, (off_t)len))
		ioerr("zero-range");
	memset(model + off, 0, len);
	if (!keep && off + len > msize)
		msize = off + len;
	counts[K_ZERO]++;
	negative_point(off);
}

static void op_dread(void)
{
	uint64_t lim, start, len, want, nblk;
	void *buf;
	ssize_t n;

	if (!msize)
		return;
	lim = (msize + BLK - 1) & ~(BLK - 1);
	start = below(lim) & ~(BLK - 1);
	if (start >= msize)
		return;
	nblk = 1 + below(8);
	len = nblk * BLK;
	if (start + len > lim)
		len = lim - start;
	want = msize - start < len ? msize - start : len;
	record(K_DREAD, "O_DIRECT read off=%llu len=%llu",
	       (unsigned long long)start, (unsigned long long)len);
	if (posix_memalign(&buf, BLK, len))
		ioerr("posix_memalign");
	n = pread(dfd, buf, len, start);
	if (n < 0)
		ioerr("O_DIRECT read");
	if ((uint64_t)n != want)
		fail("O_DIRECT read at %llu returned %zd, model says %llu",
		     (unsigned long long)start, n, (unsigned long long)want);
	check_bytes("O_DIRECT read", start, buf, want);
	free(buf);
	counts[K_DREAD]++;
}

static void op_dwrite(void)
{
	uint64_t start = below(maxsize) & ~(BLK - 1), len;
	void *buf;
	ssize_t n;

	len = (1 + below(8)) * BLK;
	if (start + len > maxsize)
		len = maxsize - start;
	record(K_DWRITE, "O_DIRECT write off=%llu len=%llu",
	       (unsigned long long)start, (unsigned long long)len);
	if (posix_memalign(&buf, BLK, len))
		ioerr("posix_memalign");
	fillrnd(buf, len);
	n = pwrite(dfd, buf, len, start);
	if (n < 0)
		ioerr("O_DIRECT write");
	if ((uint64_t)n != len)
		fail("O_DIRECT write at %llu returned %zd of %llu",
		     (unsigned long long)start, n, (unsigned long long)len);
	memcpy(model + start, buf, len);
	if (start + len > msize)
		msize = start + len;
	free(buf);
	counts[K_DWRITE]++;
	negative_point(start);
}

static void op_fsync(void)
{
	record(K_FSYNC, "fsync");
	if (fsync(fd))
		ioerr("fsync");
	counts[K_FSYNC]++;
}

static void op_reopen(void)
{
	record(K_REOPEN, "close and reopen (buffered and O_DIRECT)");
	close(fd);
	close(dfd);
	fd = open(g_path, O_RDWR);
	if (fd < 0)
		ioerr("reopen");
	dfd = open(g_path, O_RDWR | O_DIRECT);
	if (dfd < 0)
		ioerr("reopen O_DIRECT");
	counts[K_REOPEN]++;
}

int main(int argc, char **argv)
{
	const char *ng = getenv("FSX_NEGATIVE"), *dump = getenv("FSX_DUMP");
	unsigned long long check_every = 500;

	if (argc < 4 || argc > 6) {
		fprintf(stderr,
			"usage: %s <file> <seed> <ops> [maxsize=4194304] [check_every=500]\n",
			argv[0]);
		return 2;
	}
	g_path = argv[1];
	g_seed_s = argv[2];
	g_ops = strtoull(argv[3], NULL, 0);
	g_maxsize = argc > 4 ? strtoull(argv[4], NULL, 0) : 4ULL << 20;
	if (argc > 5)
		check_every = strtoull(argv[5], NULL, 0);
	g_check_every = check_every;
	if (g_maxsize < BLK || g_maxsize % BLK || g_maxsize > (1ULL << 30) ||
	    check_every == 0) {
		fprintf(stderr, "fsx_cetra: maxsize must be a multiple of 4096 in [4096, 1 GiB]\n");
		return 2;
	}
	maxsize = g_maxsize;
	rs = strtoull(argv[2], NULL, 0) * 0x2545f4914f6cdd1dULL + 1;
	if (ng && *ng)
		neg_from = (int64_t)strtoll(ng, NULL, 0);
	dropcache = getenv("FSX_DROPCACHE") && *getenv("FSX_DROPCACHE") == '1';

	model = calloc(1, maxsize);
	fd = open(g_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open");
		return 2;
	}
	dfd = open(g_path, O_RDWR | O_DIRECT);
	if (dfd < 0) {
		perror("open O_DIRECT");
		return 2;
	}
	printf("FSX start seed=%s ops=%llu maxsize=%llu check_every=%llu%s\n",
	       g_seed_s, g_ops, g_maxsize, check_every,
	       neg_from >= 0 ? " NEGATIVE CONTROL armed" : "");

	for (op = 0; op < g_ops; op++) {
		uint64_t r = below(100);

		if (r < 14)
			op_read();
		else if (r < 34)
			op_write();
		else if (r < 44)
			op_mmap(0);
		else if (r < 52)
			op_mmap(1);
		else if (r < 57)
			op_trunc();
		else if (r < 65)
			op_falloc();
		else if (r < 70)
			op_punch();
		else if (r < 75)
			op_zero();
		else if (r < 82)
			op_dread();
		else if (r < 90)
			op_dwrite();
		else if (r < 94)
			op_fsync();
		else if (r < 98)
			op_reopen();
		else
			op_read();
		check_size();
		if ((op + 1) % check_every == 0)
			full_check();
	}
	full_check();

	if (neg_from >= 0 && !neg_done) {
		printf("FSX NEGATIVE CONTROL DID NOT FIRE (from op %lld)\n",
		       (long long)neg_from);
		return 3;
	}
	if (dump) {
		FILE *f = fopen(dump, "wb");

		if (!f || fwrite(model, 1, msize, f) != msize) {
			perror("FSX_DUMP");
			return 2;
		}
		fclose(f);
	}
	printf("COUNTS");
	for (int k = 0; k < K_N; k++)
		printf(" %s=%llu", kname[k], (unsigned long long)counts[k]);
	printf("\nFSX PASS seed=%s ops=%llu size=%llu\n", g_seed_s, g_ops,
	       (unsigned long long)msize);
	close(fd);
	close(dfd);
	return 0;
}
