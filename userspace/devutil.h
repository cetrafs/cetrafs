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
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/fs.h> /* BLKGETSIZE64, BLKSSZGET */
#include <scsi/sg.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
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

/*
 * A node label off the disk, made safe to print: up to its NUL (or the
 * field's end), every byte that is not printable ASCII as '?'. The label
 * is whatever a registering node wrote -- or whatever a damaged or
 * hostile row holds -- and the tools print it straight to the
 * operator's terminal, where an escape sequence is a command (audit
 * 2026-11-11 F12, tests/image/tool_label_sanitized.sh).
 */
static inline void cetrafs_label_copy(char *dst, size_t dst_sz, const char *src, size_t src_len)
{
    size_t i;

    if (!dst_sz)
        return;
    for (i = 0; i < src_len && i + 1 < dst_sz && src[i]; i++)
        dst[i] = (unsigned char) src[i] >= 0x20 && (unsigned char) src[i] < 0x7f ? src[i] : '?';
    dst[i] = 0;
}

/*
 * TEST ONLY environment knobs. Every one the tools honour is read
 * through these two, so that none of them is silent or unbounded: a
 * knob that is set says so on stderr (once per knob per process) --
 * several of them shrink a safety window, and a production run that
 * inherited one from a test shell must be visible in its own output --
 * and a numeric one that is not a plain integer inside its range ends
 * the run (exit 2) instead of becoming whatever atoi() made of it: "-1"
 * seconds was a 136-year sleep (audit 2026-11-11 G2,
 * tests/image/tool_test_knobs.sh).
 */
static inline const char *cetrafs_test_env(const char *name)
{
    static const char *told[32];
    const char *v = getenv(name);
    unsigned i;

    if (!v)
        return NULL;
    for (i = 0; i < 32 && told[i]; i++)
        if (strcmp(told[i], name) == 0)
            return v;
    if (i < 32)
        told[i] = name;
    fprintf(stderr, "cetrafs: TEST KNOB %s=%s is set: this is not a production run\n", name, v);
    return v;
}

/* 'dflt' when unset; the value when it is an integer in [lo, hi]; exit 2
 * otherwise. */
static inline long long cetrafs_test_env_ll(const char *name, long long lo, long long hi, long long dflt)
{
    const char *v = cetrafs_test_env(name);
    char *end;
    long long r;

    if (!v)
        return dflt;
    errno = 0;
    r = strtoll(v, &end, 10);
    if (errno || end == v || *end || r < lo || r > hi) {
        fprintf(stderr, "cetrafs: TEST KNOB %s=%s is not an integer in [%lld, %lld]; refusing to run\n", name, v, lo,
                hi);
        exit(2);
    }
    return r;
}

/* Is 'fd' something only a test makes: an image file, a loop device, or
 * a device-mapper stack whose every member is a loop device (the crash
 * rig's dm-log-writes)? */
static inline int cetrafs_fd_is_test_device(int fd)
{
    char path[96];
    struct stat st;
    DIR *d;
    struct dirent *e;
    int members = 0, others = 0;

    if (fstat(fd, &st))
        return 0;
    if (S_ISREG(st.st_mode))
        return 1;
    if (!S_ISBLK(st.st_mode))
        return 0;
    if (major(st.st_rdev) == 7) /* loop */
        return 1;
    snprintf(path, sizeof(path), "/sys/dev/block/%u:%u/slaves", major(st.st_rdev), minor(st.st_rdev));
    d = opendir(path);
    if (!d)
        return 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        if (strncmp(e->d_name, "loop", 4) == 0)
            members++;
        else
            others++;
    }
    closedir(d);
    return members > 0 && others == 0;
}

/* A TEST knob that DAMAGES the volume (zeroes a journal, leaves Block
 * Group headers unwritten): honoured only on a test device. Set on
 * anything else -- a production run that inherited it from a test
 * shell -- it refuses the run (exit 2) before anything is written. */
static inline const char *cetrafs_test_env_damaging(const char *name, int fd)
{
    const char *v = cetrafs_test_env(name);

    if (v && !cetrafs_fd_is_test_device(fd)) {
        fprintf(stderr,
                "cetrafs: TEST KNOB %s damages the volume and is honoured only on an image file or a loop "
                "device; refusing to run\n",
                name);
        exit(2);
    }
    return v;
}

/* A test hold, in whole seconds: at most an hour. */
static inline void cetrafs_test_hold(const char *name)
{
    cetrafs_sleep_full((unsigned) cetrafs_test_env_ll(name, 0, 3600, 0));
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
 * device, or one every node has a recorded departure for, returns
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

    c.checksum = cetrafs_cpu_to_le64(0);
    return crc32c_struct(&c, sizeof(c), offsetof(cetrafs_node_entry_t, checksum), sizeof(c.checksum)) == want;
}

/*
 * Is row 'now' the same beat by the same holder as 'then'? hb_seq alone
 * is not: it restarts at 1 when a row is registered afresh, so a row
 * retired and re-registered while we watched could read the very value
 * we sampled and look like a node that stopped. node_uuid names the
 * machine (for a REPAIR claim, its per-claim nonce) and incarnation the
 * mount session, drawn anew at every registration and re-attach (format
 * 0x000A) -- the kernel's struct cetrafs_row_mark, the same three.
 */
static inline int cetrafs_row_same_beat(const cetrafs_node_entry_t *then, const cetrafs_node_entry_t *now)
{
    return then->hb_seq == now->hb_seq && then->incarnation == now->incarnation &&
           !memcmp(then->node_uuid, now->node_uuid, sizeof(then->node_uuid));
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

    /* A recorded departure -- the node's own clean unmount, or a peer's
     * DEAD verdict after watching it stop. An exact value, not a
     * duration, so it needs no clock and stays reliable under skew. */
    if (cetrafs_le32(ne.departure) != CETRAFS_NODE_DEPART_NONE)
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
    ne->checksum = cetrafs_cpu_to_le64(0);
    ne->checksum = cetrafs_cpu_to_le64(
        crc32c_struct(ne, sizeof(*ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(ne->checksum)));
}

/*
 * COMPARE AND WRITE from userspace, for the registry row a repair claims.
 *
 * The kernel takes every contested record with one SCSI COMPARE AND
 * WRITE; the tools used to write their claim, renewals, release and
 * reaps blind and lean on a settle delay to notice a collision. A
 * second repairer that read a FREE row, stalled, then wrote, landed on
 * top of a claim that had already settled and looked -- and both went
 * on repairing (audit, reviewer's finding on L34). Through SG_IO the
 * same primitive is available here: the write lands only on the image
 * it was decided against.
 *
 * Used when the device says it has the command (Block Limits VPD,
 * MAXIMUM COMPARE AND WRITE LENGTH >= 1, as the kernel reads it) and is
 * a whole disk: on a partition the command's LBA addresses the disk, not
 * the partition. Otherwise the tools keep the blind write and the settle
 * -- a device with no CAW can only ever be mounted by one node.
 *
 * The CAW covers one logical block, the one holding the row record --
 * and, since format 0x000A, the displaced row a borrowing claim keeps at
 * CETRAFS_REPAIR_SAVED_OFF, which lies inside that first sector. One
 * swap lands both. (It used to sit past the sector and was written
 * first with WRITE(16), so two repairers racing for a row could have the
 * loser's tail land after the winner's and erase the row the winner had
 * saved -- L24.) Nothing of the row block lies past its first sector.
 *
 * Async-signal-safe: static buffers, syscalls only (the renewal runs
 * from a timer).
 */
static int cetrafs_caw_mode = -1; /* -1: not probed, 0: no CAW, 1: CAW */
static unsigned cetrafs_caw_lbs;
/* Page-aligned: SG_IO maps a suitably aligned user buffer straight into
 * the request, and a LIO target's COMPARE AND WRITE wrote garbage from a
 * buffer that started mid-page (found by tests/kernel/repair_claim_caw.sh;
 * sg3_utils, page-aligned, did not). */
static unsigned char cetrafs_caw_buf[2 * CETRAFS_BLOCK_SIZE] __attribute__((aligned(4096)));

/* One SCSI command. Returns 0 GOOD, 1 MISCOMPARE, 2 UNIT ATTENTION,
 * -1 refused before execution (the device says the command is not
 * supported, or the data is protected), -2 outcome unknown, -3 RESERVATION
 * CONFLICT: another initiator holds the device, so nothing ran. -3 is not
 * -1: a flush refused for a reservation is a flush that did not happen,
 * not a device with nothing to flush (audit 2026-11-14 U8). */
static inline int cetrafs_sg_cmd(int fd, unsigned char *cdb, unsigned char cdb_len, int dir, void *buf, unsigned len)
{
    unsigned char sense[64];
    sg_io_hdr_t io;
    unsigned char key;

    memset(&io, 0, sizeof(io));
    memset(sense, 0, sizeof(sense));
    io.interface_id = 'S';
    io.cmd_len = cdb_len;
    io.cmdp = cdb;
    io.dxfer_direction = dir;
    io.dxferp = buf;
    io.dxfer_len = len;
    io.sbp = sense;
    io.mx_sb_len = sizeof(sense);
    io.timeout = 30000;
    if (ioctl(fd, SG_IO, &io) < 0)
        return -2;
    if (io.status == 0 && io.host_status == 0 && (io.driver_status & 0x0f) == 0)
        return 0;
    if (io.status == 0x18) /* RESERVATION CONFLICT: not executed */
        return -3;
    if (io.sb_len_wr < 3)
        return -2;
    key = (sense[0] & 0x7f) >= 0x72 ? (sense[1] & 0x0f) : (sense[2] & 0x0f);
    if (key == 0x0e)
        return 1;
    if (key == 0x06)
        return 2;
    if (key == 0x05 || key == 0x07) /* ILLEGAL REQUEST, DATA PROTECT */
        return -1;
    return -2;
}

/* On the platter, whatever cache the device has: a claim is what a
 * mounting node reads. SYNCHRONIZE CACHE rather than FUA, which a
 * device without FUA support refuses as an invalid CDB field. A device
 * with no cache to flush may refuse the command too; it has nothing to
 * flush. */
static inline int cetrafs_sg_sync_cache(int fd)
{
    unsigned char cdb[10] = {0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    int i, r = -2;

    for (i = 0; i < 3; i++)
        if ((r = cetrafs_sg_cmd(fd, cdb, sizeof(cdb), SG_DXFER_NONE, NULL, 0)) != 2)
            break;
    /* -1: the device has no cache to flush. -3 (a reservation held by
     * someone else) and -2 (unknown) are a flush that did not happen. */
    return r == 0 || r == -1 ? 0 : -1;
}

static inline int cetrafs_caw_probe(int fd)
{
    struct stat st;
    char path[96];
    unsigned char cdb[6] = {0x12, 0x01, 0xb0, 0, 64, 0}, vpd[64];
    int lbs = 0;

    if (cetrafs_caw_mode >= 0)
        return cetrafs_caw_mode;
    cetrafs_caw_mode = 0;
    if (cetrafs_test_env("CETRAFS_TEST_TOOLS_NO_CAW")) /* the fallback, for its own suites */
        return 0;
    if (fstat(fd, &st) != 0 || !S_ISBLK(st.st_mode))
        return 0;
    snprintf(path, sizeof(path), "/sys/dev/block/%u:%u/partition", major(st.st_rdev), minor(st.st_rdev));
    if (access(path, F_OK) == 0)
        return 0; /* the command addresses the whole disk */
    /*
     * A device-mapper node passes SCSI commands to the disk under it,
     * and they address THAT disk's blocks: through a kpartx partition or
     * an LV that does not start at block 0, the swap's LBA is the
     * volume's and lands that far before the row -- the claim always
     * miscompares, or, over zeros, writes a stray row into whatever is
     * there (audit 2026-11-15 B-26). Only a whole multipath map
     * (dm uuid "mpath-...") addresses the volume's own blocks; the kernel
     * refuses the rest the same way (caw.c). The others take the
     * fallback, as a device without CAW does.
     */
    snprintf(path, sizeof(path), "/sys/dev/block/%u:%u/dm/uuid", major(st.st_rdev), minor(st.st_rdev));
    {
        FILE *u = fopen(path, "r");

        if (u) {
            char uuid[160] = "";
            bool mpath = fgets(uuid, sizeof(uuid), u) && strncmp(uuid, "mpath-", 6) == 0;

            fclose(u);
            if (!mpath && !cetrafs_test_env("CETRAFS_TEST_TOOLS_DM_ANY"))
                return 0;
        }
    }
    if (ioctl(fd, BLKSSZGET, &lbs) != 0 || lbs < 512 || (unsigned) lbs > CETRAFS_BLOCK_SIZE)
        return 0;
    memset(vpd, 0, sizeof(vpd));
    if (cetrafs_sg_cmd(fd, cdb, sizeof(cdb), SG_DXFER_FROM_DEV, vpd, sizeof(vpd)) != 0)
        return 0;
    if (vpd[1] != 0xb0 || vpd[5] < 1)
        return 0;
    /* And the identity itself: what a SCSI READ of block 0 returns must
     * be what a read of the device's block 0 returns, or the command
     * reaches some other block 0. */
    if (!cetrafs_test_env("CETRAFS_TEST_TOOLS_DM_ANY")) {
        static unsigned char viasg[CETRAFS_BLOCK_SIZE] __attribute__((aligned(4096)));
        static unsigned char viadev[CETRAFS_BLOCK_SIZE] __attribute__((aligned(4096)));
        unsigned char rcdb[16];
        unsigned nlb = CETRAFS_BLOCK_SIZE / (unsigned) lbs;

        memset(rcdb, 0, sizeof(rcdb));
        rcdb[0] = 0x88; /* READ(16), LBA 0 */
        rcdb[10] = (unsigned char) (nlb >> 24);
        rcdb[11] = (unsigned char) (nlb >> 16);
        rcdb[12] = (unsigned char) (nlb >> 8);
        rcdb[13] = (unsigned char) nlb;
        if (cetrafs_sg_cmd(fd, rcdb, sizeof(rcdb), SG_DXFER_FROM_DEV, viasg, sizeof(viasg)) != 0 ||
            pread(fd, viadev, sizeof(viadev), 0) != (ssize_t) sizeof(viadev) ||
            memcmp(viasg, viadev, sizeof(viasg)) != 0) {
            fprintf(stderr, "note: SCSI commands through this device reach a different block 0 -- "
                            "not using COMPARE AND WRITE on it\n");
            return 0;
        }
    }
    cetrafs_caw_lbs = (unsigned) lbs;
    cetrafs_caw_mode = 1;
    return 1;
}

static inline void cetrafs_row_drop_cache(int fd, const cetrafs_superblock_t *sb, uint32_t idx)
{
    posix_fadvise(fd, cetrafs_node_row_off(sb, idx), CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED);
}

/* The whole registry, as the device has it: a peer's row write reaches
 * the device, not this machine's page cache (audit 2026-11-14 U1).
 * POSIX_FADV_DONTNEED alone is advice: it leaves a page it cannot drop
 * at that instant where it is, and the first sample of mkfs -f's probe
 * read a FREE row a peer had claimed since, one run in two
 * (image/mkfs_probe_fresh.sh). On a block device BLKFLSBUF writes back
 * and invalidates the whole cache, every CPU's LRU drained first. */
static inline void cetrafs_registry_drop_cache(int fd, const cetrafs_superblock_t *sb)
{
    uint32_t count = cetrafs_le32(sb->node_table_count);
    struct stat st;

    if (fstat(fd, &st) == 0 && S_ISBLK(st.st_mode))
        (void) ioctl(fd, BLKFLSBUF, 0);
    if (count)
        posix_fadvise(fd, cetrafs_node_row_off(sb, 0), (off_t) count * CETRAFS_BLOCK_SIZE, POSIX_FADV_DONTNEED);
}

/*
 * Swap the row block's first logical block from old_blk to new_blk (both
 * whole row blocks; only the first lbs bytes are compared). With
 * 'write_tail', the tail of new_blk is written first when the row spans
 * several logical blocks.
 *
 * Only a CLAIM writes the tail: it is where a claim keeps the row it
 * displaced, and it means something only while the record says REPAIR.
 * The tail write is blind and lands whatever the swap then decides, so a
 * reap, renewal or release that wrote it and then miscompared had erased
 * the saved row of the live claim it lost to (audit 2026-11-06 L24). They
 * leave it alone: reap and release put back a record that never reads
 * its tail, and a renewal leaves the tail as it is.
 * Returns 0 landed, 1 the row was not old_blk (nothing written to the
 * record), -1 failed (and, when unknown, read back: not landed).
 */
static inline int cetrafs_row_caw(int fd, const cetrafs_superblock_t *sb, uint32_t idx, const unsigned char *old_blk,
                                  const unsigned char *new_blk)
{
    unsigned lbs = cetrafs_caw_lbs;
    uint64_t lba = (uint64_t) cetrafs_node_row_off(sb, idx) / lbs;
    unsigned char cdb[16];
    int i, r = -2;

    memset(cdb, 0, sizeof(cdb));
    cdb[0] = 0x89; /* COMPARE AND WRITE */
    for (i = 0; i < 8; i++)
        cdb[2 + i] = (unsigned char) (lba >> (56 - 8 * i));
    cdb[13] = 1;
    memcpy(cetrafs_caw_buf, old_blk, lbs);
    memcpy(cetrafs_caw_buf + lbs, new_blk, lbs);
    /* UNIT ATTENTION: not processed (SAM), the same swap again. */
    for (i = 0; i < 3; i++)
        if ((r = cetrafs_sg_cmd(fd, cdb, sizeof(cdb), SG_DXFER_TO_DEV, cetrafs_caw_buf, 2 * lbs)) != 2)
            break;
    cetrafs_row_drop_cache(fd, sb, idx);
    if (r == 0) {
        /* The swap LANDED: the device returned GOOD, and every reader
         * through that device sees the new row. A flush that then fails
         * does not un-land it -- reporting failure here made the caller
         * leave a claim it had taken unreleased and treat its own row as
         * not its (audit 2026-11-14 U8). The flush failure is said. */
        if (cetrafs_sg_sync_cache(fd) != 0) {
            /* write(2), not fprintf: this runs from the renewal timer. */
            static const char msg[] = "WARN: a registry claim landed but the device would not flush it\n";

            (void) !write(STDERR_FILENO, msg, sizeof(msg) - 1);
        }
        return 0;
    }
    if (r == 1)
        return r;
    if (r == -2) {
        /* Nothing says it did not execute: the device decides. */
        unsigned char rb[CETRAFS_BLOCK_SIZE];

        if (pread(fd, rb, sizeof(rb), cetrafs_node_row_off(sb, idx)) == (ssize_t) sizeof(rb) &&
            !memcmp(rb, new_blk, lbs))
            return 0;
    }
    return -1;
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
/* How long a new repair claim settles before it looks for a concurrent
 * claimant (cetrafs_repair_claim()): longer than the gap between any
 * repairer's read of a free row and its write of the claim. */
#define CETRAFS_REPAIR_SETTLE_SECS 2u
static inline unsigned cetrafs_repair_settle_secs(void)
{
    return CETRAFS_REPAIR_SETTLE_SECS;
}

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

    cetrafs_row_drop_cache(fd, sb, idx); /* the row as the device has it (class 57) */
    if (pread(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(blk))
        return;
    memcpy(&ne, blk, sizeof(ne));
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR || !cetrafs_row_same_beat(judged, &ne))
        return; /* renewed since, or another claim (another nonce) */
    memcpy(&saved, blk + CETRAFS_REPAIR_SAVED_OFF, sizeof(saved));
    memset(out, 0, sizeof(out));
    if (cetrafs_le32(saved.state) == CETRAFS_NODE_STATE_REGISTERED && cetrafs_node_row_crc_ok(&saved))
        memcpy(out, &saved, sizeof(saved));
    if (cetrafs_caw_probe(fd)) {
        /* Only over the claim as judged: one that renewed since, or was
         * reaped by someone else, miscompares and is left alone. */
        int r;

        /* Test hook only: hold between the judgement and the swap, so a
         * suite can land the repairer's renewal in between
         * (tests/kernel/repair_reap_keeps_saved.sh). */
        cetrafs_test_hold("CETRAFS_TEST_REAP_GAP_SECS");
        r = cetrafs_row_caw(fd, sb, idx, blk, out);

        if (r == 1)
            return;
        if (r != 0) {
            fprintf(stderr, "WARN: registry row %u: the dead repair claim could not be reaped\n", idx);
            return;
        }
    } else if (pwrite(fd, out, sizeof(out), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(out) ||
               fsync(fd) != 0) {
        fprintf(stderr, "WARN: registry row %u: the dead repair claim could not be reaped\n", idx);
        return;
    }
    if (cetrafs_le32(saved.state) == CETRAFS_NODE_STATE_REGISTERED && cetrafs_node_row_crc_ok(&saved)) {
        char lab[CETRAFS_NODE_LABEL_LEN + 1];

        cetrafs_label_copy(lab, sizeof(lab), saved.label, sizeof(saved.label));
        fprintf(stderr, "registry row %u: reaped a dead repair claim and gave the row back to %s\n", idx, lab);
    }
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
    cetrafs_registry_drop_cache(fd, sb); /* the first sample from the device (audit 2026-11-14 U2) */
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
            if (!changed && cetrafs_row_same_beat(&first[idx], &ne)) {
                /* Not renewed over the whole window: its repairer is
                 * gone. Give the row back, or it stays REPAIR forever. */
                cetrafs_repair_reap(fd, sb, idx, &first[idx]);
                continue;
            }
            if (out_row)
                *out_row = idx;
            if (out_label && label_sz) {
                cetrafs_label_copy(out_label, label_sz, ne.label, sizeof(ne.label));
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
 * node has provably left (departure == CLEAN, or a lease older than the
 * staleness window) is borrowed and restored.
 * The node it belongs to re-attaches by UUID, and a mount cannot happen
 * while the claim is live anyway.
 */
static unsigned char cetrafs_repair_saved[CETRAFS_BLOCK_SIZE];
static int cetrafs_repair_borrowed;
/* This claim's identity, in the row's node_uuid (unused on a REPAIR
 * row): a claim is OURS only while the row carries it. */
static uint8_t cetrafs_repair_nonce[CETRAFS_NODE_UUID_LEN];

/* Is the row at 'idx' still our claim? Async-signal-safe (pread). */
static inline int cetrafs_repair_row_is_ours(int fd, const cetrafs_superblock_t *sb, uint32_t idx)
{
    cetrafs_node_entry_t ne;

    /* A peer on another host takes a row straight on the device: "still
     * ours" from this host's cache is the unsafe answer (class 57). */
    cetrafs_row_drop_cache(fd, sb, idx);
    if (pread(fd, &ne, sizeof(ne), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(ne))
        return 0;
    return cetrafs_le32(ne.state) == CETRAFS_NODE_STATE_REPAIR &&
           !memcmp(ne.node_uuid, cetrafs_repair_nonce, sizeof(cetrafs_repair_nonce));
}

static inline void cetrafs_repair_new_nonce(void)
{
    int rfd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    struct timespec ts;
    unsigned i;

    if (rfd < 0 || read(rfd, cetrafs_repair_nonce, sizeof(cetrafs_repair_nonce)) !=
                       (ssize_t) sizeof(cetrafs_repair_nonce)) {
        clock_gettime(CLOCK_REALTIME, &ts);
        for (i = 0; i < sizeof(cetrafs_repair_nonce); i++)
            cetrafs_repair_nonce[i] = (uint8_t) ((ts.tv_nsec >> (i % 4 * 8)) ^ (getpid() >> (i % 2 * 8)) ^ i);
    }
    if (rfd >= 0)
        close(rfd);
}

/* CETRAFS_PEER_PROBE_SECS is a test knob only: the suites cannot afford
 * a real stale window per assertion. Returns 0 when unset, which is
 * every normal invocation; it SHRINKS the live-peer window, so it is
 * announced every time it is in effect (cetrafs_test_env). */
static inline unsigned cetrafs_peer_probe_secs(void)
{
    return (unsigned) cetrafs_test_env_ll("CETRAFS_PEER_PROBE_SECS", 1, CETRAFS_STALE_MAX_SECS, 0);
}

/*
 * The stale window a row advertises (cetrafs_node_entry_t.stale_secs):
 * how long that node waits for a silent peer. Anything outside the legal
 * range -- a row that is garbage, torn, or not a registered node at
 * all -- counts as the longest window a node may run, never as a short
 * one: the error must make a tool wait longer, not act sooner.
 */
static inline unsigned cetrafs_row_stale_secs(const cetrafs_node_entry_t *r)
{
    uint32_t v = cetrafs_le32(r->stale_secs);

    return v >= CETRAFS_STALE_MIN_SECS && v <= CETRAFS_STALE_MAX_SECS ? v : CETRAFS_STALE_MAX_SECS;
}

/*
 * How long a tool watches a row that looks mounted before calling its
 * node gone: as long as the most patient live node would. That is the
 * longest stale window any live row advertises (max_stale, from
 * cetrafs_row_stale_secs()), floored at four of the slowest row's own
 * beats (cetrafs_node_is_stale(), and the kernel's own mount probe).
 *
 * The wait has to be the PEERS' window, not a short guess: a node whose
 * paths have all failed has its I/O QUEUED by multipath for up to 90 s,
 * its heartbeat included, and then it all lands. A tool that waited 20 s
 * formatted or repaired a volume such a node was about to write to, and
 * one that waited the default 120 s called a node gone that its peers,
 * at 240 s, still waited for (audit F9). Before the window was on the
 * device every tool waited the legal maximum, 240 s, whatever the
 * cluster ran. Paid only when some row looks live. Both inputs are
 * clamped to their legal maxima, so a hostile row cannot make us sleep
 * for days.
 */
static inline unsigned cetrafs_probe_window(uint32_t max_advertised, unsigned max_stale)
{
    unsigned knob = cetrafs_peer_probe_secs();
    uint32_t pi = max_advertised < CETRAFS_HB_INTERVAL_MAX_SECS ? max_advertised : CETRAFS_HB_INTERVAL_MAX_SECS;
    unsigned window = max_stale >= CETRAFS_STALE_MIN_SECS && max_stale <= CETRAFS_STALE_MAX_SECS
                          ? max_stale
                          : CETRAFS_STALE_MAX_SECS;

    if (knob) /* tests: the old two-beat rule over a compressed base */
        return pi && 2 * pi + 5 > knob ? 2 * pi + 5 : knob;
    if (pi && 4 * pi > window)
        window = 4 * pi;
    return window;
}

static inline void cetrafs_repair_timer(int fd, const cetrafs_superblock_t *sb, uint32_t row, int on);
static inline void cetrafs_repair_release(int fd, const cetrafs_superblock_t *sb, uint32_t row);

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

/* Claim a row for this repairer. Returns the row, -1 if none could be
 * taken (or the write failed), -2 if another repairer claimed the
 * volume at the same time, or -3 if the superblock changed between the
 * caller's read and the claim -- in every failure the caller must not
 * proceed: an unclaimed repair is the thing being fixed. */
static inline int cetrafs_repair_claim(int fd, const cetrafs_superblock_t *sb, const char *label)
{
    uint32_t count = cetrafs_le32(sb->node_table_count), idx, slowest = 0;
    unsigned patience = 0;
    unsigned char *seen = NULL, cur[CETRAFS_BLOCK_SIZE];
    int pass, caw;

    if (!count || count > 4096)
        return -1;
    if (!cetrafs_node_table_placed_ok(fd, sb)) {
        fprintf(stderr, "ERR: the superblock places the Node Registry where it cannot be -- refusing to write a "
                        "repair claim there\n");
        return -1;
    }
    /* Test hook only: hold between the caller's "is anyone repairing?"
     * check and the claim, so a suite can start two repairers that both
     * passed it (tests/kernel/repair_claim_concurrent.sh). */
    cetrafs_test_hold("CETRAFS_TEST_REPAIR_CLAIM_DELAY_SECS");
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED); /* the rows as the device has them, not our cache */
    caw = cetrafs_caw_probe(fd);

    /*
     * Pass 0 takes a free row; pass 1 borrows a cleanly departed one
     * (departure == CLEAN); pass 2 borrows one whose node is PROVEN gone.
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

                if (cetrafs_le32(r->state) != CETRAFS_NODE_STATE_REGISTERED)
                    continue;
                if (cetrafs_le32(r->hb_interval_secs) > slowest)
                    slowest = cetrafs_le32(r->hb_interval_secs);
                if (cetrafs_row_stale_secs(r) > patience)
                    patience = cetrafs_row_stale_secs(r);
            }
            fprintf(stderr,
                    "no free or cleanly released registry row; watching for %us for one whose node is gone...\n",
                    cetrafs_probe_window(slowest, patience));
            fflush(stderr);
            cetrafs_sleep_full(cetrafs_probe_window(slowest, patience));
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
                if (!cetrafs_node_entry_blank(&ne))
                    continue; /* a live row with a flipped state, not a free one (BM-36) */
            } else {
                if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
                    continue;
                if (pass == 1 && cetrafs_le32(ne.departure) != CETRAFS_NODE_DEPART_CLEAN)
                    continue; /* not a clean departure: only a probe can tell */
                if (pass == 2 && memcmp(blk, seen + (size_t) idx * CETRAFS_BLOCK_SIZE, sizeof(blk)) != 0)
                    continue; /* written during the probe: alive, not ours to take */
                memcpy(cetrafs_repair_saved, blk, sizeof(cetrafs_repair_saved));
                cetrafs_repair_borrowed = 1;
            }
            free(seen);
            seen = NULL;
            memcpy(cur, blk, sizeof(cur)); /* the image this claim is decided against */

            memset(&ne, 0, sizeof(ne));
            ne.state = cetrafs_cpu_to_le32(CETRAFS_NODE_STATE_REPAIR);
            ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
            ne.hb_seq = cetrafs_cpu_to_le64(1);
            cetrafs_repair_new_nonce();
            memcpy(ne.node_uuid, cetrafs_repair_nonce, sizeof(ne.node_uuid));
            snprintf(ne.label, sizeof(ne.label), "%s", label);
            cetrafs_node_row_stamp(&ne);

            memset(blk, 0, sizeof(blk));
            memcpy(blk, &ne, sizeof(ne));
            /* The displaced row, on the device, not only in this
             * process: a repairer that is killed or crashes cannot run
             * its release, and whoever reaps the dead claim puts the
             * registration back from here (CETRAFS_REPAIR_SAVED_OFF,
             * inside the sector the claim's own swap writes). */
            if (cetrafs_repair_borrowed)
                memcpy(blk + CETRAFS_REPAIR_SAVED_OFF, cetrafs_repair_saved, sizeof(cetrafs_node_entry_t));
            /* Test hook only: hold between the row read above and the
             * claim, so a suite can land another claim in between
             * (tests/kernel/repair_claim_caw.sh). */
            cetrafs_test_hold("CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS");
            if (caw) {
                /* Lands only on the row as read: a claim that got there
                 * first makes this one miscompare, and that is another
                 * repairer -- the caller stops. Flushed: on the platter. */
                int r = cetrafs_row_caw(fd, sb, idx, cur, blk);

                if (r == 1) {
                    cetrafs_repair_borrowed = 0;
                    return -2;
                }
                if (r != 0)
                    return -1;
            } else {
                if (pwrite(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(blk))
                    return -1;
                /* On the platter before the first structural write, or the
                 * claim does not exist as far as a mounting node is concerned. */
                if (fsync(fd) != 0)
                    return -1;
            }
            printf("  registry claim written by %s\n", caw ? "COMPARE AND WRITE" : "a plain write (no CAW on this device)");
            fflush(stdout);
            cetrafs_repair_timer(fd, sb, idx, 1); /* renewals from here until the release */
            /* Without CAW the claim is a blind write, so two repairers
             * starting together could each
             * find the volume unclaimed and each claim it -- the same
             * row, the last write winning, or two rows -- and repair it
             * at once (audit L34). Settle, then look again past our
             * page cache: a row that no longer carries our nonce was
             * taken by the other one (not ours to release); a second
             * REPAIR row is a concurrent claimant, and both yield --
             * each repairer that sees the other stops, so the worst
             * case is both stopping, never both writing. A claim landing
             * after this look sees ours at its own and yields. */
            {
                uint32_t other;

                /* With CAW a claim is on the device when it returns: a
                 * concurrent one landed either before ours (seen now) or
                 * after (sees ours). No settle to wait out. */
                if (!caw)
                    cetrafs_sleep_full(cetrafs_repair_settle_secs());
                posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
                if (!cetrafs_repair_row_is_ours(fd, sb, idx)) {
                    cetrafs_repair_timer(fd, sb, idx, 0);
                    cetrafs_repair_borrowed = 0;
                    return -2;
                }
                for (other = 0; other < count; other++) {
                    cetrafs_node_entry_t o;

                    if (other == idx ||
                        pread(fd, &o, sizeof(o), cetrafs_node_row_off(sb, other)) != (ssize_t) sizeof(o))
                        continue;
                    if (cetrafs_le32(o.state) == CETRAFS_NODE_STATE_REPAIR) {
                        cetrafs_repair_release(fd, sb, idx);
                        return -2;
                    }
                }
            }
            /* And the superblock the caller is about to act on was read
             * BEFORE the claim: anything that changed it in between (a
             * grow that finished, a mkfs) is now under our claim but not
             * in our copy. Read it again, past the cache. */
            {
                unsigned char sblk[CETRAFS_BLOCK_SIZE];

                if (pread(fd, sblk, sizeof(sblk), 0) != (ssize_t) sizeof(sblk) ||
                    memcmp(sblk, sb, sizeof(*sb)) != 0) {
                    cetrafs_repair_release(fd, sb, idx);
                    return -3;
                }
            }
            return (int) idx;
        }
    }
    free(seen);
    return -1;
}

/* Refresh the lease. Cheap enough to call often; the caller decides how
 * often, and "too rarely" means a mount can slip in mid-repair. */
static inline int __cetrafs_repair_renew(int fd, const cetrafs_superblock_t *sb, uint32_t row)
{
    unsigned char blk[CETRAFS_BLOCK_SIZE];
    cetrafs_node_entry_t ne;

    cetrafs_row_drop_cache(fd, sb, row); /* the row as the device has it (class 57) */
    if (pread(fd, blk, sizeof(blk), cetrafs_node_row_off(sb, row)) != (ssize_t) sizeof(blk))
        return -1;
    memcpy(&ne, blk, sizeof(ne));
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR ||
        memcmp(ne.node_uuid, cetrafs_repair_nonce, sizeof(cetrafs_repair_nonce)))
        return -1; /* somebody took our row: say so rather than fight */
    ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
    ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
    cetrafs_node_row_stamp(&ne);
    if (cetrafs_caw_mode == 1) {
        /* Over the claim as we hold it: a row taken since miscompares
         * instead of being written back over. */
        static unsigned char nb[CETRAFS_BLOCK_SIZE];

        memcpy(nb, blk, sizeof(nb));
        memcpy(nb, &ne, sizeof(ne));
        return cetrafs_row_caw(fd, sb, row, blk, nb) == 0 ? 0 : -1;
    }
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
 * The SIGALRM timer below renews the same row through the same function
 * and the same static CAW buffer, and the tools also renew from their
 * work loops. A tick landing between a main-line renewal's read and its
 * CAW changed the row under it: the CAW miscompared, and fsck -r stopped
 * with "this repair's registry claim was taken away" when nothing had
 * taken it (audit 2026-11-05, N7). So the tick is held off for the
 * length of a renewal. sigprocmask() is async-signal-safe, and inside
 * the handler SIGALRM is already blocked, so the timer's own call is
 * unchanged.
 */
static inline int cetrafs_repair_renew(int fd, const cetrafs_superblock_t *sb, uint32_t row)
{
    sigset_t alrm, old;
    int ret;

    sigemptyset(&alrm);
    sigaddset(&alrm, SIGALRM);
    sigprocmask(SIG_BLOCK, &alrm, &old);
    ret = __cetrafs_repair_renew(fd, sb, row);
    sigprocmask(SIG_SETMASK, &old, NULL);
    return ret;
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
static volatile sig_atomic_t cetrafs_repair_lost; /* 1: our row was taken; 2: a node is live */
/* Set by a tool that works on a MOUNTED volume through the kernel (a
 * live grow): mounted nodes beating under its claim are expected, not a
 * node that got in, so the watch for them is off. Losing its own row
 * still stops it (1). Before this, every live grow longer than one
 * renewal died on the first write after a peer's heartbeat
 * (GROWFS-LIVE-REVIEW M1). */
static volatile sig_atomic_t cetrafs_repair_peers_expected;
static int cetrafs_renew_fd = -1;
static cetrafs_superblock_t cetrafs_renew_sb;
static uint32_t cetrafs_renew_row;

/*
 * Every other row's hb_seq as it stood when the claim was taken, so each
 * renewal can look for a node that is beating under the repair (audit
 * R4, tool half). The probe before the claim refuses a live node and the
 * kernel's mount gate refuses a mount under a live claim -- but only
 * while the claim LOOKS live, and a repairer whose own I/O is queued
 * behind dead paths does not. A refused mount never writes its row, so
 * a REGISTERED row whose hb_seq moved is a node that got in: stop before
 * writing more. Rows past the cap are not watched (registries are far
 * smaller).
 */
#define CETRAFS_REPAIR_WATCH_ROWS 256
/* Each row as it stood (zeroed if unreadable): a beat is any change of
 * hb_seq, machine or mount session (cetrafs_row_same_beat()) -- a node
 * that re-registered a row and reached the old hb_seq again got in too. */
static cetrafs_node_entry_t cetrafs_renew_seen[CETRAFS_REPAIR_WATCH_ROWS];

static inline int cetrafs_repair_row_read(int fd, const cetrafs_superblock_t *sb, uint32_t idx, cetrafs_node_entry_t *ne)
{
    if (pread(fd, ne, sizeof(*ne), cetrafs_node_row_off(sb, idx)) != (ssize_t) sizeof(*ne))
        return -1;
    return 0;
}

static inline void cetrafs_repair_watch_arm(int fd, const cetrafs_superblock_t *sb, uint32_t row)
{
    uint32_t count = cetrafs_le32(sb->node_table_count), idx;

    cetrafs_registry_drop_cache(fd, sb); /* the baseline as the device has it */
    for (idx = 0; idx < count && idx < CETRAFS_REPAIR_WATCH_ROWS; idx++)
        if (idx == row || cetrafs_repair_row_read(fd, sb, idx, &cetrafs_renew_seen[idx]) != 0)
            memset(&cetrafs_renew_seen[idx], 0, sizeof(cetrafs_renew_seen[idx]));
}

/* Async-signal-safe: pread and posix_fadvise only. 1 if some other
 * REGISTERED row beat. The registry is dropped from this machine's cache
 * first: a peer's beat is on the device, and a tick served from the cache
 * would watch the baseline forever (audit 2026-11-14 U1). */
static inline int cetrafs_repair_node_beat(int fd, const cetrafs_superblock_t *sb, uint32_t row)
{
    uint32_t count = cetrafs_le32(sb->node_table_count), idx;
    cetrafs_node_entry_t ne;

    cetrafs_registry_drop_cache(fd, sb);
    for (idx = 0; idx < count && idx < CETRAFS_REPAIR_WATCH_ROWS; idx++) {
        if (idx == row || cetrafs_repair_row_read(fd, sb, idx, &ne) != 0)
            continue;
        if (cetrafs_le32(ne.state) == CETRAFS_NODE_STATE_REGISTERED && !cetrafs_row_same_beat(&cetrafs_renew_seen[idx], &ne))
            return 1;
    }
    return 0;
}

static void cetrafs_repair_tick(int sig)
{
    int saved = errno;

    (void) sig;
    if (cetrafs_renew_fd >= 0 && cetrafs_repair_renew(cetrafs_renew_fd, &cetrafs_renew_sb, cetrafs_renew_row) != 0)
        cetrafs_repair_lost = 1;
    else if (cetrafs_renew_fd >= 0 && !cetrafs_repair_lost && !cetrafs_repair_peers_expected &&
             cetrafs_repair_node_beat(cetrafs_renew_fd, &cetrafs_renew_sb, cetrafs_renew_row))
        cetrafs_repair_lost = 2;
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
/* SIGPIPE: `fsck -r ... | head`, the reader gone. SIGABRT: an assert or
 * a libc abort mid-repair. Both killed the tool with the claim held
 * (audit F9). SIGKILL cannot be caught: that one is the reap's. */
static const int cetrafs_repair_stop_sigs[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGABRT};

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
    cetrafs_repair_watch_arm(fd, sb, row);
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

    unsigned char cur[CETRAFS_BLOCK_SIZE];

    cetrafs_repair_timer(fd, sb, row, 0); /* no renewal may land after the release */
    if (cetrafs_caw_mode == 1)
        cetrafs_row_drop_cache(fd, sb, row);
    if (!cetrafs_repair_row_is_ours(fd, sb, row) ||
        pread(fd, cur, sizeof(cur), cetrafs_node_row_off(sb, row)) != (ssize_t) sizeof(cur)) {
        cetrafs_repair_borrowed = 0;
        return; /* another repairer's claim now: not ours to give back */
    }
    if (cetrafs_repair_borrowed) {
        memcpy(blk, cetrafs_repair_saved, sizeof(blk)); /* put the registration back */
        cetrafs_repair_borrowed = 0;
    } else {
        memset(blk, 0, sizeof(blk)); /* all-zero is CETRAFS_NODE_STATE_FREE */
    }
    if (cetrafs_caw_mode == 1) {
        (void) cetrafs_row_caw(fd, sb, row, cur, blk); /* only over our own claim */
        return;
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
    /* The rows as the device has them: a peer on another host registers
     * straight to the device, and a fresh fd shares this host's page
     * cache. A node registered after that cache filled was missed, and
     * the gate it feeds said every node was ready (class 57). */
    if (!cetrafs_test_env("CETRAFS_TEST_CAPS_CACHED")) /* the control of tests/image/growfs_caps_fresh.sh */
        posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
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
        /* One row per block, like every other registry reader: a
         * 128-byte stride read row 0 and then garbage from inside its
         * block, so every node past the first was missing from the
         * readiness notice (audit 2026-11-06 L9). */
        off_t off = cetrafs_node_row_off(&sb, idx);

        if (pread(fd, &e, sizeof(e), off) != (ssize_t) sizeof(e)) {
            close(fd);
            return -1;
        }
        if (cetrafs_le32(e.state) != CETRAFS_NODE_STATE_REGISTERED)
            continue;
        cetrafs_label_copy(labels[n], CETRAFS_NODE_LABEL_LEN + 1, e.label, sizeof(e.label));
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
    unsigned patience = 0;
    unsigned budget = CETRAFS_ROW_SETTLE_BUDGET_MS;
    int found = 0;

    count = cetrafs_le32(sb.node_table_count);
    /* The first sample is the verdict on whether anybody needs watching,
     * so it must come from the device: a row this host cached while it
     * was still FREE would read "nobody" and let the caller format a
     * volume a peer has mounted since (audit 2026-11-14 U2). */
    cetrafs_registry_drop_cache(fd, &sb);
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
            if (cetrafs_row_stale_secs(&first[idx]) > patience)
                patience = cetrafs_row_stale_secs(&first[idx]);
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
            patience = CETRAFS_STALE_MAX_SECS; /* its window is unknown: assume the longest */
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
        unsigned probe = cetrafs_probe_window(slowest, patience);

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
        if (iscand[idx] == 1 && rc == 1 && cetrafs_row_same_beat(&first[idx], &now_ne))
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
            cetrafs_label_copy(out_label, label_sz, now_ne.label, sizeof(now_ne.label));
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
