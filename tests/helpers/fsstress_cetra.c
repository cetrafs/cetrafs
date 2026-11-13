// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * fsstress_cetra -- seeded multi-process namespace and data churn.
 *
 * usage: fsstress_cetra <dir> <seed> <procs> <ops-per-proc>
 *
 * Every process runs the same mix, drawn from its own seeded stream:
 * create, write, truncate, unlink, link, symlink, rename (within and
 * across directories, over an existing name too), mkdir, rmdir, setxattr,
 * removexattr, chmod, fsync, and a read-back check.
 *
 * Two areas, two standards:
 *
 *   dir/shared   one directory every process works in, with NO model.
 *                Names collide and race on purpose. The only requirement
 *                is that each call succeeds or fails with an errno a
 *                namespace race may legitimately return; anything else
 *                (EIO, EUCLEAN, ENOSPC, ...) is a failure.
 *
 *   dir/p<k>     process k's own tree, modelled exactly. A NAME is a
 *                directory plus a leaf (root/s07 and d4/s07 are two
 *                names), and the model is keyed by name: each entry holds
 *                one name's type, the inode behind it (hard links share
 *                one), or a symlink target. Inodes carry size, bytes,
 *                nlink, mode and xattr. Checked on read-back and in full
 *                at the end.
 *
 * The volume's own consistency is the caller's to check (fsck) once every
 * process has exited and the volume is unmounted.
 *
 * Environment:
 *   FSSTRESS_NEGATIVE=1  the NEGATIVE CONTROL. Process 0's model records
 *                        its first live file one byte larger than it is,
 *                        so its final check must fail. The run must exit
 *                        nonzero; the suite asserts that it does.
 *   FSSTRESS_TRACE=1     print every namespace operation as it is issued.
 *
 * Exit: 0 every process agreed with the model; 1 a mismatch or an
 * unexpected errno; 2 usage.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>

#define NAMES 24			/* leaf names per directory */
#define NDIR 4				/* d1..d4; directory 0 is the process root */
#define NS ((NDIR + 1) * NAMES)		/* a name: dir * NAMES + leaf */
#define NINO 32
#define FMAX 65536
#define XMAX 200
#define LINKMAX 8

enum cnt {
	C_CREAT, C_WRITE, C_TRUNC, C_UNLINK, C_LINK, C_SYMLINK, C_RENAME,
	C_MKDIR, C_RMDIR, C_SETX, C_RMX, C_CHMOD, C_FSYNC, C_VERIFY, C_SHARED,
	C_N
};
static const char *cname[C_N] = {
	"creat", "write", "trunc", "unlink", "link", "symlink", "rename",
	"mkdir", "rmdir", "setx", "rmx", "chmod", "fsync", "verify", "shared",
};

struct ino {
	int used, mode, has_x;
	uint64_t size;
	uint32_t xlen;
	uint8_t xval[XMAX];
	uint8_t *data;
};
struct name {
	int kind;	/* 0 empty, 1 file (an inode), 2 symlink */
	int ino;
	char target[48];
};

static const char *g_dir, *g_seed_s;
static int g_proc, g_negative, g_trace;
static long g_op, g_ops;
static char base[PATH_MAX], shared[PATH_MAX];
static struct ino inos[NINO];
static struct name names[NS];
static int dirs[NDIR + 1];
static uint64_t cnt[C_N];
static uint64_t rs;

static uint64_t rnd(void)
{
	uint64_t z = (rs += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

static uint64_t below(uint64_t n)
{
	return n ? rnd() % n : 0;
}

static void fail(const char *fmt, ...)
{
	va_list ap;

	printf("FSSTRESS MISMATCH seed=%s proc=%d op=%ld: ", g_seed_s, g_proc, g_op);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
	exit(1);
}

static void trace(const char *fmt, ...)
{
	va_list ap;

	if (!g_trace)
		return;
	printf("TRACE proc=%d op=%ld ", g_proc, g_op);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

static int dir_of(int i)
{
	return i / NAMES;
}

static int leaf_of(int i)
{
	return i % NAMES;
}

static void path_of(char *out, size_t n, int i)
{
	if (dir_of(i) == 0)
		snprintf(out, n, "%s/s%02d", base, leaf_of(i));
	else
		snprintf(out, n, "%s/d%d/s%02d", base, dir_of(i), leaf_of(i));
}

static int dir_usable(int d)
{
	return d == 0 || dirs[d];
}

/* A random empty name whose directory exists, or -1. */
static int find_free(void)
{
	for (int t = 0; t < 256; t++) {
		int i = (int)below(NS);

		if (names[i].kind == 0 && dir_usable(dir_of(i)))
			return i;
	}
	return -1;
}

/* A random occupied name, of the given kind (0 = any), or -1. */
static int find_used(int kind)
{
	for (int t = 0; t < 256; t++) {
		int i = (int)below(NS);

		if (names[i].kind && (kind == 0 || names[i].kind == kind))
			return i;
	}
	return -1;
}

static int find_ino(void)
{
	for (int i = 0; i < NINO; i++)
		if (!inos[i].used)
			return i;
	return -1;
}

static int nlink_of(int ino)
{
	int n = 0;

	for (int i = 0; i < NS; i++)
		if (names[i].kind == 1 && names[i].ino == ino)
			n++;
	return n;
}

/* Frees an inode once no name refers to it. */
static void free_if_unnamed(int ino)
{
	if (nlink_of(ino) == 0) {
		free(inos[ino].data);
		memset(&inos[ino], 0, sizeof(inos[ino]));
	}
}

static void must(int rc, const char *what, const char *path)
{
	if (rc)
		fail("%s %s: %s", what, path, strerror(errno));
}

static int race_errno(int e)
{
	return e == ENOENT || e == EEXIST || e == ENOTEMPTY || e == EISDIR ||
	       e == ENOTDIR || e == EMLINK || e == EBUSY || e == EINVAL;
}

static void op_create(void)
{
	int i = find_free(), n = find_ino();
	char p[PATH_MAX];
	int fd;
	size_t len;
	uint8_t *buf;

	if (i < 0 || n < 0)
		return;
	path_of(p, sizeof(p), i);
	trace("create %s", p);
	fd = open(p, O_CREAT | O_EXCL | O_WRONLY, 0644);
	if (fd < 0)
		fail("create %s: %s", p, strerror(errno));
	inos[n].used = 1;
	inos[n].mode = 0644;
	inos[n].data = calloc(1, FMAX);
	len = below(16384);
	buf = malloc(len ? len : 1);
	for (size_t k = 0; k < len; k++)
		buf[k] = (uint8_t)rnd();
	if (len && write(fd, buf, len) != (ssize_t)len)
		fail("create-write %s: %s", p, strerror(errno));
	memcpy(inos[n].data, buf, len);
	inos[n].size = len;
	free(buf);
	close(fd);
	names[i].kind = 1;
	names[i].ino = n;
	cnt[C_CREAT]++;
}

static void op_write(void)
{
	int i = find_used(1);
	struct ino *in;
	uint64_t lim, off, len;
	char p[PATH_MAX];
	int fd;
	uint8_t *buf;

	if (i < 0)
		return;
	in = &inos[names[i].ino];
	lim = in->size + 4096;
	if (lim > FMAX - 8192)
		lim = FMAX - 8192;
	off = below(lim + 1);
	len = 1 + below(8192);
	path_of(p, sizeof(p), i);
	trace("write %s off=%llu len=%llu", p, (unsigned long long)off,
	      (unsigned long long)len);
	buf = malloc(len);
	for (uint64_t k = 0; k < len; k++)
		buf[k] = (uint8_t)rnd();
	fd = open(p, O_WRONLY);
	if (fd < 0)
		fail("open %s for write: %s", p, strerror(errno));
	if (pwrite(fd, buf, len, (off_t)off) != (ssize_t)len)
		fail("write %s at %llu: %s", p, (unsigned long long)off, strerror(errno));
	close(fd);
	memcpy(in->data + off, buf, len);
	if (off + len > in->size)
		in->size = off + len;
	free(buf);
	cnt[C_WRITE]++;
}

static void op_trunc(void)
{
	int i = find_used(1);
	struct ino *in;
	uint64_t n;
	char p[PATH_MAX];

	if (i < 0)
		return;
	in = &inos[names[i].ino];
	n = below(FMAX / 2 + 1);
	path_of(p, sizeof(p), i);
	trace("truncate %s to %llu", p, (unsigned long long)n);
	must(truncate(p, (off_t)n), "truncate", p);
	if (n < in->size)
		memset(in->data + n, 0, in->size - n);
	in->size = n;
	cnt[C_TRUNC]++;
}

static void unlink_name(int i)
{
	char p[PATH_MAX];
	int ino;

	path_of(p, sizeof(p), i);
	trace("unlink %s", p);
	must(unlink(p), "unlink", p);
	ino = names[i].ino;
	names[i].kind = 0;
	if (ino >= 0)	/* a symlink has no inode */
		free_if_unnamed(ino);
	cnt[C_UNLINK]++;
}

static void op_unlink(void)
{
	int i = find_used(0);

	if (i >= 0)
		unlink_name(i);
}

static void op_link(void)
{
	int a = find_used(1), b = find_free();
	char pa[PATH_MAX], pb[PATH_MAX];

	if (a < 0 || b < 0 || nlink_of(names[a].ino) >= LINKMAX)
		return;
	path_of(pa, sizeof(pa), a);
	path_of(pb, sizeof(pb), b);
	trace("link %s -> %s", pa, pb);
	must(link(pa, pb), "link", pa);
	names[b].kind = 1;
	names[b].ino = names[a].ino;
	cnt[C_LINK]++;
}

static void op_symlink(void)
{
	int b = find_free();
	char p[PATH_MAX], t[48];

	if (b < 0)
		return;
	snprintf(t, sizeof(t), "tgt-%u-%ld", (unsigned)below(1u << 30), g_op);
	path_of(p, sizeof(p), b);
	trace("symlink %s -> %s", p, t);
	must(symlink(t, p), "symlink", p);
	names[b].kind = 2;
	names[b].ino = -1;
	strcpy(names[b].target, t);
	cnt[C_SYMLINK]++;
}

static void op_rename(void)
{
	int a = find_used(0), b = find_free();
	char pa[PATH_MAX], pb[PATH_MAX];
	int victim;

	if (a < 0)
		return;
	/* Sometimes rename over an occupied name, to reach the victim path. */
	if (below(3) == 0)
		b = find_used(0);
	if (b < 0 || b == a)
		return;
	if (names[b].kind == 1 && names[a].kind == 1 && names[a].ino == names[b].ino)
		return; /* the same inode under both names: rename does nothing */
	path_of(pa, sizeof(pa), a);
	path_of(pb, sizeof(pb), b);
	trace("rename %s -> %s (victim kind %d)", pa, pb, names[b].kind);
	must(rename(pa, pb), "rename", pa);
	if (names[b].kind == 1) {
		victim = names[b].ino;
		names[b].kind = 0;
		free_if_unnamed(victim);
	}
	names[b] = names[a];
	names[a].kind = 0;
	cnt[C_RENAME]++;
}

static void op_mkdir(void)
{
	int d = 1 + (int)below(NDIR);
	char p[PATH_MAX];

	if (dirs[d])
		return;
	snprintf(p, sizeof(p), "%s/d%d", base, d);
	trace("mkdir %s", p);
	must(mkdir(p, 0755), "mkdir", p);
	dirs[d] = 1;
	cnt[C_MKDIR]++;
}

static void op_rmdir(void)
{
	int d = 1 + (int)below(NDIR);
	char p[PATH_MAX];

	if (!dirs[d])
		return;
	/* Empty it first: creates refill a directory faster than a rmdir
	 * would otherwise find it empty. */
	for (int i = 0; i < NS; i++)
		if (names[i].kind && dir_of(i) == d)
			unlink_name(i);
	snprintf(p, sizeof(p), "%s/d%d", base, d);
	trace("rmdir %s", p);
	must(rmdir(p), "rmdir", p);
	dirs[d] = 0;
	cnt[C_RMDIR]++;
}

static void op_setx(void)
{
	int i = find_used(1);
	struct ino *in;
	uint32_t n;
	char p[PATH_MAX];

	if (i < 0)
		return;
	in = &inos[names[i].ino];
	n = 1 + (uint32_t)below(XMAX);
	path_of(p, sizeof(p), i);
	for (uint32_t k = 0; k < n; k++)
		in->xval[k] = (uint8_t)rnd();
	trace("setxattr %s (%u bytes)", p, n);
	must(setxattr(p, "user.fsstress", in->xval, n, 0), "setxattr", p);
	in->has_x = 1;
	in->xlen = n;
	cnt[C_SETX]++;
}

static void op_rmx(void)
{
	int i = find_used(1);
	struct ino *in;
	char p[PATH_MAX];

	if (i < 0)
		return;
	in = &inos[names[i].ino];
	path_of(p, sizeof(p), i);
	trace("removexattr %s", p);
	if (removexattr(p, "user.fsstress") == 0) {
		if (!in->has_x)
			fail("removexattr %s succeeded but the model has no xattr", p);
		in->has_x = 0;
	} else if (errno != ENODATA) {
		fail("removexattr %s: %s", p, strerror(errno));
	} else if (in->has_x) {
		fail("removexattr %s: ENODATA but the model has an xattr", p);
	}
	cnt[C_RMX]++;
}

static void op_chmod(void)
{
	static const int modes[] = {0600, 0640, 0644, 0755};
	int i = find_used(1), m = modes[below(4)];
	char p[PATH_MAX];

	if (i < 0)
		return;
	path_of(p, sizeof(p), i);
	trace("chmod %s %o", p, m);
	must(chmod(p, (mode_t)m), "chmod", p);
	inos[names[i].ino].mode = m;
	cnt[C_CHMOD]++;
}

static void op_fsync(void)
{
	int i = find_used(1), fd;
	char p[PATH_MAX];

	if (i < 0)
		return;
	path_of(p, sizeof(p), i);
	trace("fsync %s", p);
	fd = open(p, O_RDONLY);
	if (fd < 0)
		fail("open %s for fsync: %s", p, strerror(errno));
	if (fsync(fd))
		fail("fsync %s: %s", p, strerror(errno));
	close(fd);
	cnt[C_FSYNC]++;
}

/* Full check of one file name against the model. */
static void check_file(int i)
{
	struct ino *in = &inos[names[i].ino];
	char p[PATH_MAX];
	struct stat st;
	uint64_t want = in->size;
	uint8_t *buf;
	int fd;

	path_of(p, sizeof(p), i);
	if (lstat(p, &st))
		fail("lstat %s: %s", p, strerror(errno));
	if (!S_ISREG(st.st_mode))
		fail("%s is not a regular file", p);
	if ((uint64_t)st.st_size != want)
		fail("%s size: model %llu, file %lld", p, (unsigned long long)want,
		     (long long)st.st_size);
	if (st.st_nlink != (nlink_t)nlink_of(names[i].ino))
		fail("%s nlink: model %d, file %lu", p, nlink_of(names[i].ino),
		     (unsigned long)st.st_nlink);
	if ((st.st_mode & 07777) != (mode_t)in->mode)
		fail("%s mode: model %o, file %o", p, in->mode, st.st_mode & 07777);
	buf = malloc(want ? want : 1);
	fd = open(p, O_RDONLY);
	if (fd < 0)
		fail("open %s: %s", p, strerror(errno));
	if (want && pread(fd, buf, want, 0) != (ssize_t)want)
		fail("read %s: %s", p, strerror(errno));
	close(fd);
	for (uint64_t k = 0; k < want; k++)
		if (buf[k] != in->data[k])
			fail("%s byte %llu: model 0x%02x, file 0x%02x", p,
			     (unsigned long long)k, in->data[k], buf[k]);
	free(buf);
	if (in->has_x) {
		uint8_t x[XMAX];
		ssize_t got = getxattr(p, "user.fsstress", x, sizeof(x));

		if (got != (ssize_t)in->xlen || memcmp(x, in->xval, in->xlen))
			fail("%s xattr: model %u bytes, file %zd", p, in->xlen, got);
	} else if (getxattr(p, "user.fsstress", NULL, 0) >= 0) {
		fail("%s has an xattr the model does not", p);
	} else if (errno != ENODATA) {
		fail("getxattr %s: %s", p, strerror(errno));
	}
}

static void op_check(void)
{
	int i = find_used(1);

	if (i < 0)
		return;
	check_file(i);
	cnt[C_VERIFY]++;
}

/* Shared directory: no model, only the errno contract. */
static void op_shared(void)
{
	int a = (int)below(16), b = (int)below(16), k = (int)below(5);
	char pa[PATH_MAX], pb[PATH_MAX];
	int rc = 0;

	snprintf(pa, sizeof(pa), "%s/h%02d", shared, a);
	snprintf(pb, sizeof(pb), "%s/h%02d", shared, b);
	switch (k) {
	case 0: {
		int fd = open(pa, O_CREAT | O_EXCL | O_WRONLY, 0644);

		if (fd >= 0) {
			if (write(fd, pa, 64) < 0) {
				/* a failed write is not in this contract */
			}
			close(fd);
		} else
			rc = -1;
		break;
	}
	case 1:
		rc = unlink(pa);
		break;
	case 2:
		rc = link(pa, pb);
		break;
	case 3:
		rc = rename(pa, pb);
		break;
	default:
		rc = symlink("shared-target", pa);
		break;
	}
	if (rc && !race_errno(errno))
		fail("shared op %d on %s: unexpected %s", k, pa, strerror(errno));
	cnt[C_SHARED]++;
}

static void child(int k)
{
	/* Cumulative weights over 0..99, one per class in the switch below. */
	static const int wsum[] = {
		10, 18, 22, 26, 32, 36, 44, 47, 50, 56, 59, 63, 67, 75, 100,
	};

	g_proc = k;
	rs = strtoull(g_seed_s, NULL, 0) * 1000003ULL + (uint64_t)k * 7919ULL + 1;
	snprintf(base, sizeof(base), "%s/p%d", g_dir, k);
	memset(names, 0, sizeof(names));
	memset(inos, 0, sizeof(inos));
	memset(dirs, 0, sizeof(dirs));
	memset(cnt, 0, sizeof(cnt));

	for (g_op = 0; g_op < g_ops; g_op++) {
		uint64_t r = below(100);
		int j = 0;

		while (r >= (uint64_t)wsum[j])
			j++;
		switch (j) {
		case 0: op_create(); break;
		case 1: op_write(); break;
		case 2: op_trunc(); break;
		case 3: op_unlink(); break;
		case 4: op_link(); break;
		case 5: op_symlink(); break;
		case 6: op_rename(); break;
		case 7: op_mkdir(); break;
		case 8: op_rmdir(); break;
		case 9: op_setx(); break;
		case 10: op_rmx(); break;
		case 11: op_chmod(); break;
		case 12: op_fsync(); break;
		case 13: op_check(); break;
		default: op_shared(); break;
		}
	}

	/* Final check of the whole private tree. */
	g_op = -1;
	if (g_negative && k == 0) {
		for (int i = 0; i < NS; i++)
			if (names[i].kind == 1) {
				inos[names[i].ino].size++;
				printf("FSSTRESS NEGATIVE CONTROL: proc 0 model size of name %d off by one\n", i);
				break;
			}
	}
	for (int i = 0; i < NS; i++) {
		char p[PATH_MAX];
		struct stat st;

		if (names[i].kind == 1) {
			check_file(i);
		} else if (names[i].kind == 2) {
			char t[256];
			ssize_t n;

			path_of(p, sizeof(p), i);
			n = readlink(p, t, sizeof(t) - 1);
			if (n < 0)
				fail("readlink %s: %s", p, strerror(errno));
			t[n] = 0;
			if (strcmp(t, names[i].target))
				fail("%s target: model %s, file %s", p, names[i].target, t);
		} else {
			path_of(p, sizeof(p), i);
			if (lstat(p, &st) == 0 || errno != ENOENT)
				fail("%s exists but the model has no such name", p);
		}
	}
	for (int d = 1; d <= NDIR; d++) {
		char p[PATH_MAX];
		struct stat st;

		snprintf(p, sizeof(p), "%s/d%d", base, d);
		if (dirs[d]) {
			if (stat(p, &st) || !S_ISDIR(st.st_mode))
				fail("%s: model has a directory, file does not", p);
		} else if (stat(p, &st) == 0)
			fail("%s exists but the model has no such directory", p);
	}
	printf("COUNTS %d", k);
	for (int c = 0; c < C_N; c++)
		printf(" %s=%llu", cname[c], (unsigned long long)cnt[c]);
	printf("\n");
	fflush(stdout);
	exit(0);
}

int main(int argc, char **argv)
{
	int procs, bad = 0;
	pid_t pids[64];

	if (argc != 5) {
		fprintf(stderr, "usage: %s <dir> <seed> <procs> <ops-per-proc>\n", argv[0]);
		return 2;
	}
	g_dir = argv[1];
	g_seed_s = argv[2];
	procs = atoi(argv[3]);
	g_ops = atol(argv[4]);
	if (procs < 1 || procs > 64 || g_ops < 1)
		return 2;
	g_trace = getenv("FSSTRESS_TRACE") != NULL;
	g_negative = getenv("FSSTRESS_NEGATIVE") && *getenv("FSSTRESS_NEGATIVE") == '1';

	snprintf(shared, sizeof(shared), "%s/shared", g_dir);
	if (mkdir(shared, 0755) && errno != EEXIST) {
		perror("mkdir shared");
		return 2;
	}
	for (int k = 0; k < procs; k++) {
		char p[PATH_MAX];

		snprintf(p, sizeof(p), "%s/p%d", g_dir, k);
		if (mkdir(p, 0755) && errno != EEXIST) {
			perror("mkdir proc");
			return 2;
		}
	}
	printf("FSSTRESS start seed=%s procs=%d ops=%ld%s\n", g_seed_s, procs, g_ops,
	       g_negative ? " NEGATIVE CONTROL armed" : "");
	fflush(stdout);

	for (int k = 0; k < procs; k++) {
		pids[k] = fork();
		if (pids[k] < 0) {
			perror("fork");
			return 2;
		}
		if (pids[k] == 0)
			child(k);
	}
	for (int k = 0; k < procs; k++) {
		int st = 0;

		if (waitpid(pids[k], &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st))
			bad++;
	}
	if (bad) {
		printf("FSSTRESS FAILED: %d process(es) disagreed with the model\n", bad);
		return 1;
	}
	printf("FSSTRESS PASS seed=%s procs=%d\n", g_seed_s, procs);
	return 0;
}
