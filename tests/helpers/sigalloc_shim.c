// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * sigalloc_shim.c -- test-only LD_PRELOAD library: report every heap
 * allocator call made while a signal handler is running.
 *
 * sigaction() is wrapped so each installed handler runs inside a
 * trampoline that marks "in a handler"; malloc, calloc, realloc, free and
 * posix_memalign check the mark and, when it is up, write one line
 * "SIGALLOC <fn> sig=<n>" to stderr with write(2) -- the process may be
 * about to die by the very signal being handled, so nothing is buffered.
 * The real allocators are glibc's __libc_* entry points, which need no
 * dlsym() (dlsym itself allocates). The repair tools' handlers must
 * never reach the allocator: a tick that lands inside the main line's
 * malloc re-enters it (audit 2026-11-22 N-2).
 *
 * Build: cc -shared -fPIC -o sigalloc_shim.so sigalloc_shim.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void __libc_free(void *);
extern void *__libc_memalign(size_t, size_t);

static volatile sig_atomic_t in_handler, cur_sig;
static void (*real_handler[65])(int);

static void note(const char *fn)
{
    char line[64] = "SIGALLOC ";
    size_t n = strlen(line), i;
    int s = cur_sig;
    char d[8];
    int k = 0;

    for (i = 0; fn[i] && n < sizeof(line) - 16; i++)
        line[n++] = fn[i];
    memcpy(line + n, " sig=", 5);
    n += 5;
    do
        d[k++] = (char) ('0' + s % 10);
    while ((s /= 10) && k < 7);
    while (k)
        line[n++] = d[--k];
    line[n++] = '\n';
    (void) !write(2, line, n);
}

static void trampoline(int sig)
{
    sig_atomic_t was = in_handler, was_sig = cur_sig;

    in_handler = 1;
    cur_sig = sig;
    if (sig > 0 && sig < 65 && real_handler[sig])
        real_handler[sig](sig);
    in_handler = was;
    cur_sig = was_sig;
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    static int (*real)(int, const struct sigaction *, struct sigaction *);
    struct sigaction mine;

    if (!real)
        real = (int (*)(int, const struct sigaction *, struct sigaction *)) dlsym(RTLD_NEXT, "sigaction");
    if (act && !(act->sa_flags & SA_SIGINFO) && act->sa_handler != SIG_DFL && act->sa_handler != SIG_IGN &&
        act->sa_handler != trampoline && sig > 0 && sig < 65) {
        real_handler[sig] = act->sa_handler;
        mine = *act;
        mine.sa_handler = trampoline;
        act = &mine;
    }
    return real(sig, act, old);
}

void *malloc(size_t n)
{
    if (in_handler)
        note("malloc");
    return __libc_malloc(n);
}

void *calloc(size_t a, size_t b)
{
    if (in_handler)
        note("calloc");
    return __libc_calloc(a, b);
}

void *realloc(void *p, size_t n)
{
    if (in_handler)
        note("realloc");
    return __libc_realloc(p, n);
}

void free(void *p)
{
    if (in_handler && p)
        note("free");
    __libc_free(p);
}

int posix_memalign(void **out, size_t align, size_t n)
{
    void *p;

    if (in_handler)
        note("posix_memalign");
    p = __libc_memalign(align, n);
    if (!p)
        return 12; /* ENOMEM */
    *out = p;
    return 0;
}
