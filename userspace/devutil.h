/* SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
/*
 * devutil.h -- small shared helpers for the userspace tools (mkfs/fsck).
 *
 * cetrafs_device_mounted(): is this block device currently mounted
 * anywhere on this system? Both tools refuse to touch a mounted device
 * outright -- fsck reading structures the kernel is concurrently
 * mutating produces garbage "errors" at best, and mkfs writing under a
 * live mount destroys it; neither has a legitimate use, so there is no
 * override flag (mkfs's -f is about overwriting on-disk *data*, not
 * about racing a live kernel).
 *
 * Matching is by device number (st_rdev), not path string: the same
 * device is commonly reachable via several names (/dev/sda,
 * /dev/disk/by-id/..., a symlink), and /proc/self/mounts records
 * whichever one was used at mount time. That is a same-SYSTEM check
 * only, which on this project's real deployment (a shared iSCSI/FC LUN)
 * misses the case that matters most: another NODE having the volume
 * mounted right now. cetrafs_find_live_peer() below covers that by
 * reading what the peers themselves wrote -- the Node Registry.
 */
#ifndef CETRAFS_DEVUTIL_H
#define CETRAFS_DEVUTIL_H

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

/* Sleep the whole interval. sleep() returns early on any signal, and a
 * repair holds a SIGALRM timer for its renewals (below) -- a liveness
 * probe cut short by one would conclude "nobody is beating" from a
 * window too short to see a beat. */
static inline void cetrafs_sleep_full(unsigned secs)
{
    struct timespec ts = {.tv_sec = (time_t) secs, .tv_nsec = 0};

    while (nanosleep(&ts, &ts) != 0 && errno == EINTR)
        ;
}

/* Returns 1 (and copies the mountpoint into 'where') if 'dev' is a block
 * device currently mounted on this system, 0 otherwise (including when
 * 'dev' is a regular file image, which can't appear in /proc/self/mounts
 * under its own name). */
static inline int cetrafs_device_mounted(const char *dev, char *where, size_t where_len)
{
    struct stat devst, st;
    FILE *f;
    char src[4096], mnt[4096];
    int mounted = 0;

    if (stat(dev, &devst) != 0 || !S_ISBLK(devst.st_mode))
        return 0;

    f = fopen("/proc/self/mounts", "r");
    if (!f)
        return 0; /* can't tell -- fall through to the caller's own open-time errors */

    while (fscanf(f, "%4095s %4095s %*[^\n]", src, mnt) == 2) {
        if (stat(src, &st) != 0 || !S_ISBLK(st.st_mode))
            continue;
        if (st.st_rdev == devst.st_rdev) {
            if (where && where_len)
                snprintf(where, where_len, "%s", mnt);
            mounted = 1;
            break;
        }
    }

    fclose(f);
    return mounted;
}


/*
 * Is some OTHER machine currently mounting this volume?
 *
 * Decided by WATCHING a candidate row's hb_seq advance, never by
 * comparing its last_seen against this machine's clock.
 *
 * The clock comparison is what this used to do, and its own comment
 * waved the problem away as "a reason to treat a positive answer as
 * authoritative and a negative one as merely probable". That was far too
 * generous: a negative answer here is what lets mkfs reformat the
 * device, so under clock skew -- two real nodes were found 1h55m apart,
 * neither running a working NTP service -- this would have cheerfully
 * destroyed a volume another host was actively running VMs off. Exactly
 * the catastrophe the check exists to prevent.
 *
 * A mounted node bumps hb_seq every CETRAFS_HEARTBEAT_INTERVAL_SECS, so
 * sampling twice far enough apart answers the question with no clock
 * agreement required at all. The cost is the wait, which is paid ONLY
 * when some row actually looks like it might be live: a never-mounted
 * device, or one every node left cleanly (last_seen == 0), returns
 * immediately.
 *
 * Returns 1 and fills the out-parameters for the first live peer found,
 * 0 if none (including when the device is not a cetrafs volume at all --
 * nothing can be mounting it as one), and -1 when the registry CANNOT BE
 * READ (an I/O error on a volume that claims to be cetrafs): "unreadable"
 * is not "nobody", and both callers run DESTRUCTIVE operations on the
 * strength of this answer -- they must fail closed on -1. A read that
 * merely falls off the end of the device stays 0, same as the
 * bounded-garbage case below: that is a corrupt layout, not a peer.
 *
 * Rows that fail their checksum are skipped rather than trusted: a torn
 * or garbage row must not be able to block a format forever. FREE rows
 * are skipped too -- mkfs leaves the table zero-filled and never stamps
 * a checksum on one.
 *
 * out_age_secs is filled with the wall-clock age of the row for display
 * only; it is meaningless under skew and nothing decides anything with
 * it.
 */
/* Read one Node Registry row; 1 = a checksum-valid, REGISTERED row that
 * is not an explicit clean departure; 0 = anything else readable;
 * -1 = the row CANNOT be read (I/O error -- see the contract above). */
static inline int cetrafs_read_live_candidate(int fd,
                                              const cetrafs_superblock_t *sb,
                                              uint32_t idx,
                                              cetrafs_node_entry_t *out)
{
    /* This runs BEFORE any layout validation -- it is the "is somebody
     * mounted?" gate, which deliberately trusts nothing but the magic --
     * so node_table_start can be arbitrary garbage. The multiply used to
     * be signed and overflowed (caught by the UBSAN fuzz run: a
     * checksum-valid SB with node_table_start ~2^60). Unsigned math,
     * bounded before it becomes an off_t: an offset that large cannot be
     * a real table, and "no live row" is the honest answer. */
    uint64_t lba = cetrafs_le64(sb->node_table_start) + idx;
    unsigned char blk[CETRAFS_BLOCK_SIZE];

    if (lba >= (uint64_t) INT64_MAX / CETRAFS_BLOCK_SIZE)
        return 0;
    off_t off = (off_t) (lba * CETRAFS_BLOCK_SIZE);
    cetrafs_node_entry_t ne;
    uint32_t want;

    {
        ssize_t got = pread(fd, blk, CETRAFS_BLOCK_SIZE, off);

        if (got < 0)
            return -1; /* I/O error: cannot VERIFY, which is not "nobody" */
        if (got != (ssize_t) CETRAFS_BLOCK_SIZE)
            return 0; /* past the device end: a corrupt layout, like the bound above */
    }
    memcpy(&ne, blk, sizeof(ne));

    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
        return 0;

    want = (uint32_t) cetrafs_le64(ne.checksum);
    ne.checksum = 0;
    if (crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(ne.checksum)) != want)
        return 0; /* garbage row -- must not be able to block a format */
    ne.checksum = cetrafs_cpu_to_le64(want);

    /* An explicit clean departure. A single exact sentinel, not a
     * duration, so it needs no clock and stays reliable under skew. */
    if (ne.last_seen == 0)
        return 0;

    *out = ne;
    return 1;
}

/* ---- the offline repairer's claim --------------------------------
 *
 * `fsck -r` and growfs refuse to touch a volume a node has mounted.
 * That covers one direction: nothing stopped a node MOUNTING halfway
 * through a repair, because the repairer put nothing on the device for
 * a mount to see. These three write (and clear) a Node Registry row in
 * CETRAFS_NODE_STATE_REPAIR, which fill_super() refuses to mount past.
 *
 * It is a lease. cetrafs_repair_renew() must be called as the work
 * proceeds, and a repairer that dies releases the volume after the
 * ordinary staleness window rather than blocking it forever.
 */
static inline off_t cetrafs_node_row_off(const cetrafs_superblock_t *sb, uint32_t idx)
{
    return (off_t) ((cetrafs_le64(sb->node_table_start) + idx) * CETRAFS_BLOCK_SIZE);
}

static inline void cetrafs_node_row_stamp(cetrafs_node_entry_t *ne)
{
    ne->checksum = 0;
    ne->checksum = cetrafs_cpu_to_le64(
        crc32c_struct(ne, sizeof(*ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(ne->checksum)));
}

/*
 * Is somebody else repairing this volume right now?
 *
 * Returns 1 and fills out_row/out_label if a REPAIR row is live, 0 if
 * none is, -1 on an I/O error (which, like cetrafs_find_live_peer(),
 * means "cannot verify" and must fail closed in the caller).
 */
static inline int cetrafs_find_repair_claim(int fd,
                                            const cetrafs_superblock_t *sb,
                                            uint32_t *out_row,
                                            char *out_label,
                                            size_t label_sz)
{
    uint32_t count = cetrafs_le32(sb->node_table_count), idx, ncand = 0;
    cetrafs_node_entry_t *first;
    int found = 0;

    if (!count || count > 4096)
        return 0;
    first = (cetrafs_node_entry_t *) calloc(count, sizeof(*first));
    if (!first)
        return -1; /* cannot verify is not "nobody" */

    /*
     * Live is decided by WATCHING, as for a node: a repairer renews its
     * row every CETRAFS_REPAIR_RENEW_SECS on a timer, so a claim whose
     * hb_seq does not move over CETRAFS_REPAIR_PROBE_SECS belongs to a
     * repairer that is gone. This compared last_seen with THIS machine's
     * clock, which on skewed hosts let a second repair run beside a live
     * one -- and kept a dead one's claim "live" for as long as its
     * last_seen sat in our future. The wait is paid only when a claim
     * exists at all.
     */
    for (int pass = 0; pass < 2 && !found; pass++) {
        if (pass == 1) {
            if (!ncand)
                break;
            fprintf(stderr, "a repair claim is registered; watching it %us to see whether its repairer is alive...\n",
                    (unsigned) CETRAFS_REPAIR_PROBE_SECS);
            fflush(stderr);
            cetrafs_sleep_full(CETRAFS_REPAIR_PROBE_SECS);
            posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED); /* or the re-read is served from our cache */
        }
        for (idx = 0; idx < count; idx++) {
            unsigned char blk[CETRAFS_BLOCK_SIZE];
            cetrafs_node_entry_t ne;
            uint32_t want;
            ssize_t got = pread(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, idx));

            if (got < 0) {
                free(first);
                return -1;
            }
            if (got != (ssize_t) sizeof(blk))
                break; /* past the device end: a corrupt layout, not a claim */
            memcpy(&ne, blk, sizeof(ne));
            if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR)
                continue;
            want = (uint32_t) cetrafs_le64(ne.checksum);
            ne.checksum = 0;
            if (crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(ne.checksum)) != want)
                continue; /* garbage must not be able to block a repair */
            if (pass == 0) {
                first[idx] = ne;
                ncand++;
                continue;
            }
            if (cetrafs_le32(first[idx].state) != CETRAFS_NODE_STATE_REPAIR || ne.hb_seq == first[idx].hb_seq)
                continue; /* not seen before, or not renewed: no live repairer here */
            if (out_row)
                *out_row = idx;
            if (out_label && label_sz) {
                memcpy(out_label, ne.label, label_sz - 1 < sizeof(ne.label) ? label_sz - 1 : sizeof(ne.label));
                out_label[label_sz - 1] = 0;
            }
            found = 1;
            break;
        }
    }
    free(first);
    return found;
}

/*
 * The bytes a claim displaced, so release can put them back. A registry
 * full of departed nodes is the normal state of a cluster that has been
 * reinstalled a few times, and a volume that cannot be REPAIRED because
 * every row is spoken for would be a trap of its own -- so a row whose
 * node has provably left (the last_seen == 0 clean-departure sentinel,
 * or a lease older than the staleness window) is borrowed and restored.
 * The node it belongs to re-attaches by UUID, and a mount cannot happen
 * while the claim is live anyway.
 */
static unsigned char cetrafs_repair_saved[CETRAFS_BLOCK_SIZE];
static int cetrafs_repair_borrowed;

/* How long a liveness probe watches hb_seq, before the watched rows
 * have their say (cetrafs_probe_window()). CETRAFS_PEER_PROBE_SECS is a
 * test knob only: the suite cannot afford a real heartbeat interval per
 * assertion. Unset in every normal invocation. */
static inline unsigned cetrafs_peer_probe_secs(void)
{
    const char *env = getenv("CETRAFS_PEER_PROBE_SECS");

    if (env && *env) {
        long v = strtol(env, NULL, 10);

        if (v > 0)
            return (unsigned) v;
    }
    return CETRAFS_PEER_PROBE_SECS;
}

/*
 * The probe window for a set of rows: long enough for the SLOWEST of
 * them to beat, twice. A node advertises its own interval in its row
 * (hb_interval_secs, up to CETRAFS_HB_INTERVAL_MAX_SECS) and the fixed
 * window (one default interval + 5 s = 20 s) was shorter than a legal
 * 30 s one: a live node beating that slowly could pass a whole probe
 * unseen and be declared gone -- by mkfs -f, by fsck -r. Clamped to the
 * legal maximum, so a hostile row cannot make us sleep for days; 0 is a
 * row that predates the field and leaves the base window. The kernel's
 * own probe (node.c) floors on four beats; this one blocks a human at a
 * prompt and is paid only when some row looks live, so two.
 */
static inline unsigned cetrafs_probe_window(uint32_t max_advertised)
{
    unsigned base = cetrafs_peer_probe_secs();
    uint32_t pi = max_advertised < CETRAFS_HB_INTERVAL_MAX_SECS ? max_advertised : CETRAFS_HB_INTERVAL_MAX_SECS;

    return pi && 2 * pi + 5 > base ? 2 * pi + 5 : base;
}

static inline void cetrafs_repair_timer(int fd, const cetrafs_superblock_t *sb, uint32_t row, int on);

/* Claim a row for this repairer. Returns the row, or -1 if none could
 * be taken (or the write failed) -- in which case the caller must not
 * proceed: an unclaimed repair is the thing being fixed. */
static inline int cetrafs_repair_claim(int fd, const cetrafs_superblock_t *sb, const char *label)
{
    uint32_t count = cetrafs_le32(sb->node_table_count), idx, slowest = 0;
    unsigned char *seen = NULL;
    int pass;

    if (!count || count > 4096)
        return -1;

    /*
     * Pass 0 takes a free row; pass 1 borrows a cleanly departed one
     * (last_seen == 0); pass 2 borrows one whose node is PROVEN gone.
     * Never in another order: borrowing while a free row exists would
     * displace a registration for no reason.
     *
     * Proven gone means watched: its hb_seq did not move over a probe
     * window, the test cetrafs_find_live_peer() applies. This used to
     * compare the row's last_seen with THIS machine's clock, and a live
     * node whose clock lagged by more than the staleness window had its
     * row overwritten -- after which the live-peer probe could not see
     * it either (the row read REPAIR) and the repair ran on a mounted
     * volume. The wait is paid only when the table is full and nobody
     * left cleanly.
     */
    for (pass = 0; pass < 3; pass++) {
        if (pass == 2) {
            seen = (unsigned char *) calloc(count, CETRAFS_BLOCK_SIZE);
            if (!seen)
                return -1;
            for (idx = 0; idx < count; idx++)
                if (pread(fd, seen + (size_t) idx * CETRAFS_BLOCK_SIZE, CETRAFS_BLOCK_SIZE,
                          cetrafs_node_row_off(sb, idx)) != (ssize_t) CETRAFS_BLOCK_SIZE) {
                    free(seen);
                    return -1;
                }
            for (idx = 0; idx < count; idx++) {
                const cetrafs_node_entry_t *r =
                    (const cetrafs_node_entry_t *) (seen + (size_t) idx * CETRAFS_BLOCK_SIZE);

                if (cetrafs_le32(r->state) == CETRAFS_NODE_STATE_REGISTERED &&
                    cetrafs_le32(r->hb_interval_secs) > slowest)
                    slowest = cetrafs_le32(r->hb_interval_secs);
            }
            fprintf(stderr,
                    "no free or cleanly released registry row; watching for %us for one whose node is gone...\n",
                    cetrafs_probe_window(slowest));
            fflush(stderr);
            cetrafs_sleep_full(cetrafs_probe_window(slowest));
            posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED); /* or the re-read is served from our cache */
        }
        for (idx = 0; idx < count; idx++) {
            unsigned char blk[CETRAFS_BLOCK_SIZE];
            cetrafs_node_entry_t ne;

            if (pread(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(blk)) {
                free(seen);
                return -1;
            }
            memcpy(&ne, blk, sizeof(ne));
            if (pass == 0) {
                if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_FREE)
                    continue;
            } else {
                if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
                    continue;
                if (pass == 1 && ne.last_seen != 0)
                    continue; /* not a clean departure: only a probe can tell */
                if (pass == 2 && memcmp(blk, seen + (size_t) idx * CETRAFS_BLOCK_SIZE, sizeof(blk)) != 0)
                    continue; /* written during the probe: alive, not ours to take */
                memcpy(cetrafs_repair_saved, blk, sizeof(cetrafs_repair_saved));
                cetrafs_repair_borrowed = 1;
            }
            free(seen);
            seen = NULL;

            memset(&ne, 0, sizeof(ne));
            ne.state = cetrafs_cpu_to_le32(CETRAFS_NODE_STATE_REPAIR);
            ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
            ne.hb_seq = cetrafs_cpu_to_le64(1);
            snprintf(ne.label, sizeof(ne.label), "%s", label);
            cetrafs_node_row_stamp(&ne);

            memset(blk, 0, sizeof(blk));
            memcpy(blk, &ne, sizeof(ne));
            if (pwrite(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(blk))
                return -1;
            /* On the platter before the first structural write, or the
             * claim does not exist as far as a mounting node is concerned. */
            if (fsync(fd) != 0)
                return -1;
            cetrafs_repair_timer(fd, sb, idx, 1); /* renewals from here until the release */
            return (int) idx;
        }
    }
    free(seen);
    return -1;
}

/* Refresh the lease. Cheap enough to call often; the caller decides how
 * often, and "too rarely" means a mount can slip in mid-repair. */
static inline int cetrafs_repair_renew(int fd, const cetrafs_superblock_t *sb, uint32_t row)
{
    unsigned char blk[CETRAFS_BLOCK_SIZE];
    cetrafs_node_entry_t ne;

    if (pread(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, row)) != (ssize_t) sizeof(blk))
        return -1;
    memcpy(&ne, blk, sizeof(ne));
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR)
        return -1; /* somebody took our row: say so rather than fight */
    ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
    ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
    cetrafs_node_row_stamp(&ne);
    memcpy(blk, &ne, sizeof(ne));
    if (pwrite(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, row)) != (ssize_t) sizeof(blk))
        return -1;
    return 0;
}

/*
 * The claim's renewals, on a timer: every CETRAFS_REPAIR_RENEW_SECS,
 * whatever phase the repair is in. Renewing from the work loops left
 * every other phase -- and the whole of growfs, which never renewed --
 * without a heartbeat, so a long one let the lease lapse mid-repair and
 * a node mount under it. pread/pwrite and the checksum are all the
 * handler does, which is safe in a signal handler; the row is written
 * by nobody else while the timer runs. A renewal that finds the row
 * taken sets cetrafs_repair_lost for the work loop to stop on.
 */
static volatile sig_atomic_t cetrafs_repair_lost;
static int cetrafs_renew_fd = -1;
static cetrafs_superblock_t cetrafs_renew_sb;
static uint32_t cetrafs_renew_row;

static void cetrafs_repair_tick(int sig)
{
    int saved = errno;

    (void) sig;
    if (cetrafs_renew_fd >= 0 && cetrafs_repair_renew(cetrafs_renew_fd, &cetrafs_renew_sb, cetrafs_renew_row) != 0)
        cetrafs_repair_lost = 1;
    errno = saved;
}

static inline void cetrafs_repair_timer(int fd, const cetrafs_superblock_t *sb, uint32_t row, int on)
{
    struct itimerval it;
    struct sigaction sa;

    memset(&it, 0, sizeof(it));
    memset(&sa, 0, sizeof(sa));
    if (!on) {
        setitimer(ITIMER_REAL, &it, NULL);
        sa.sa_handler = SIG_DFL;
        sigaction(SIGALRM, &sa, NULL);
        cetrafs_renew_fd = -1;
        return;
    }
    cetrafs_renew_sb = *sb;
    cetrafs_renew_row = row;
    cetrafs_renew_fd = fd;
    sa.sa_handler = cetrafs_repair_tick;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, NULL);
    it.it_interval.tv_sec = CETRAFS_REPAIR_RENEW_SECS;
    it.it_value.tv_sec = CETRAFS_REPAIR_RENEW_SECS;
    setitimer(ITIMER_REAL, &it, NULL);
}

/* Give the volume back. Best effort by construction: if this never runs
 * -- a kill, a crash, a power cut -- the lease above expires on its own. */
static inline void cetrafs_repair_release(int fd, const cetrafs_superblock_t *sb, uint32_t row)
{
    unsigned char blk[CETRAFS_BLOCK_SIZE];

    cetrafs_repair_timer(fd, sb, row, 0); /* no renewal may land after the release */
    if (cetrafs_repair_borrowed) {
        memcpy(blk, cetrafs_repair_saved, sizeof(blk)); /* put the registration back */
        cetrafs_repair_borrowed = 0;
    } else {
        memset(blk, 0, sizeof(blk)); /* all-zero is CETRAFS_NODE_STATE_FREE */
    }
    if (pwrite(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, row)) == (ssize_t) sizeof(blk))
        (void) fsync(fd);
}

/*
 * Walk the Node Registry and report, per REGISTERED row, whether that
 * node's module advertised CETRAFS_NODE_CAP_LIVE_GROW.
 *
 * This is the only on-disk evidence of what build each peer is running:
 * caps is written by the node itself at registration, and a row written
 * by a build that predates capabilities reads 0. A node whose row says
 * 0 cannot mount a grown (0x0009) volume -- its module refuses the
 * layout -- so growing while such a node is expected back strands it.
 *
 * Unlike cetrafs_find_live_peer(), this does NOT care whether the row
 * is heartbeating: a node that is merely unmounted right now is still
 * coming back, and is exactly who the warning is for.
 *
 * Returns the number of registered rows, -1 on I/O error. Fills the
 * caller's arrays up to 'max'.
 */
static inline int cetrafs_scan_node_caps(const char *dev,
                                         char labels[][CETRAFS_NODE_LABEL_LEN + 1],
                                         uint32_t *caps_out,
                                         uint32_t *rows_out,
                                         unsigned max)
{
    cetrafs_superblock_t sb;
    cetrafs_node_entry_t e;
    uint32_t count, idx;
    unsigned n = 0;
    int fd;

    fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb) || cetrafs_le32(sb.magic) != CETRAFS_MAGIC) {
        close(fd);
        return -1;
    }
    count = cetrafs_le32(sb.node_table_count);
    if (!count || count > 4096) {
        close(fd);
        return -1;
    }
    for (idx = 0; idx < count && n < max; idx++) {
        off_t off = (off_t) cetrafs_le64(sb.node_table_start) * CETRAFS_BLOCK_SIZE + (off_t) idx * sizeof(e);

        if (pread(fd, &e, sizeof(e), off) != (ssize_t) sizeof(e)) {
            close(fd);
            return -1;
        }
        if (cetrafs_le32(e.state) != CETRAFS_NODE_STATE_REGISTERED)
            continue;
        snprintf(labels[n], CETRAFS_NODE_LABEL_LEN + 1, "%.*s", CETRAFS_NODE_LABEL_LEN, e.label);
        caps_out[n] = cetrafs_le32(e.caps);
        rows_out[n] = idx;
        n++;
    }
    close(fd);
    return (int) n;
}

static inline int cetrafs_find_live_peer(const char *dev,
                                         uint32_t *out_row,
                                         char *out_label,
                                         size_t label_sz,
                                         long long *out_age_secs)
{
    cetrafs_superblock_t sb;
    cetrafs_node_entry_t *first = NULL;
    uint32_t count, idx, ncand = 0, slowest = 0;
    int fd, found = 0;

    fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    if (pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb) || cetrafs_le32(sb.magic) != CETRAFS_MAGIC) {
        close(fd);
        return 0; /* not a cetrafs volume: nothing can be mounting it as one */
    }

    count = cetrafs_le32(sb.node_table_count);
    /* Same trust boundary: a garbage count must not size an allocation.
     * Any legal volume's node table is <= CETRAFS_MAX_READER_NODES (64,
     * mkfs-enforced); 4096 is comfortably past any future format and
     * still a trivial calloc. */
    if (!count || count > 4096) {
        close(fd);
        return 0;
    }
    first = (cetrafs_node_entry_t *) calloc(count, sizeof(*first));
    if (!first) {
        close(fd);
        return -1; /* cannot verify is not "nobody" -- see the contract */
    }

    /* Pass 1: who even looks like they might be mounted? */
    unsigned char *iscand = (unsigned char *) calloc(count, 1);
    if (!iscand) {
        free(first);
        close(fd);
        return -1;
    }
    for (idx = 0; idx < count; idx++) {
        int rc = cetrafs_read_live_candidate(fd, &sb, idx, &first[idx]);

        if (rc < 0) { /* an unreadable row fails the whole verdict closed */
            free(iscand);
            free(first);
            close(fd);
            return -1;
        }
        if (rc) {
            iscand[idx] = 1;
            ncand++;
            if (cetrafs_le32(first[idx].hb_interval_secs) > slowest)
                slowest = cetrafs_le32(first[idx].hb_interval_secs);
        }
    }
    if (ncand == 0) {
        free(iscand);
        free(first);
        close(fd);
        return 0; /* nobody to wait for */
    }

    /* Pass 2: give every candidate more than one full heartbeat interval
     * to prove it is alive by moving its own counter. */
    {
        unsigned probe = cetrafs_probe_window(slowest);

        fprintf(stderr,
                "%s: %u node registry row(s) look mounted; watching for %us to see whether they are "
                "still heartbeating...\n",
                dev, ncand, probe);
        fflush(stderr);
        cetrafs_sleep_full(probe);
    }

    /*
     * Drop this machine's cached pages for the device before re-reading.
     *
     * Without this the second pread is served from the page cache
     * populated by the first one, so the peer's heartbeat is INVISIBLE
     * no matter how long we wait -- every row reads exactly as it did at
     * t0 and every live peer is reported dead. Found on real hardware:
     * node b watched node a for 20s while a was mounted and heartbeating,
     * saw nothing move, and concluded the volume was free.
     *
     * The kernel has the same problem and solves it the same way
     * (ioutil.c's forced-fresh reads); a shared LUN is simply not
     * coherent through one machine's cache.
     */
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

    for (idx = 0; idx < count && !found; idx++) {
        cetrafs_node_entry_t now_ne;

        int rc;

        if (!iscand[idx])
            continue;
        rc = cetrafs_read_live_candidate(fd, &sb, idx, &now_ne);
        if (rc < 0) { /* unreadable mid-probe: fail closed, same as pass 1 */
            free(iscand);
            free(first);
            close(fd);
            return -1;
        }
        if (!rc)
            continue; /* it left, or its row went away, during the probe */
        if (now_ne.hb_seq == first[idx].hb_seq)
            continue; /* registered, but not heartbeating: gone */

        if (out_row)
            *out_row = idx;
        if (out_age_secs) {
            long long age = (long long) time(NULL) - (long long) cetrafs_le64(now_ne.last_seen);

            *out_age_secs = age < 0 ? 0 : age;
        }
        if (out_label && label_sz) {
            memcpy(out_label, now_ne.label, label_sz - 1 < sizeof(now_ne.label) ? label_sz - 1 : sizeof(now_ne.label));
            out_label[label_sz - 1] = 0;
        }
        found = 1;
    }

    free(iscand);
    free(first);
    close(fd);
    return found;
}

#endif /* CETRAFS_DEVUTIL_H */
