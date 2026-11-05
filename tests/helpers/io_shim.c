// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * io_shim -- test-only LD_PRELOAD library: pread/pwrite inside a byte
 * window [SHIM_LO, SHIM_HI) behave as the kernel is allowed to make them
 * behave and a block device almost never does: the first of each fails
 * with EINTR having done nothing, and every one after transfers at most
 * half of what was asked. A tool whose I/O helpers loop and retry does
 * the same work; one that treats either as fatal stops.
 *
 * Built by the suite (cc -shared -fPIC ... -ldl), not by ct_helper. At
 * exit it prints "io_shim: eintr_r=N eintr_w=N split_r=N split_w=N" to
 * stderr so the suite can show the shim actually fired.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

static long long lo = -1, hi;
static int eintr_r, eintr_w;
static long split_r, split_w;

static void init(void)
{
    if (lo < 0) {
        const char *a = getenv("SHIM_LO"), *b = getenv("SHIM_HI");

        lo = a ? atoll(a) : 0;
        hi = b ? atoll(b) : 0;
    }
}

static int in(off_t off) { init(); return off >= lo && off < hi; }

__attribute__((destructor)) static void report(void)
{
    fprintf(stderr, "io_shim: eintr_r=%d eintr_w=%d split_r=%ld split_w=%ld\n", eintr_r, eintr_w, split_r, split_w);
}

#define WRAP_READ(name)                                                          \
    ssize_t name(int fd, void *buf, size_t n, off_t off)                         \
    {                                                                            \
        static ssize_t (*real)(int, void *, size_t, off_t);                      \
        if (!real)                                                               \
            real = (ssize_t (*)(int, void *, size_t, off_t)) dlsym(RTLD_NEXT, #name); \
        if (in(off) && n > 1) {                                                  \
            if (!eintr_r) { eintr_r = 1; errno = EINTR; return -1; }             \
            split_r++;                                                           \
            n /= 2;                                                              \
        }                                                                        \
        return real(fd, buf, n, off);                                            \
    }
#define WRAP_WRITE(name)                                                         \
    ssize_t name(int fd, const void *buf, size_t n, off_t off)                   \
    {                                                                            \
        static ssize_t (*real)(int, const void *, size_t, off_t);                \
        if (!real)                                                               \
            real = (ssize_t (*)(int, const void *, size_t, off_t)) dlsym(RTLD_NEXT, #name); \
        if (in(off) && n > 1) {                                                  \
            if (!eintr_w) { eintr_w = 1; errno = EINTR; return -1; }             \
            split_w++;                                                           \
            n /= 2;                                                              \
        }                                                                        \
        return real(fd, buf, n, off);                                            \
    }
WRAP_READ(pread)
WRAP_READ(pread64)
WRAP_WRITE(pwrite)
WRAP_WRITE(pwrite64)
