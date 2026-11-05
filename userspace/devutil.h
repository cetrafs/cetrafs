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
#include <linux/fs.h> /* BLKGETSIZE64 */
#include <sys/ioctl.h>
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
    if (!f) {
        /* Cannot tell is not "not mounted": every caller is about to
         * write the device, and the open-time errors it used to rely on
         * do not fire for a block device a kernel has mounted. */
        if (where && where_len)
            snprintf(where, where_len, "(unknown: /proc/self/mounts unreadable: %s)", strerror(errno));
        return 1;
    }

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
/*
 * A row in a live state (REGISTERED, REPAIR) whose checksum does not
 * verify may be one its node is rewriting right now: re-read it, from
 * the device, before believing that.
 *
 * Skipping it on the first bad read made a live node's row caught
 * mid-update count as NO node, and mkfs -f / fsck -r went ahead on a
 * mounted volume (tests/image/peer_probe_torn_row.sh). A checksum
 * detects; a lockless reader next to a writer re-reads (CLAUDE.md,
 * rule 3). A row that never verifies is garbage after all, and must
 * still not block a tool forever -- so the retries are bounded per row
 * (10..160 ms, 310 ms in all) and per scan (*budget_ms), and a
 * registry full of garbage costs seconds, not minutes.
 *
 * Returns the pread result for the last read: the caller checks the
 * state and checksum again exactly as before.
 */
#define CETRAFS_ROW_SETTLE_BUDGET_MS 2000u

static inline int cetrafs_node_row_crc_ok(const cetrafs_node_entry_t *ne)
{
    cetrafs_node_entry_t c = *ne;
    uint32_t want = (uint32_t) cetrafs_le64(c.checksum);

    c.checksum = 0;
    return crc32c_struct(&c, sizeof(c), offsetof(cetrafs_node_entry_t, checksum), sizeof(c.checksum)) == want;
}

static inline ssize_t cetrafs_node_row_pread_settled(int fd, unsigned char *blk, off_t off, unsigned *budget_ms)
{
    unsigned delay = 10;
    ssize_t got;

    for (;;) {
        cetrafs_node_entry_t ne;
        uint32_t st;

        got = pread(fd, blk, CETRAFS_BLOCK_SIZE, off);
        if (got != (ssize_t) CETRAFS_BLOCK_SIZE)
            return got;
        memcpy(&ne, blk, sizeof(ne));
        st = cetrafs_le32(ne.state);
        if ((st != CETRAFS_NODE_STATE_REGISTERED && st != CETRAFS_NODE_STATE_REPAIR) || cetrafs_node_row_crc_ok(&ne))
            return got;
        if (delay > 160 || !budget_ms || *budget_ms < delay)
            return got; /* never verified: garbage, and the caller says so */
        *budget_ms -= delay;
        {
            struct timespec ts = {.tv_sec = 0, .tv_nsec = (long) delay * 1000000L};

            while (nanosleep(&ts, &ts) != 0 && errno == EINTR)
                ;
        }
        posix_fadvise(fd, off, CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED); /* the device, not our cache */
        delay *= 2;
    }
}

/* Read one Node Registry row; 1 = a checksum-valid, REGISTERED row that
 * is not an explicit clean departure; 2 = a REGISTERED row whose
 * checksum never verified, even re-read; 0 = anything else readable;
 * -1 = the row CANNOT be read (I/O error -- see the contract above). */
static inline int cetrafs_read_live_candidate(int fd,
                                              const cetrafs_superblock_t *sb,
                                              uint32_t idx,
                                              cetrafs_node_entry_t *out,
                                              unsigned *budget_ms)
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

    {
        ssize_t got = cetrafs_node_row_pread_settled(fd, blk, off, budget_ms);

        if (got < 0)
            return -1; /* I/O error: cannot VERIFY, which is not "nobody" */
        if (got != (ssize_t) CETRAFS_BLOCK_SIZE)
            return 0; /* past the device end: a corrupt layout, like the bound above */
    }
    memcpy(&ne, blk, sizeof(ne));

    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
        return 0;

    if (!cetrafs_node_row_crc_ok(&ne))
        return 2; /* never verified, re-read included: the caller decides */

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

/* CETRAFS_PEER_PROBE_SECS is a test knob only (see below). */
static inline unsigned cetrafs_peer_probe_secs(void);

/*
 * How long a tool watches a repair claim before calling its repairer
 * gone: the node stale window, as the kernel's mount gate does
 * (cetrafs_node_repair_claim_exists()). A renewal is a pwrite plus an
 * fdatasync from a timer, queued behind the same multipath retry as a
 * heartbeat, so a repairer whose host lost its paths can be silent for
 * most of that window and still have writes queued to land. Watching
 * three renewals (15 s) let a second repair start under them.
 */
static inline unsigned cetrafs_repair_watch_secs(void)
{
    unsigned knob = cetrafs_peer_probe_secs();

    if (knob)
        return knob > CETRAFS_REPAIR_PROBE_SECS ? knob : CETRAFS_REPAIR_PROBE_SECS;
    return CETRAFS_NODE_STALE_SECS > CETRAFS_REPAIR_PROBE_SECS ? CETRAFS_NODE_STALE_SECS : CETRAFS_REPAIR_PROBE_SECS;
}

/*
 * Reap the claim of a repairer judged dead: put back the row it borrowed
 * (kept at CETRAFS_REPAIR_SAVED_OFF in the claim's own block), or free
 * the row. A killed fsck -r or growfs used to leave its row REPAIR for
 * good, and on a full registry the node it borrowed from could not mount
 * again. Only while the row is still the claim that was watched; a
 * repairer that comes back afterwards finds its row taken and stops.
 * The kernel's mount gate does the same (cetrafs_node_reap_repair_claim()).
 */
static inline void cetrafs_repair_reap(int fd, const cetrafs_superblock_t *sb, uint32_t idx,
                                       const cetrafs_node_entry_t *judged)
{
    unsigned char blk[CETRAFS_BLOCK_SIZE], out[CETRAFS_BLOCK_SIZE];
    cetrafs_node_entry_t ne, saved;

    if (pread(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(blk))
        return;
    memcpy(&ne, blk, sizeof(ne));
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR || ne.hb_seq != judged->hb_seq)
        return;
    memcpy(&saved, blk + CETRAFS_REPAIR_SAVED_OFF, sizeof(saved));
    memset(out, 0, sizeof(out));
    if (cetrafs_le32(saved.state) == CETRAFS_NODE_STATE_REGISTERED && cetrafs_node_row_crc_ok(&saved))
        memcpy(out, &saved, sizeof(saved));
    if (pwrite(fd, out, sizeof(out), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(out) || fsync(fd) != 0) {
        fprintf(stderr, "WARN: registry row %u: the dead repair claim could not be reaped\n", idx);
        return;
    }
    if (cetrafs_le32(saved.state) == CETRAFS_NODE_STATE_REGISTERED && cetrafs_node_row_crc_ok(&saved))
        fprintf(stderr, "registry row %u: reaped a dead repair claim and gave the row back to %.*s\n", idx,
                (int) sizeof(saved.label), saved.label);
    else
        fprintf(stderr, "registry row %u: reaped a dead repair claim; the row is free again\n", idx);
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
    unsigned budget = CETRAFS_ROW_SETTLE_BUDGET_MS;

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
                    cetrafs_repair_watch_secs());
            fflush(stderr);
            cetrafs_sleep_full(cetrafs_repair_watch_secs());
            posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED); /* or the re-read is served from our cache */
        }
        for (idx = 0; idx < count; idx++) {
            unsigned char blk[CETRAFS_BLOCK_SIZE];
            cetrafs_node_entry_t ne;
            int changed;
            ssize_t got = cetrafs_node_row_pread_settled(fd, blk, cetrafs_node_row_off(sb, idx), &budget);

            if (got < 0) {
                free(first);
                return -1;
            }
            if (got != (ssize_t) sizeof(blk))
                break; /* past the device end: a corrupt layout, not a claim */
            memcpy(&ne, blk, sizeof(ne));
            if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR)
                continue;
            changed = 0;
            if (!cetrafs_node_row_crc_ok(&ne)) {
                /* Never verified, re-read included. At the first look
                 * that is garbage, which must not block a repair; at
                 * the second, after a valid first look, the row CHANGED
                 * during the probe -- a repairer at work. */
                if (pass == 0 || cetrafs_le32(first[idx].state) != CETRAFS_NODE_STATE_REPAIR)
                    continue;
                ne = first[idx]; /* report what we could verify */
                changed = 1;
            }
            if (pass == 0) {
                first[idx] = ne;
                ncand++;
                continue;
            }
            if (cetrafs_le32(first[idx].state) != CETRAFS_NODE_STATE_REPAIR)
                continue; /* not seen before */
            if (!changed && ne.hb_seq == first[idx].hb_seq) {
                /* Not renewed over the whole window: its repairer is
                 * gone. Give the row back, or it stays REPAIR forever. */
                cetrafs_repair_reap(fd, sb, idx, &first[idx]);
                continue;
            }
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

/* CETRAFS_PEER_PROBE_SECS is a test knob only: the suites cannot afford
 * a real stale window per assertion. Returns 0 when unset, which is
 * every normal invocation. */
static inline unsigned cetrafs_peer_probe_secs(void)
{
    const char *env = getenv("CETRAFS_PEER_PROBE_SECS");

    if (env && *env) {
        long v = strtol(env, NULL, 10);

        if (v > 0)
            return (unsigned) v;
    }
    return 0;
}

/*
 * How long a tool watches a row that looks mounted before calling its
 * node gone: exactly as long as a mounted peer would -- the stale
 * window, floored at four of the row's own advertised beats
 * (cetrafs_node_is_stale(), and the kernel's own mount probe).
 *
 * It was two beats plus 5 s, 20 s at the default interval. But the
 * stale window is 120 s for a reason that has nothing to do with
 * heartbeats (cetrafs.h, CETRAFS_NODE_STALE_SECS): a node whose paths
 * have all failed has its I/O QUEUED by multipath for up to 90 s, its
 * heartbeat included, and then it all lands. A tool that waited 20 s
 * formatted or repaired a volume such a node was about to write to --
 * the inversion that window was raised to prevent, re-opened by the
 * one caller that blocks a human at a prompt. Paid only when some row
 * looks live. Clamped to the legal maximum interval, so a hostile row
 * cannot make us sleep for days; 0 is a row that predates the field.
 */
static inline unsigned cetrafs_probe_window(uint32_t max_advertised)
{
    unsigned knob = cetrafs_peer_probe_secs();
    uint32_t pi = max_advertised < CETRAFS_HB_INTERVAL_MAX_SECS ? max_advertised : CETRAFS_HB_INTERVAL_MAX_SECS;
    unsigned window = CETRAFS_NODE_STALE_SECS;

    if (knob) /* tests: the old two-beat rule over a compressed base */
        return pi && 2 * pi + 5 > knob ? 2 * pi + 5 : knob;
    if (pi && 4 * pi > window)
        window = 4 * pi;
    return window;
}

static inline void cetrafs_repair_timer(int fd, const cetrafs_superblock_t *sb, uint32_t row, int on);

/*
 * May a repairer write registry rows where this superblock says the
 * registry is? Every claim, renewal and release writes at
 * node_table_start + row, straight off the superblock, and the release
 * writes a row of zeros -- so a superblock with a damaged
 * node_table_start aimed both at file data, on exactly the damaged
 * volume fsck was asked to repair. fsck now validates the whole layout
 * before claiming; growfs checks only the geometry it computes with.
 * This is the one place both pass through: the superblock must be the
 * one written (CRC) and the registry must lie inside the device,
 * clear of every other region the superblock names.
 */
static inline int cetrafs_node_table_placed_ok(int fd, const cetrafs_superblock_t *sb)
{
    unsigned long long dev_bytes = 0;
    uint64_t start = cetrafs_le64(sb->node_table_start), nblk = cetrafs_le64(sb->node_table_blocks);
    uint64_t total = cetrafs_le64(sb->total_blocks), zg = cetrafs_le32(sb->zone_group_count);
    uint64_t bg = cetrafs_le32(sb->block_group_count), first = cetrafs_le64(sb->bg_table_first_count);
    uint64_t data_end = cetrafs_le64(sb->bg_data_end);
    struct {
        uint64_t start, count;
    } r[8];
    unsigned i, n = 0;

    if ((uint32_t) cetrafs_le64(sb->checksum) !=
        crc32c_struct(sb, sizeof(*sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb->checksum)))
        return 0;
    if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0) {
        struct stat st;

        if (fstat(fd, &st) < 0)
            return 0;
        dev_bytes = (unsigned long long) st.st_size;
    }
    if (total > dev_bytes / CETRAFS_BLOCK_SIZE)
        return 0;
    if (!cetrafs_le32(sb->node_table_count) || cetrafs_le32(sb->node_table_count) > nblk)
        return 0;
    if (!start || nblk > total || start > total - nblk)
        return 0;

    if (!first || first > bg)
        first = bg;
    if (!data_end)
        data_end = cetrafs_le64(sb->bg_regions_start) + bg * cetrafs_le64(sb->bg_size_blocks);
    r[n].start = 0, r[n++].count = 1;
    r[n].start = cetrafs_le64(sb->zg_table_start), r[n++].count = zg;
    r[n].start = cetrafs_le64(sb->bg_table_start), r[n++].count = first;
    r[n].start = cetrafs_le64(sb->inode_bmap_start), r[n++].count = cetrafs_le64(sb->inode_bmap_blocks);
    r[n].start = cetrafs_le64(sb->inode_table_start), r[n++].count = cetrafs_le64(sb->inode_table_blocks);
    r[n].start = cetrafs_le64(sb->pending_free_start), r[n++].count = zg * cetrafs_le32(sb->pending_free_blocks_per_zg);
    r[n].start = cetrafs_le64(sb->node_journal_start),
    r[n++].count = (uint64_t) cetrafs_le32(sb->node_table_count) * cetrafs_le32(sb->node_journal_blocks);
    r[n].start = cetrafs_le64(sb->bg_regions_start),
    r[n++].count = data_end > cetrafs_le64(sb->bg_regions_start) ? data_end - cetrafs_le64(sb->bg_regions_start) : 0;
    for (i = 0; i < n; i++)
        if (r[i].count && start < r[i].start + r[i].count && r[i].start < start + nblk)
            return 0;
    return 1;
}

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
    if (!cetrafs_node_table_placed_ok(fd, sb)) {
        fprintf(stderr, "ERR: the superblock places the Node Registry where it cannot be -- refusing to write a "
                        "repair claim there\n");
        return -1;
    }

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
            /* The displaced row, on the device, not only in this
             * process: a repairer that is killed or crashes cannot run
             * its release, and whoever reaps the dead claim puts the
             * registration back from here (CETRAFS_REPAIR_SAVED_OFF). */
            if (cetrafs_repair_borrowed)
                memcpy(blk + CETRAFS_REPAIR_SAVED_OFF, cetrafs_repair_saved, sizeof(cetrafs_node_entry_t));
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
    /* A renewal is what a mounting node on another host watches for,
     * and it reads the device: one left in our page cache until
     * writeback (~30 s) is no renewal inside its probe window. Async
     * -signal-safe, so it may run from the timer below. */
    if (fdatasync(fd) != 0)
        return -1;
    return 0;
}

/*
 * The claim's renewals, on a timer: every CETRAFS_REPAIR_RENEW_SECS,
 * whatever phase the repair is in. Renewing from the work loops left
 * every other phase -- and the whole of growfs, which never renewed --
 * without a heartbeat, so a long one let the lease lapse mid-repair and
 * a node mount under it. pread/pwrite/fdatasync and the checksum are
 * all the handler does, which is safe in a signal handler; the row is written
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

static inline void cetrafs_repair_release(int fd, const cetrafs_superblock_t *sb, uint32_t row);

/*
 * The signals a person or a service manager uses to stop a tool. Each
 * used to kill it with the claim still on the device: the mount gate
 * then waited out the stale window, and the row stayed REPAIR. Now the
 * claim is released first (pwrite and fsync are async-signal-safe,
 * and so is everything the release does), then the signal is re-raised
 * with its default action, so the exit status still says what happened.
 */
static const int cetrafs_repair_stop_sigs[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};

static void cetrafs_repair_stop(int sig)
{
    if (cetrafs_renew_fd >= 0)
        cetrafs_repair_release(cetrafs_renew_fd, &cetrafs_renew_sb, cetrafs_renew_row);
    signal(sig, SIG_DFL);
    raise(sig);
}

static inline void cetrafs_repair_timer(int fd, const cetrafs_superblock_t *sb, uint32_t row, int on)
{
    struct itimerval it;
    struct sigaction sa;
    unsigned i;

    memset(&it, 0, sizeof(it));
    memset(&sa, 0, sizeof(sa));
    if (!on) {
        setitimer(ITIMER_REAL, &it, NULL);
        sa.sa_handler = SIG_DFL;
        sigaction(SIGALRM, &sa, NULL);
        for (i = 0; i < sizeof(cetrafs_repair_stop_sigs) / sizeof(cetrafs_repair_stop_sigs[0]); i++)
            sigaction(cetrafs_repair_stop_sigs[i], &sa, NULL);
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
    sa.sa_handler = cetrafs_repair_stop;
    sa.sa_flags = 0;
    sigfillset(&sa.sa_mask); /* not interleaved with a renewal */
    for (i = 0; i < sizeof(cetrafs_repair_stop_sigs) / sizeof(cetrafs_repair_stop_sigs[0]); i++)
        sigaction(cetrafs_repair_stop_sigs[i], &sa, NULL);
    it.it_interval.tv_sec = CETRAFS_REPAIR_RENEW_SECS;
    it.it_value.tv_sec = CETRAFS_REPAIR_RENEW_SECS;
    setitimer(ITIMER_REAL, &it, NULL);
}

/* Give the volume back. Best effort by construction: if this never runs
 * -- a SIGKILL, a crash, a power cut -- the lease above expires on its
 * own, and whoever next watches the claim and finds it dead reaps the row
 * (cetrafs_repair_reap()). */
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

/* The probe itself, on a device already open and a superblock already
 * read -- mkfs runs it AFTER zeroing block 0, off the copy it kept. */
static inline int cetrafs_find_live_peer_on(int fd,
                                            const char *dev,
                                            const cetrafs_superblock_t *sbp,
                                            uint32_t *out_row,
                                            char *out_label,
                                            size_t label_sz,
                                            long long *out_age_secs)
{
    cetrafs_superblock_t sb = *sbp;
    cetrafs_node_entry_t *first = NULL;
    uint32_t count, idx, ncand = 0, slowest = 0;
    unsigned budget = CETRAFS_ROW_SETTLE_BUDGET_MS;
    int found = 0;

    count = cetrafs_le32(sb.node_table_count);
    /* Same trust boundary: a garbage count must not size an allocation.
     * Any legal volume's node table is <= CETRAFS_MAX_READER_NODES (64,
     * mkfs-enforced); 4096 is comfortably past any future format and
     * still a trivial calloc. */
    if (!count || count > 4096) {
        return 0;
    }
    first = (cetrafs_node_entry_t *) calloc(count, sizeof(*first));
    if (!first) {
        return -1; /* cannot verify is not "nobody" -- see the contract */
    }

    /* Pass 1: who even looks like they might be mounted? */
    unsigned char *iscand = (unsigned char *) calloc(count, 1);
    if (!iscand) {
        free(first);
        return -1;
    }
    for (idx = 0; idx < count; idx++) {
        int rc = cetrafs_read_live_candidate(fd, &sb, idx, &first[idx], &budget);

        if (rc < 0) { /* an unreadable row fails the whole verdict closed */
            free(iscand);
            free(first);
                return -1;
        }
        if (rc == 1) {
            iscand[idx] = 1;
            ncand++;
            if (cetrafs_le32(first[idx].hb_interval_secs) > slowest)
                slowest = cetrafs_le32(first[idx].hb_interval_secs);
        } else if (rc == 2) {
            /* REGISTERED but never verified, re-reads included. Most
             * likely garbage -- but a live node's row that stayed torn
             * longer than the settle budget was dropped here as "nobody"
             * and the tool went ahead on a mounted volume (fails open,
             * CLAUDE.md rule 3). Watch it through the probe window like
             * any candidate: a row that turns VALID meanwhile was being
             * written, which is a live node; one still garbage after it
             * is garbage. It costs one window, never a refusal. */
            iscand[idx] = 2;
            ncand++;
        }
    }
    if (ncand == 0) {
        free(iscand);
        free(first);
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
        rc = cetrafs_read_live_candidate(fd, &sb, idx, &now_ne, &budget);
        if (rc < 0) { /* unreadable mid-probe: fail closed, same as pass 1 */
            free(iscand);
            free(first);
                return -1;
        }
        if (!rc)
            continue; /* it left, or its row went away, during the probe */
        if (iscand[idx] == 2 && rc == 2)
            continue; /* garbage before the window and after it */
        /* rc == 2: verified at the first look, never since -- the row
         * CHANGED during the probe, which is a writer at work. */
        /* A row unverifiable at the first look and valid now was written
         * during the probe: that is a live node, whatever its hb_seq. */
        if (iscand[idx] == 1 && rc == 1 && now_ne.hb_seq == first[idx].hb_seq)
            continue; /* registered, but not heartbeating: gone */
        if (rc == 2)
            now_ne = first[idx]; /* report what we last could verify (iscand 1 only) */

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
    return found;
}

static inline int cetrafs_find_live_peer(const char *dev,
                                         uint32_t *out_row,
                                         char *out_label,
                                         size_t label_sz,
                                         long long *out_age_secs)
{
    cetrafs_superblock_t sb;
    int fd, found;

    fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    if (pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb) || cetrafs_le32(sb.magic) != CETRAFS_MAGIC) {
        close(fd);
        return 0; /* not a cetrafs volume: nothing can be mounting it as one */
    }
    found = cetrafs_find_live_peer_on(fd, dev, &sb, out_row, out_label, label_sz, out_age_secs);
    close(fd);
    return found;
}

#endif /* CETRAFS_DEVUTIL_H */
