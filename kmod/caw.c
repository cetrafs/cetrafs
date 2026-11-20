// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * caw.c -- generic cross-transport COMPARE AND WRITE (atomic test-and-set)
 * primitive + capability discovery.
 *
 * Every contested claim in the filesystem goes through it -- node
 * registration, Zone Group ownership, the namespace and file locks, the
 * inode bitmap, the pending-free queues: one fused compare-and-swap on
 * one record (cetrafs_cas_record() and friends, below). It replaced the
 * device-wide SCSI PR mutex the cluster was first built on. A device
 * without CAW is mounted by one node only (fs.c's mount gate), and its
 * CAS falls back to a node-local mutex (cetrafs_cas_nocaw()).
 *
 * Two backends behind one interface:
 *
 *  - SCSI COMPARE AND WRITE (opcode 0x89): one fused command carrying a
 *    data-out buffer of 2 x the transfer length -- the compare (expected)
 *    image followed by the write (new) image. The target atomically
 *    reads the LBA range, compares to the first half, and writes the
 *    second half iff equal; a mismatch returns CHECK CONDITION with
 *    MISCOMPARE sense. This is what VMware VAAI "ATS" is built on.
 *    Fully implemented here via scsi_execute_cmd().
 *
 *  - NVMe fused Compare(0x05)+Write(0x01): NVMe's COMPARE is compare-ONLY,
 *    so an atomic CAS needs a FUSED command pair (FUSE=01b then 10b)
 *    submitted as one linked unit in a single submission queue. The
 *    kernel exposes NO module-callable API for fused NVMe passthrough:
 *    nvme_submit_sync_cmd() is exported, but it issues ONE command per
 *    request, and nothing in blk-mq keeps two requests adjacent in one
 *    queue under a single doorbell, which is what the spec requires of
 *    a fused pair. The user passthrough paths (ioctl, io_uring) refuse
 *    any nonzero command flags, the field FUSE lives in, with -EINVAL;
 *    and the in-kernel target (nvmet) rejects fused commands outright,
 *    so a Linux-served namespace has none to offer either (all checked
 *    against the 7.2 source). So the NVMe backend is a deliberate,
 *    documented stub returning -EOPNOTSUPP -- implementing it needs
 *    either an nvme-driver change to export a fused primitive or an
 *    in-tree home for this code. Fused-capable targets do exist (SPDK's
 *    NVMe-oF target, arrays that back VMFS over NVMe-oF); the missing
 *    piece is the Linux initiator.
 *    The real deployment target (an FC/iSCSI LUN) presents SCSI anyway.
 *
 * Block size: the atomic unit is one LOGICAL block (bdev_logical_block_
 * size()) -- 512 on a 512-logical LUN, 4096 on a 4Kn one. The filesystem
 * block size (4096) is unrelated; a caller that wants an atomic record
 * update supplies a logical-block-sized, logical-block-aligned region.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/sched/mm.h>
#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/moduleparam.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/unaligned.h>
#include <linux/wait.h>

#include <scsi/scsi_common.h>
#include <scsi/scsi_device.h>
#include <scsi/scsi_proto.h>

#include "kmod.h"

/* scsi_execute_cmd timeout, in jiffies. A CAW is a single small
 * synchronous command; this is a generous ceiling, not a target. */
#define CETRAFS_CAW_TIMEOUT_JIFFIES (10 * HZ)

/* Retries for conditions the target reports as "command not executed"
 * (UNIT ATTENTION, ABORTED COMMAND) -- never for MISCOMPARE. */
#define CETRAFS_CAW_RETRIES 5
/* Paths one CAW over dm tries after a not-executed refusal of a path. */
#define CETRAFS_CAW_PATH_TRIES 4

/*
 * Count of compare-and-swaps that lost their race and were retried
 * against a fresh image -- i.e. MISCOMPAREs the device reported.
 *
 * It exists so a concurrency test can prove the contention it claims to
 * create. The real-hardware stress passes with "0 errors", which looks
 * conclusive and is not: each CAW costs ~32 ms on the LUN, so eight
 * threads could in principle take turns and never collide once, and the
 * run would be just as green while exercising nothing. A nonzero count
 * here is the evidence that the atomic path was genuinely contended.
 */
static atomic64_t cetrafs_cas_miscompares = ATOMIC64_INIT(0);

/* Every compare-and-swap attempted. Counted for the same reason
 * cas_miscompares is: a CAW is a passthrough request and the block
 * layer does not account it, so on a real LUN these are the tens of
 * milliseconds each that appear in no /sys/block counter. Without this
 * the only way to see them is a tracer. */
static atomic64_t cetrafs_cas_ops = ATOMIC64_INIT(0);

u64 cetrafs_cas_op_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_ops);
}

void cetrafs_cas_op_counted(void)
{
    atomic64_inc(&cetrafs_cas_ops);
}

/* Waits of a swap whose outcome was unknown for a path to answer
 * (cetrafs_cas_undecided_nap()). */
static atomic64_t cetrafs_cas_undecided_naps = ATOMIC64_INIT(0);

u64 cetrafs_cas_undecided_nap_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_undecided_naps);
}

u64 cetrafs_cas_miscompare_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_miscompares);
}

/*
 * Opt-in, read-only capability probe. Set caw_probe=<device> at insmod
 * (e.g. caw_probe=/dev/sda) and the module logs what cetrafs_caw_
 * discover() finds for that device at load time, then does nothing
 * further -- a way to validate the primitive against real SCSI hardware
 * without mounting or writing anything (discovery is a read-only
 * INQUIRY). Empty by default: the module touches no device on its own.
 */
static char *caw_probe;
module_param(caw_probe, charp, 0444);
MODULE_PARM_DESC(caw_probe, "device to run a read-only ATS/CAW capability probe against at module load (diagnostic)");

/*
 * Test-only: make cetrafs_caw_discover() fail, to exercise what a mount
 * does when it cannot determine the device's capability.
 *
 * A knob is needed because the real failure modes -- a kzalloc(64)
 * returning NULL, a target that stops answering INQUIRY mid-probe --
 * cannot be provoked from a test, and the behaviour they select is the
 * volume's entire safety model. Without this the "refuse the mount"
 * path would be reasoning nobody ever ran.
 */
/* TEST ONLY: make the next COMPARE AND WRITE issued over a dm path fail
 * with a transport error, once. A second real path to the same LUN
 * cannot be fabricated on a single-path test box, so this is what
 * exercises the rotation in dmpath.c: the failure must be absorbed by a
 * retry on a re-resolved path, not surface to the caller. Off in
 * production. */
static bool cetrafs_caw_fail_path_once;
cetrafs_test_param(caw_fail_path_once, cetrafs_caw_fail_path_once, bool, 0644);
MODULE_PARM_DESC(caw_fail_path_once, "TEST ONLY: fail the next CAW issued over a dm path, once");

/*
 * Test-only: report a timed-out command, with the two outcomes a real
 * timeout leaves ambiguous.
 *
 *   landed  -- the swap IS issued and then reported as timed out, which
 *              is the dangerous case: the device has the new image and
 *              the caller does not know it.
 *   lost    -- the swap is NOT issued and reported as timed out.
 *
 * Both must end with the mutator having been applied EXACTLY ONCE. A
 * mutator that adds a delta is the one that can tell the difference.
 */
/* TEST ONLY: the next swap made through cetrafs_cas_region_judged() is
 * executed and then reported timed out (tests/kernel/ibmap_cas_image_only.sh). */
static bool cetrafs_cas_judged_timeout_once;
cetrafs_test_param(cas_judged_timeout_once, cetrafs_cas_judged_timeout_once, bool, 0644);
MODULE_PARM_DESC(cas_judged_timeout_once, "TEST ONLY: next judged CAS executes, then reports a timeout");

static bool cetrafs_caw_timeout_landed_once;
cetrafs_test_param(caw_timeout_landed_once, cetrafs_caw_timeout_landed_once, bool, 0644);
MODULE_PARM_DESC(caw_timeout_landed_once, "TEST ONLY: next CAW executes, then reports a timeout");

static bool cetrafs_caw_timeout_lost_once;
cetrafs_test_param(caw_timeout_lost_once, cetrafs_caw_timeout_lost_once, bool, 0644);
MODULE_PARM_DESC(caw_timeout_lost_once, "TEST ONLY: next CAW does not execute and reports a timeout");

/* TEST ONLY: the late-landing half of a timeout. The next CAW is NOT
 * issued and reported as timed out -- so the re-read finds the pre-image
 * and the caller retries -- and is then executed just before the CAW
 * after it, the way a command still queued on the array lands behind
 * the host's back. */
/*
 * The re-read that settles a command whose outcome is UNKNOWN. It has to
 * be the DEVICE talking: the whole verdict is "is our image on the
 * platter?". cetrafs_bread_uncached() deliberately keeps a DIRTY
 * buffer's local bytes rather than reading over them (it would discard a
 * write not yet issued), so for a dirty buffer it answers with this
 * node's own copy -- which may hold the pre-image while the device holds
 * the post-image, and then a swap that landed is taken as not landed and
 * applied again. A dirty buffer cannot answer the question: refuse, and
 * the caller reports the outcome as unknown (-EIO) rather than guess.
 *
 * TEST ONLY: cas_verify_dirty_once dirties this node's cached copy of
 * the block right before the next verify, which only a real CAW device
 * reaches (the selftest's phase 2d).
 */
static bool cetrafs_cas_verify_dirty_once;
cetrafs_test_param(cas_verify_dirty_once, cetrafs_cas_verify_dirty_once, bool, 0644);
MODULE_PARM_DESC(cas_verify_dirty_once, "TEST ONLY: the next unknown-outcome re-read finds the cached copy dirty");

/* The mount whose CAS selftest is driving the undecidable-outcome case
 * (phase 2d) right now, and whether that case reached its stop. That
 * stop is the correct answer in production (docs/internal/ERRORS.md),
 * and taken at mount it failed the selftest's own restore and with it
 * every CAW mount that armed cas_selftest. For that one mount, during
 * that one injected call, the stop is recorded instead of taken -- and
 * the selftest asserts it was reached. */
static struct super_block *cetrafs_cas_selftest_sb;
static bool cetrafs_cas_selftest_stop_seen;

/*
 * A swap whose outcome is unknown keeps its call alive until it has an
 * answer. A transport failure on the way to that answer -- the re-read,
 * the flush, the retry refused or finding no path -- is not one; it
 * used to end the call, and every undecided call that ends stops the
 * mount, so one path failover with a peer CAS in the same seconds
 * stopped a node, and its peers failed over with it (audit 2026-11-15
 * M-21, M-22). Wait instead, backing off, and let the next attempt's
 * fresh read judge. Bounded: the lease fences this node long before the
 * window (cetrafs_sb_is_fenced()), and a fenced mount writes nothing.
 */
static unsigned long cetrafs_cas_undecided_window(struct super_block *sb)
{
    return (unsigned long) max(cetrafs_sb_stale_secs(sb), 10u) * HZ;
}

/* TEST ONLY: an undecided swap ends on a transport error, as before
 * (tests/kernel/cas_undecided_waits.sh's control). */
static bool cetrafs_cas_undecided_wait_off;
cetrafs_test_param(cas_undecided_wait_off, cetrafs_cas_undecided_wait_off, bool, 0644);

static bool cetrafs_cas_undecided_nap(struct super_block *sb, unsigned long until, int *naps)
{
    if (READ_ONCE(cetrafs_cas_undecided_wait_off) || cetrafs_sb_is_fenced(sb) || time_after(jiffies, until))
        return false;
    atomic64_inc(&cetrafs_cas_undecided_naps);
    msleep(min(50u << min(*naps, 5), 1000u));
    (*naps)++;
    return true;
}

/*
 * The re-read that decides an unknown outcome, from the DEVICE: a bio
 * into a private page, never the buffer cache.
 *
 * It went through cetrafs_bread_uncached_retry(), which -- rightly, for
 * every other caller -- keeps this node's own DIRTY copy rather than
 * fetching over a pending write. Here that copy answers nothing: the
 * question is what the device holds, and a dirty buffer made it
 * unanswerable, so the swap was declared undecidable and the mount
 * stopped (audit 2026-11-11 C3, tests/kernel/cas_verify_reads_device.sh).
 * The cached copy is reconciled afterwards by the caller, as for any
 * swap (cetrafs_cas_publish_cache()).
 */
static int cetrafs_cas_verify_read(struct super_block *sb, u64 fs_lba, u8 *out)
{
    struct page *pg;
    int attempt, ret = -EIO;

    if (cetrafs_cas_verify_dirty_once) {
        struct buffer_head *bh = sb_find_get_block(sb, fs_lba);

        cetrafs_cas_verify_dirty_once = false;
        if (bh) {
            if (buffer_uptodate(bh)) {
                cetrafs_bh_begin_update(bh); /* no change: only dirtied, by the protocol */
                cetrafs_bh_end_update(sb, bh);
            }
            brelse(bh);
        }
    }
    pg = alloc_page(GFP_NOIO);
    if (!pg)
        return -ENOMEM;
    for (attempt = 0; attempt < 3 && ret; attempt++) {
        struct bio *bio = bio_alloc(sb->s_bdev, 1, REQ_OP_READ | REQ_SYNC, GFP_NOIO);

        bio->bi_iter.bi_sector = (sector_t) fs_lba * (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT);
        __bio_add_page(bio, pg, CETRAFS_BLOCK_SIZE, 0);
        ret = submit_bio_wait(bio);
        bio_put(bio);
        if (ret && attempt < 2)
            msleep(10);
    }
    if (!ret)
        memcpy(out, page_address(pg), CETRAFS_BLOCK_SIZE);
    __free_page(pg);
    return ret;
}

/* TEST ONLY: the next no-CAW swap holds the fallback's mutex this much
 * longer, so a suite can kill a CAS waiting behind it
 * (cas_nocaw_wait_killable.sh). One-shot. */
/* TEST ONLY: no fence test between the read and the swap (B-19's control). */
static bool cetrafs_cas_gate_last_off;
cetrafs_test_param(cas_gate_last_off, cetrafs_cas_gate_last_off, bool, 0644);

static unsigned int cetrafs_cas_nocaw_stall_ms;
cetrafs_test_param(cas_nocaw_stall_ms, cetrafs_cas_nocaw_stall_ms, uint, 0644);
MODULE_PARM_DESC(cas_nocaw_stall_ms, "TEST ONLY: the next no-CAW CAS holds its mutex this many ms longer (one-shot)");

static bool cetrafs_caw_timeout_late_once;
cetrafs_test_param(caw_timeout_late_once, cetrafs_caw_timeout_late_once, bool, 0644);
MODULE_PARM_DESC(caw_timeout_late_once, "TEST ONLY: next CAW reports a timeout, then lands just before the next one");

/* TEST ONLY: the same, landing EARLIER -- after the re-read that found
 * the pre-image, but before the retry reads the region again. That retry
 * then reads the post-image as its starting point, and without the check
 * in cetrafs_cas_region_seeded_impl() it applied the mutator on top of
 * it: an increment landed twice. caw_timeout_late_once lands after that
 * read, so it only ever exercised the interleaving already handled. */
static bool cetrafs_caw_timeout_late_preread_once;
cetrafs_test_param(caw_timeout_late_preread_once, cetrafs_caw_timeout_late_preread_once, bool, 0644);
MODULE_PARM_DESC(caw_timeout_late_preread_once,
                 "TEST ONLY: next CAW reports a timeout, then lands just before the retry re-reads the region");

/* TEST ONLY: the next CAW over a dm path executes and then reports a
 * failure with sense (a MEDIUM or HARDWARE ERROR after the write). */
/* TEST ONLY: the next CAW on a plain SCSI device executes, then reports
 * this sense key -- what a MEDIUM ERROR or ABORTED COMMAND after the
 * write landed looks like. 0 = off. */
static int cetrafs_caw_sense_landed_once;
cetrafs_test_param(caw_sense_landed_once, cetrafs_caw_sense_landed_once, int, 0644);
MODULE_PARM_DESC(caw_sense_landed_once, "TEST ONLY: next sd CAW executes, then reports this sense key");

/* TEST ONLY: the next this-many CAWs are refused NOT READY / standby
 * port (asc 0x04 ascq 0x0b) without being issued -- what an
 * active/passive array answers on its passive port
 * (tests/kernel/caw_not_ready_rotates.sh). */
static int cetrafs_caw_not_ready_count;
cetrafs_test_param(caw_not_ready_count, cetrafs_caw_not_ready_count, int, 0644);
MODULE_PARM_DESC(caw_not_ready_count, "TEST ONLY: refuse the next N CAWs NOT READY (not executed)");

/* TEST ONLY: a definite refusal over a dm path reported as an unknown
 * outcome, as before audit 2026-11-15 M-22 (its suite's control). */
static bool cetrafs_caw_definite_as_unknown;
cetrafs_test_param(caw_definite_as_unknown, cetrafs_caw_definite_as_unknown, bool, 0644);

static struct {
    u8 *compare, *write_data;
    u64 lba;
    unsigned int nblocks;
    bool before_read; /* caw_timeout_late_preread_once: land at the CAS layer's re-read */
} cetrafs_caw_late;

/* Execute the held-back command now (the test knobs above). */
static void cetrafs_caw_land_held(struct block_device *bdev)
{
    u8 *c = cetrafs_caw_late.compare, *w = cetrafs_caw_late.write_data;

    cetrafs_caw_late.compare = NULL;
    cetrafs_caw_late.write_data = NULL;
    pr_warn("CAW lba=%llu: TEST late landing -- the timed-out command lands now\n",
            (unsigned long long) cetrafs_caw_late.lba);
    (void) cetrafs_caw(bdev, cetrafs_caw_late.lba, cetrafs_caw_late.nblocks, c, w, false);
    kfree(c);
    kfree(w);
}

static bool cetrafs_caw_fail_discover;
cetrafs_test_param(caw_fail_discover, cetrafs_caw_fail_discover, bool, 0644);
MODULE_PARM_DESC(caw_fail_discover, "test-only: force CAW capability discovery to fail");

void cetrafs_caw_probe_at_load(void)
{
    struct file *f;
    struct block_device *bdev;
    struct cetrafs_caw_info info;
    int ret;

    if (!caw_probe || !*caw_probe)
        return;

    f = bdev_file_open_by_path(caw_probe, BLK_OPEN_READ, &caw_probe, NULL);
    if (IS_ERR(f)) {
        pr_info("caw probe: cannot open %s read-only: %ld\n", caw_probe, PTR_ERR(f));
        return;
    }
    bdev = file_bdev(f);

    ret = cetrafs_caw_discover(bdev, &info);
    if (ret)
        pr_info("caw probe: discover(%s) failed: %d\n", caw_probe, ret);
    else
        pr_info("caw probe: %s -> class=%s logical_block_size=%u max_caw_blocks=%u (atomic CAW %s)\n", caw_probe,
                cetrafs_caw_class_name(info.klass), info.logical_block_size, info.max_caw_blocks,
                info.max_caw_blocks ? "available" : "unavailable");

    /*
     * Give the dmpath cache slot back.
     *
     * Discovery on a stacked device resolves a SCSI path and CACHES it,
     * holding the path device open and an sdev reference with it. This
     * probe then closed its own handle and walked away, so a load-time
     * probe permanently consumed one of the four slots -- and kept a
     * device open that nothing was using -- for a bdev nobody will ever
     * ask about again.
     */
    cetrafs_dmpath_forget(bdev);
    bdev_fput(f);
}

const char *cetrafs_caw_class_name(enum cetrafs_caw_class klass)
{
    switch (klass) {
    case CETRAFS_CAW_SCSI:
        return "scsi";
    case CETRAFS_CAW_NVME:
        return "nvme";
    default:
        return "none";
    }
}

/*
 * Resolve the SCSI device backing 'bdev', taking a reference on success
 * (caller must scsi_device_put()). NULL if the device isn't SCSI.
 *
 * scsi_device_from_queue() would be the obvious call but it's a local,
 * non-exported symbol on this kernel; the exported route is via the
 * device model: a SCSI sd disk's gendisk device has the scsi_device's
 * sdev_gendev as its parent, which scsi_is_sdev_device() identifies.
 */
struct scsi_device *cetrafs_caw_get_sdev(struct block_device *bdev)
{
    struct device *ddev;
    struct scsi_device *sdev;

    if (!bdev || !bdev->bd_disk)
        return NULL;
    /* A partition's gendisk is the WHOLE disk's, so the device found
     * below is the whole disk's -- and a COMPARE AND WRITE sent to it at
     * a partition-relative LBA lands bd_start_sect earlier. A compare of
     * zeros against zeros there succeeds and writes the wrong block.
     * dmpath.c refuses a path with an offset for the same reason
     * (cetrafs_dmpath_identical()); this is the plain-SCSI half. No
     * device here means no atomic CAW, and the mount gate then allows
     * one mounter only. */
    if (bdev_is_partition(bdev))
        return NULL;

    ddev = disk_to_dev(bdev->bd_disk);
    if (!ddev || !ddev->parent || !scsi_is_sdev_device(ddev->parent))
        return NULL;

    sdev = to_scsi_device(ddev->parent);
    if (scsi_device_get(sdev) != 0)
        return NULL;
    return sdev;
}

/* Issue one SCSI COMPARE AND WRITE. 'half' buffers are each
 * nblocks * logical_block_size bytes. Returns 0 on success, -EBUSY on
 * MISCOMPARE (another writer changed the region), -EIO when the target
 * says it did not execute for a reason another path cannot change,
 * -EAGAIN when it says it did not execute for a reason of THIS path (a
 * standby or transitioning port, a busy one), -ETIMEDOUT when nothing
 * says it did not execute. */
static int cetrafs_caw_scsi(struct scsi_device *sdev,
                            u64 lba,
                            unsigned int nblocks,
                            const void *compare,
                            const void *write_data,
                            unsigned int lbs)
{
    unsigned int half = nblocks * lbs;
    unsigned char cdb[16] = {0};
    struct scsi_sense_hdr sshdr;
    struct scsi_exec_args args;
    u8 *sense;
    void *buf;
    int ret;
    int attempt;

    /* NOFS: every claim and publish comes through here, namespace
     * locks and alloc_mutex held (audit 2026-11-14 N6). */
    buf = kmalloc((size_t) half * 2, GFP_NOFS);
    if (!buf)
        return -ENOMEM;
    sense = kzalloc(SCSI_SENSE_BUFFERSIZE, GFP_NOFS);
    if (!sense) {
        kfree(buf);
        return -ENOMEM;
    }

    memcpy(buf, compare, half);
    memcpy((u8 *) buf + half, write_data, half);

    cdb[0] = 0x89; /* COMPARE AND WRITE */
    put_unaligned_be64(lba, &cdb[2]);
    cdb[13] = (u8) nblocks; /* NUMBER OF LOGICAL BLOCKS */

    memset(&args, 0, sizeof(args));
    args.sense = sense;
    args.sense_len = SCSI_SENSE_BUFFERSIZE;
    args.sshdr = &sshdr;

    /*
     * scsi_execute_cmd()'s own retry count stays 0 -- a MISCOMPARE must
     * surface to the caller, never be silently retried with the same
     * (now-stale) compare image. Every result is sorted by WHO says the
     * command did not execute (BUG-CLASSES class 30):
     *
     *  - MISCOMPARE: the compare failed, nothing was written (-EBUSY).
     *  - UNIT ATTENTION: SAM -- the command that receives one was not
     *    processed. Routine on a two-node cluster (ASC 0x2A: the OTHER
     *    node's PR and CAW traffic, "Parameters changed" in dmesg), so
     *    it is retried here: the same compare image, the same atomic
     *    swap, not a blind re-write.
     *  - RESERVATION CONFLICT status, DATA PROTECT, and ILLEGAL REQUEST
     *    against the CDB itself (ASC 0x20 opcode, 0x21 LBA out of
     *    range, 0x24 field in CDB): refused before any medium access --
     *    a definite -EIO.
     *  - NOT READY with ASC 0x04 (logical unit not ready: a standby or
     *    unavailable ALUA port, a transition in progress), and the
     *    BUSY / TASK SET FULL statuses: the command was not accepted
     *    for processing (SAM, SPC). Definite, and about this PATH: a
     *    busy one is retried here after a pause, and either ends as
     *    -EAGAIN so a dm caller can rotate to another path. They read
     *    as unknown once, and an active/passive failover then sent the
     *    swap through the undecided machinery, whose contended exits
     *    stop the mount (audit 2026-11-15 M-22, N-66).
     *  - Anything else -- ABORTED COMMAND, MEDIUM ERROR, HARDWARE
     *    ERROR, NOT READY for another cause, ILLEGAL REQUEST in the
     *    parameter data, no sense at all: nothing promises the write
     *    did not happen. That
     *    is UNKNOWN (-ETIMEDOUT), which cetrafs_cas_region_seeded_impl()
     *    settles by reading the region back. ABORTED COMMAND used to be
     *    retried here as "not executed"; if it had landed, the retry
     *    MISCOMPAREd and the caller re-ran its mutator on its own
     *    post-image -- a delta applied twice. The dm branch already read
     *    these as unknown; this branch now agrees with it.
     */
    for (attempt = 0; attempt <= CETRAFS_CAW_RETRIES; attempt++) {
        bool valid;

        memset(sense, 0, SCSI_SENSE_BUFFERSIZE);
        memset(&sshdr, 0, sizeof(sshdr));

        if (READ_ONCE(cetrafs_caw_not_ready_count) > 0) {
            /* TEST ONLY: refused by a standby port, never issued. */
            WRITE_ONCE(cetrafs_caw_not_ready_count, cetrafs_caw_not_ready_count - 1);
            sshdr.response_code = 0x70;
            sshdr.sense_key = NOT_READY;
            sshdr.asc = 0x04;
            sshdr.ascq = 0x0b; /* target port in standby state */
            ret = SAM_STAT_CHECK_CONDITION;
            valid = true;
        } else {
            ret = scsi_execute_cmd(sdev, cdb, REQ_OP_DRV_OUT, buf, half * 2, CETRAFS_CAW_TIMEOUT_JIFFIES, 0,
                                   &args);
            valid = scsi_sense_valid(&sshdr);
        }
        if (!ret && cetrafs_caw_sense_landed_once) {
            /* TEST ONLY: it executed; report a sense key anyway. */
            memset(&sshdr, 0, sizeof(sshdr));
            sshdr.response_code = 0x70;
            sshdr.sense_key = (u8) cetrafs_caw_sense_landed_once;
            cetrafs_caw_sense_landed_once = 0;
            pr_warn("CAW lba=%llu: TEST caw_sense_landed_once -- executed, reporting sense key 0x%x\n",
                    (unsigned long long) lba, sshdr.sense_key);
            ret = SAM_STAT_CHECK_CONDITION;
            valid = true;
        }
        if (!ret)
            break;

        if (valid) {
            if (sshdr.sense_key == MISCOMPARE) {
                ret = -EBUSY;
                break;
            }
            if (sshdr.sense_key == UNIT_ATTENTION) {
                if (attempt < CETRAFS_CAW_RETRIES) {
                    pr_info_ratelimited("CAW lba=%llu retrying after unit attention asc=0x%02x ascq=0x%02x\n",
                                        (unsigned long long) lba, sshdr.asc, sshdr.ascq);
                    continue;
                }
                pr_err("CAW lba=%llu still failing after %d retries (unit attention asc=0x%02x ascq=0x%02x)\n",
                       (unsigned long long) lba, CETRAFS_CAW_RETRIES, sshdr.asc, sshdr.ascq);
                ret = -EAGAIN;
                break;
            }
            if (sshdr.sense_key == NOT_READY && sshdr.asc == 0x04) {
                pr_warn_ratelimited("CAW lba=%llu: path not ready (asc=0x04 ascq=0x%02x), not executed\n",
                                    (unsigned long long) lba, sshdr.ascq);
                ret = -EAGAIN;
                break;
            }
            if (sshdr.sense_key == DATA_PROTECT ||
                (sshdr.sense_key == ILLEGAL_REQUEST &&
                 (sshdr.asc == 0x20 || sshdr.asc == 0x21 || sshdr.asc == 0x24))) {
                pr_err_ratelimited("CAW lba=%llu refused (not executed): sense key 0x%x asc=0x%02x ascq=0x%02x\n",
                                   (unsigned long long) lba, sshdr.sense_key, sshdr.asc, sshdr.ascq);
                ret = -EIO;
                break;
            }
            /* Say what the target actually reported: without this there
             * is nothing anywhere to debug a failed swap from. */
            pr_err_ratelimited("CAW lba=%llu failed: sense key 0x%x asc=0x%02x ascq=0x%02x -- outcome UNKNOWN\n",
                               (unsigned long long) lba, sshdr.sense_key, sshdr.asc, sshdr.ascq);
            ret = -ETIMEDOUT;
            break;
        }
        if (ret > 0 && (ret & 0xff) == SAM_STAT_RESERVATION_CONFLICT) {
            /* A STATUS, not sense data: the target refused the command
             * without executing it (SAM) -- a definite failure. */
            pr_err_ratelimited("CAW lba=%llu refused: RESERVATION CONFLICT (not executed)\n",
                               (unsigned long long) lba);
            ret = -EIO;
            break;
        }
        if (ret > 0 && ((ret & 0xff) == SAM_STAT_BUSY || (ret & 0xff) == SAM_STAT_TASK_SET_FULL)) {
            /* A STATUS: the target did not accept the command (SAM). */
            if (attempt < CETRAFS_CAW_RETRIES) {
                msleep(20 << attempt);
                continue;
            }
            pr_warn_ratelimited("CAW lba=%llu: target still busy (status 0x%02x), not executed\n",
                                (unsigned long long) lba, ret & 0xff);
            ret = -EAGAIN;
            break;
        }
        /* No valid sense: the target never answered. A timeout says the
         * HOST stopped waiting, not that the command was not executed. */
        pr_err_ratelimited("CAW lba=%llu failed with no valid sense (scsi_execute_cmd returned %d) -- "
                           "outcome UNKNOWN\n",
                           (unsigned long long) lba, ret);
        ret = -ETIMEDOUT;
        break;
    }

    kfree(sense);
    kfree(buf);
    return ret;
}

static int cetrafs_caw_nvme(struct block_device *bdev,
                            u64 lba,
                            unsigned int nblocks,
                            const void *compare,
                            const void *write_data,
                            unsigned int lbs)
{
    (void) bdev;
    (void) lba;
    (void) nblocks;
    (void) compare;
    (void) write_data;
    (void) lbs;
    /* See the file header: no module-callable fused-op API exists. */
    return -EOPNOTSUPP;
}

/*
 * Discover the transport class, logical block size, and maximum atomic
 * compare-and-write length (in logical blocks) of 'bdev'. Always fills
 * *out and returns 0 on a usable bdev; a caller checks out->klass /
 * out->max_caw_blocks. max_caw_blocks == 0 means "no atomic CAW here".
 *
 * This issues a VPD INQUIRY on the SCSI path, so it's not free -- callers
 * should discover ONCE (e.g. at mount) and cache the result, not call it
 * per operation.
 */
/* TEST ONLY: the next N Block Limits VPD reads fail as a transient
 * error would -- the page-list read included (C1). */
static unsigned int cetrafs_caw_vpd_fail;
cetrafs_test_param(caw_vpd_fail, cetrafs_caw_vpd_fail, uint, 0644);
MODULE_PARM_DESC(caw_vpd_fail, "TEST ONLY: fail the next N Block Limits VPD probes as if transient");

/*
 * The Block Limits VPD page (0xB0) into 'vpd' (64 bytes). 0; -ENODATA
 * when the device's page list (page 0) is readable and does not carry
 * 0xB0 -- the one failure that means "no such page"; -EIO when nothing
 * could be learnt. A transient failure is retried before it is believed.
 */
static int cetrafs_caw_vpd_b0(struct scsi_device *sdev, unsigned char *vpd)
{
    int tries, i, n;

    for (tries = 0; tries < 3; tries++) {
        if (cetrafs_caw_vpd_fail) {
            cetrafs_caw_vpd_fail--;
            msleep(100);
            continue;
        }
        if (scsi_get_vpd_page(sdev, 0xB0, vpd, 64) == 0)
            return 0;
        msleep(100);
    }
    if (sdev->skip_vpd_pages || !scsi_device_supports_vpd(sdev))
        return -ENODATA; /* the device does not do VPD at all */
    if (cetrafs_caw_vpd_fail) {
        cetrafs_caw_vpd_fail--;
        return -EIO;
    }
    memset(vpd, 0, 64);
    if (scsi_get_vpd_page(sdev, 0x00, vpd, 64) != 0)
        return -EIO;
    n = min_t(int, (vpd[2] << 8 | vpd[3]) + 4, 64);
    for (i = 4; i < n; i++)
        if (vpd[i] == 0xB0)
            return -EIO; /* listed, and still not given: not an answer */
    return -ENODATA;
}

int cetrafs_caw_discover(struct block_device *bdev, struct cetrafs_caw_info *out)
{
    struct scsi_device *sdev;

    if (!bdev || !bdev->bd_disk || !out)
        return -EINVAL;

    memset(out, 0, sizeof(*out));

    if (cetrafs_caw_fail_discover) {
        pr_info("CAW: discovery forced to fail (caw_fail_discover=1)\n");
        return -EIO;
    }
    out->logical_block_size = bdev_logical_block_size(bdev);

    if (bdev_is_partition(bdev))
        pr_warn("CAW: %pg is a partition -- COMPARE AND WRITE would address the whole disk; treating as no "
                "atomic CAW (one mounter only). Use the whole LUN for a shared volume.\n",
                bdev);
    sdev = cetrafs_caw_get_sdev(bdev);
    if (!sdev && !bdev_is_partition(bdev)) {
        /* dm (multipath): probe via a path -- see dmpath.c. A path that
         * exists and could not be probed is not "no CAW" (C1). */
        int prc = cetrafs_dmpath_probe(bdev, &sdev);

        if (prc == -EAGAIN) {
            pr_err("CAW: %s is backed by a SCSI path that could not be probed just now -- not "
                   "guessing that it has no atomic CAW; retry the mount once its paths are up\n",
                   bdev->bd_disk->disk_name);
            return -EAGAIN;
        }
    }
    if (sdev) {
        unsigned char *vpd = kzalloc(64, GFP_KERNEL);
        int rc;

        out->klass = CETRAFS_CAW_SCSI;
        if (!vpd) {
            /* "Could not determine" is NOT "no CAW", and the difference
             * decides this volume's entire safety model: a false
             * negative here makes a CAW-capable shared LUN look like a
             * single-mounter device, so this node would use the
             * no-CAW fallback -- which has no cross-node atomicity --
             * while a peer that probed successfully uses real
             * compare-and-swap and believes it is protected. Report the
             * failure and let the caller refuse the mount. */
            scsi_device_put(sdev);
            return -ENOMEM;
        }
        /* Block Limits VPD page (0xB0), byte 5 = MAXIMUM COMPARE AND
         * WRITE LENGTH, in logical blocks (0 => CAW unsupported). */
        rc = cetrafs_caw_vpd_b0(sdev, vpd);
        if (rc == 0) {
            out->max_caw_blocks = vpd[5];
        } else if (rc == -ENODATA) {
            /* The device lists the pages it has, and Block Limits is not
             * among them: an old target, genuinely without CAW. */
            pr_warn("CAW: %s has no Block Limits VPD page -- no atomic CAW\n", bdev->bd_disk->disk_name);
        } else {
            /* It could not be asked. scsi_get_vpd_page() says -EINVAL
             * for every failure, a transient one included, and reading
             * that as "no CAW" put a CAW-capable shared LUN on the no-CAW
             * fallback (C1): refuse instead. */
            pr_err("CAW: %s did not answer for its Block Limits VPD page (%d) -- refusing rather than "
                   "assuming no atomic CAW\n",
                   bdev->bd_disk->disk_name, rc);
            kfree(vpd);
            scsi_device_put(sdev);
            return -EIO;
        }
        kfree(vpd);
        scsi_device_put(sdev);
        return 0;
    }

    /* Not SCSI. NVMe has no exported probe; the disk-name prefix is the
     * best module-safe heuristic, and the NVMe CAW backend is a stub
     * that always returns -EOPNOTSUPP.
     *
     * max_caw_blocks therefore stays 0, and that is the whole point:
     * this field means "how much can we ATOMICALLY SWAP", not "what
     * might the hardware be capable of one day". It used to report the
     * kernel's atomic-write unit here as a purely informational ceiling,
     * but nothing downstream treats it as informational --
     * cetrafs_sb_caw_available() reads exactly this field to decide
     * whether the volume has cross-node atomicity at all. A nonzero
     * value from a device whose backend cannot execute a single CAW
     * meant fs.c's mount gate was SKIPPED (it believed the volume was
     * safe for multiple nodes) while every compare-and-swap failed
     * -EOPNOTSUPP. The awu is logged instead, where it informs without
     * deciding anything. */
    if (!strncmp(bdev->bd_disk->disk_name, "nvme", 4)) {
        /* queue_atomic_write_unit_max_bytes(), not the bdev_ wrapper
         * of the same value: the wrapper is new (absent on 7.0, which
         * is a deployment kernel), while this spelling exists on every
         * version this module is built against. It feeds a log line on
         * a path that already reports no atomic CAS, so a version shim
         * for it would be pure cost. */
        unsigned int awu = (unsigned int) queue_atomic_write_unit_max_bytes(bdev_get_queue(bdev));

        out->klass = CETRAFS_CAW_NVME;
        out->max_caw_blocks = 0;
        pr_info(
            "CAW: %s is NVMe (atomic write unit %u bytes) -- no module-callable fused "
            "compare+write exists, so this volume has no atomic CAS\n",
            bdev->bd_disk->disk_name, awu);
        return 0;
    }

    out->klass = CETRAFS_CAW_NONE;
    return 0;
}

/*
 * Atomic compare-and-write: if the 'nblocks' logical blocks at 'lba'
 * currently equal 'compare', overwrite them with 'write_data'. Buffers
 * are each nblocks * logical_block_size bytes. Returns:
 *   0           success (compared equal, write applied)
 *   -EBUSY      MISCOMPARE -- on-disk content differs; caller re-reads + retries
 *   -EOPNOTSUPP no atomic-CAW backend for this device (or nblocks too big)
 *   -E*         transport/alloc failure
 *
 * Resolves the transport per call (cheap -- no I/O) but does NOT re-probe
 * the max length; a caller that cares must gate nblocks against a cached
 * cetrafs_caw_discover() result (the device will also reject an
 * over-length request on its own).
 */
int cetrafs_caw(struct block_device *bdev, u64 lba, unsigned int nblocks, const void *compare, const void *write_data,
                bool killable)
{
    struct scsi_device *sdev;
    unsigned int lbs;

    if (!bdev || !bdev->bd_disk || !compare || !write_data)
        return -EINVAL;
    if (nblocks == 0)
        return -EINVAL;

    if (cetrafs_caw_late.compare) /* test knobs: a held command lands at the latest here */
        cetrafs_caw_land_held(bdev);
    if ((cetrafs_caw_timeout_late_once || cetrafs_caw_timeout_late_preread_once) && bdev_logical_block_size(bdev)) {
        size_t half = (size_t) nblocks * bdev_logical_block_size(bdev);

        cetrafs_caw_late.before_read = cetrafs_caw_timeout_late_preread_once;
        cetrafs_caw_timeout_late_once = false;
        cetrafs_caw_timeout_late_preread_once = false;
        cetrafs_caw_late.compare = kmemdup(compare, half, GFP_KERNEL);
        cetrafs_caw_late.write_data = kmemdup(write_data, half, GFP_KERNEL);
        if (!cetrafs_caw_late.compare || !cetrafs_caw_late.write_data) {
            kfree(cetrafs_caw_late.compare);
            kfree(cetrafs_caw_late.write_data);
            cetrafs_caw_late.compare = NULL;
            cetrafs_caw_late.write_data = NULL;
        }
        cetrafs_caw_late.lba = lba;
        cetrafs_caw_late.nblocks = nblocks;
        pr_warn("CAW lba=%llu: TEST caw_timeout_late_once -- held back, reporting a timeout\n",
                (unsigned long long) lba);
        return -ETIMEDOUT;
    }
    if (cetrafs_caw_timeout_lost_once) {
        /* Test-only: never issued, reported as timed out. */
        cetrafs_caw_timeout_lost_once = false;
        pr_warn("CAW lba=%llu: TEST caw_timeout_lost_once -- not issued, reporting a timeout\n",
                (unsigned long long) lba);
        return -ETIMEDOUT;
    }
    /* NUMBER OF LOGICAL BLOCKS is one byte of the CDB. Casting a larger
     * count into it would silently truncate -- 256 blocks becoming 0,
     * i.e. "transfer nothing", against a data-out buffer sized for 256.
     * The contract above already says an over-long request is refused;
     * this is what makes that true. (Every caller passes 1 today, so
     * this is a trap being closed, not a bug being fixed.) */
    if (nblocks > 255)
        return -EOPNOTSUPP;

    lbs = bdev_logical_block_size(bdev);

    sdev = cetrafs_caw_get_sdev(bdev);
    if (sdev) {
        int ret = cetrafs_caw_scsi(sdev, lba, nblocks, compare, write_data, lbs);

        scsi_device_put(sdev);
        if (ret == -EAGAIN)
            ret = -EIO; /* not executed; one path, nothing to rotate to */
        if (ret == 0 && cetrafs_caw_timeout_landed_once) {
            /* Test-only: it DID execute; the caller is told it timed
             * out. The dangerous half of the ambiguity. */
            cetrafs_caw_timeout_landed_once = false;
            pr_warn("CAW lba=%llu: TEST caw_timeout_landed_once -- executed, reporting a timeout anyway\n",
                    (unsigned long long) lba);
            return -ETIMEDOUT;
        }
        return ret;
    }

    /*
     * Not SCSI itself: a device-mapper node, i.e. the multipath case.
     * Issue over a path underneath (dmpath.c), and on a path failure
     * drop that path -- never on -EBUSY, which is a MISCOMPARE and a
     * legitimate lost race. A single path failure must not surface as a
     * failed claim: heartbeat renewal is itself a compare-and-swap, so
     * a path that stays broken would get this node declared dead and
     * fenced by its peers.
     *
     * What it must NOT do is re-issue a command whose outcome is
     * UNKNOWN (-ETIMEDOUT). If the first one landed, the second
     * MISCOMPAREs, the layer above reads that as a lost race, re-reads
     * and runs the mutator again -- and a mutator that adds a delta
     * rather than writing an absolute value then applies it TWICE:
     * cetrafs_zg_delta_mutate(), cetrafs_zg_pool_mutate(),
     * cetrafs_pf_append_mutate(), cetrafs_bg_count_mutate()'s delta
     * arm. So an unknown outcome marks the path failed and is handed up
     * to cetrafs_cas_region_seeded_impl(), which re-reads the region
     * and tells the cases apart before deciding to retry.
     *
     * A refusal the target says was NOT executed is a different thing,
     * and must stay one. A refusal of this path (-EAGAIN: a standby
     * port, a busy one) is re-issued here, on the next path -- the same
     * compare image, nothing to double -- a bounded number of times,
     * and ends as a definite -EIO. A refusal of the LU itself (-EIO:
     * reservation conflict, data protect, an illegal CDB) is no path's
     * fault and returns as it is, the path kept. Both used to be
     * rewritten to -ETIMEDOUT here, so an active/passive failover --
     * every host at once -- sent each swap into the undecided machinery
     * whose contended exits stop the mount, and 16 refusals in a row
     * stopped it with no peer at all (audit 2026-11-15 M-22, N-66).
     */
    {
        int ret = -EIO, tries;

        for (tries = 0; tries < CETRAFS_CAW_PATH_TRIES; tries++) {
            sdev = cetrafs_dmpath_sdev(bdev, killable);
            if (IS_ERR(sdev))
                return PTR_ERR(sdev); /* -EINTR: interrupted waiting for a path, nothing issued */
            if (!sdev) {
                /* A dm node this mount found CAW on, with no path to
                 * issue over right now: a transport failure, nothing
                 * issued. It returned -EOPNOTSUPP -- "this device has
                 * no CAW" -- which every caller passed up as such, and
                 * creat(2) reported "Operation not supported" for a
                 * path outage (C6). A node that is not dm falls through
                 * to the backends below. */
                if (strncmp(bdev->bd_disk->disk_name, "dm-", 3))
                    break;
                pr_warn_ratelimited("CAW lba=%llu: no path of %s to issue it over\n", (unsigned long long) lba,
                                    bdev->bd_disk->disk_name);
                return -EIO;
            }
            if (cetrafs_caw_fail_path_once) { /* test knob, see its MODULE_PARM_DESC */
                cetrafs_caw_fail_path_once = false;
                ret = -ETIMEDOUT;
            } else {
                ret = cetrafs_caw_scsi(sdev, lba, nblocks, compare, write_data, lbs);
                if (ret == 0 && cetrafs_caw_timeout_landed_once) {
                    cetrafs_caw_timeout_landed_once = false;
                    pr_warn("CAW lba=%llu: TEST caw_timeout_landed_once -- executed, reporting a timeout anyway\n",
                            (unsigned long long) lba);
                    ret = -ETIMEDOUT;
                }
            }
            if ((ret == -EAGAIN || ret == -EIO) && READ_ONCE(cetrafs_caw_definite_as_unknown))
                ret = -ETIMEDOUT; /* TEST ONLY: the old rewrite */
            if (ret == -EAGAIN) {
                cetrafs_dmpath_failed(bdev, sdev);
                scsi_device_put(sdev);
                ret = -EIO; /* if no path takes it: definite, not executed */
                continue;
            }
            if (ret == -ETIMEDOUT)
                cetrafs_dmpath_failed(bdev, sdev);
            scsi_device_put(sdev);
            return ret;
        }
        if (tries)
            return ret;
    }

    if (!strncmp(bdev->bd_disk->disk_name, "nvme", 4))
        return cetrafs_caw_nvme(bdev, lba, nblocks, compare, write_data, lbs);

    return -EOPNOTSUPP;
}

/* ---- record-level atomic compare-and-swap ---------------------------
 *
 * The bridge between the raw CAW primitive above and the filesystem's
 * on-disk records: read the record's CAS region fresh, let the caller
 * mutate a copy, atomically swap it in, and retry the whole cycle if
 * another node changed the region first. It replaced the old "take the
 * device-wide PR mutex, read-decide-write, release" shape of every claim
 * -- same correctness, no device-wide serialization, one round trip.
 *
 * The CAS region is the FIRST LOGICAL BLOCK of the given filesystem
 * block: 512 bytes on a 512-logical device (the hot sector --
 * CETRAFS_HOT_SECTOR, see cetrafs.h), or the whole 4096-byte block on a
 * 4Kn device. Either way it wholly contains the record and the checksum
 * covering it, which is what makes it self-validating and swappable on
 * its own.
 *
 * On a device with no atomic CAW, this degrades to exactly the old
 * behavior -- cluster mutex around a fresh read-modify-write -- so a
 * caller can be migrated to this helper unconditionally and still work
 * on PR-only hardware (and on the loop-device test harness).
 */
#define CETRAFS_CAS_RETRIES 16

/* Any dirty cached buffer for this block must reach the device before a
 * CAW: the compare image comes from the DEVICE, so a pending write would
 * both make the compare stale (permanent MISCOMPARE) and, worse, later
 * write back over the swap we just did. */
static int cetrafs_cas_flush_block(struct super_block *sb, u64 fs_lba)
{
    struct buffer_head *bh = sb_find_get_block(sb, fs_lba);
    int ret = 0;

    if (!bh)
        return 0;
    /* A failed flush discards the pending write (clean, !uptodate): the
     * CAS must not go ahead as if it had landed. A HELD bitmap image
     * (ioutil.c) is a pending write just the same. */
    if (buffer_dirty(bh) || buffer_cetra_held(bh))
        ret = cetrafs_sync_buffer(sb, bh);
    brelse(bh);
    return ret;
}

/* Size of one CAS region: the device's atomic unit where there is one,
 * else the format's hot-sector rule. A filesystem block holds
 * CETRAFS_BLOCK_SIZE / this many regions, indexed from 0. */
/*
 * Test-only: pretend the CAS region is this wide.
 *
 * The region is the device's atomic unit, so on a 4Kn device it is the
 * whole 4096-byte record block and there is exactly ONE region -- the
 * file-domain sector is no region of its own, it is a slice inside
 * region 0. Every path derives its region count from
 * cetrafs_cas_region_size() and follows; the one that did not was
 * cetrafs_cas_record_fd_seeded(), whose region index was the constant 1.
 * Past the end of the block, so the bounds check refused it and every
 * file-domain publish -- fsync, fdatasync, writeback, close -- returned
 * -EINVAL.
 *
 * None of our own hardware can show that. The test LUN is 512-byte
 * logical, and a loop device has no CAW at all, so the region is 512
 * either way and region 1 always exists. The bug was reported from a
 * 4Kn target and is invisible to the whole gate without this knob.
 *
 * Honoured ONLY where there is no CAW. With a real CAW the region size
 * is a property of the device: the swap is issued as one logical block
 * at dev_lba, so lying about its width would send a 4096-byte image to
 * a 512-byte swap. Without CAW the width is purely a software notion --
 * which buffer sizes, which offset, which bounds -- and that is exactly
 * the part under test.
 */
static unsigned int cetrafs_cas_region_force;
cetrafs_test_param(cas_region_force, cetrafs_cas_region_force, uint, 0644);
MODULE_PARM_DESC(cas_region_force,
                 "TEST ONLY: CAS region width to assume on a device with no CAW (power of two, "
                 "512..4096; 0 = the format's hot-sector rule). Reaches the wide-region paths a "
                 "4Kn device takes.");

unsigned int cetrafs_cas_region_size(struct super_block *sb)
{
    const struct cetrafs_caw_info *caw = cetrafs_sb_caw(sb);
    unsigned int forced = READ_ONCE(cetrafs_cas_region_force);

    if (cetrafs_sb_caw_available(sb))
        return caw->logical_block_size;
    /* A width that is not a power of two, or does not divide the block,
     * would leave a partial region at the end of every block -- refuse
     * it rather than model something no device can be. */
    if (forced >= CETRAFS_HOT_SECTOR && forced <= CETRAFS_BLOCK_SIZE && is_power_of_2(forced))
        return forced;
    return CETRAFS_HOT_SECTOR;
}

/*
 * CAS region 'region_idx' of filesystem block 'fs_lba'. Records live in
 * region 0 (the hot sector); bitmaps use every region of their blocks,
 * which is why this is indexed rather than fixed at the start.
 */

/*
 * G-6 (audit 2026-11-15): every CAS-managed sector carries a stamp that
 * every swap moves to a value no swap ever wrote before
 * (cetrafs_cas_stamp_next()). So a region never returns to an earlier
 * image -- a late command that compared against one can never land
 * after anything else did (the late-CAW ABA) -- and a swap whose outcome
 * the device never reported is decided by the stamp a re-read finds:
 * one of ours, the image it compared (not yet), or a peer's first swap
 * from that image (ours can never land). Set HERE, after the mutator and
 * its "no change" verdict, for every caller; the structure's own
 * checksum is then re-stamped over it, so no mutator and no reader
 * changes.
 *
 * Which structure a region is comes from its address, as the superblock
 * and the layout give it. A swap on an address none names is said, once,
 * loudly: every CAS writer must move the stamp, and a missed kind is a
 * writer that does not.
 */
enum cetrafs_stamp_kind {
    CETRAFS_SK_NONE,
    CETRAFS_SK_SB,
    CETRAFS_SK_ZG,
    CETRAFS_SK_BG,
    CETRAFS_SK_NODE,
    CETRAFS_SK_JFLAG,
    CETRAFS_SK_SEG,
    CETRAFS_SK_INODE,
    CETRAFS_SK_IBMAP,
    CETRAFS_SK_PF,
};

/* TEST ONLY: inode records are not recognised as a stamped kind -- a
 * CAS writer the classifier misses (tests/kernel/cas_stamp.sh). */
static bool cetrafs_cas_stamp_forget_records;
cetrafs_test_param(cas_stamp_forget_records, cetrafs_cas_stamp_forget_records, bool, 0644);
MODULE_PARM_DESC(cas_stamp_forget_records, "TEST ONLY: the G-6 stamp classifier does not know inode records");

static enum cetrafs_stamp_kind cetrafs_cas_stamp_kind(struct super_block *sb, u64 lba)
{
    const cetrafs_superblock_t *r = cetrafs_sb_raw(sb);
    const struct cetrafs_iseg *is;
    u32 nis, i;
    int role;
    u64 jstart, jblocks;
#define CETRAFS_IN(start, n) (lba >= (u64) (start) && lba - (u64) (start) < (u64) (n))

    if (!r)
        return CETRAFS_SK_NONE;
    if (unlikely(READ_ONCE(cetrafs_cas_stamp_forget_records)) && cetrafs_lba_ino(sb, lba))
        return CETRAFS_SK_NONE; /* TEST ONLY: see the parameter */
    if (lba == 0)
        return CETRAFS_SK_SB;
    if (CETRAFS_IN(le64_to_cpu(r->zg_table_start), le32_to_cpu(r->zone_group_count)))
        return CETRAFS_SK_ZG;
    if (CETRAFS_IN(le64_to_cpu(r->bg_table_start), le64_to_cpu(r->bg_table_first_count)))
        return CETRAFS_SK_BG;
    if (cetrafs_lba_in_ibmap(sb, lba))
        return CETRAFS_SK_IBMAP;
    if (cetrafs_lba_ino(sb, lba))
        return CETRAFS_SK_INODE;
    if (CETRAFS_IN(le64_to_cpu(r->node_table_start), le64_to_cpu(r->node_table_blocks)))
        return CETRAFS_SK_NODE;
    jstart = le64_to_cpu(r->node_journal_start);
    jblocks = le32_to_cpu(r->node_journal_blocks);
    if (jblocks && CETRAFS_IN(jstart, jblocks * le32_to_cpu(r->node_table_count)))
        return (lba - jstart) % jblocks == 0 ? CETRAFS_SK_JFLAG : CETRAFS_SK_NONE;
    if (CETRAFS_IN(le64_to_cpu(r->pending_free_start),
                   (u64) le32_to_cpu(r->pending_free_blocks_per_zg) * le32_to_cpu(r->zone_group_count)))
        return CETRAFS_SK_PF;
    /* Appended Block Group table segments: [header, last descriptor]. */
    role = cetrafs_sb_bg_seg_role(sb, lba);
    if (role)
        return role == 1 ? CETRAFS_SK_SEG : CETRAFS_SK_BG;
    /* Appended inode table segments: a header block before the bitmap
     * (the first segment is the superblock's, with none). */
    is = cetrafs_sb_isegs(sb, &nis);
    for (i = 1; is && i < nis; i++)
        if (lba + 1 == is[i].bmap)
            return CETRAFS_SK_SEG;
    return CETRAFS_SK_NONE;
#undef CETRAFS_IN
}

/* Where the region's primary stamp is, from the region's own start; -1:
 * the region holds none (the other sector of a 512-byte region pair). */
static int cetrafs_cas_stamp_off(enum cetrafs_stamp_kind k, unsigned int region_idx, unsigned int region)
{
    unsigned int base = region_idx * region; /* the region's offset in its block */

    switch (k) {
    case CETRAFS_SK_INODE:
        if (base == 0)
            return offsetof(cetrafs_inode_t, ns_cas_stamp);
        return base == CETRAFS_INODE_FD_OFF ? (int) CETRAFS_INODE_FD_STAMP_OFF : -1;
    case CETRAFS_SK_IBMAP:
        return CETRAFS_BMAP_SECTOR - CETRAFS_BMAP_TRAILER; /* this region's first sector's trailer */
    case CETRAFS_SK_PF:
        return CETRAFS_HOT_SECTOR - sizeof(cetrafs_pf_trailer_t) + offsetof(cetrafs_pf_trailer_t, stamp);
    default:
        break;
    }
    if (base)
        return -1; /* every other structure's swapped sector is its block's first */
    switch (k) {
    case CETRAFS_SK_SB:
        return offsetof(cetrafs_superblock_t, cas_stamp);
    case CETRAFS_SK_ZG:
        return offsetof(cetrafs_zone_group_t, cas_stamp);
    case CETRAFS_SK_BG:
        return offsetof(cetrafs_block_group_t, cas_stamp);
    case CETRAFS_SK_NODE:
        return offsetof(cetrafs_node_entry_t, cas_stamp);
    case CETRAFS_SK_JFLAG:
        return offsetof(cetrafs_node_journal_hdr_t, cas_stamp);
    case CETRAFS_SK_SEG:
        return offsetof(cetrafs_seg_hdr_t, cas_stamp);
    default:
        return -1;
    }
}

static u64 cetrafs_cas_stamp_get(const u8 *img, int soff)
{
    return soff < 0 ? 0 : get_unaligned_le64(img + soff);
}

/* Is a Node Registry row, its stamp aside, all zero (a FREE row)? */
static bool cetrafs_cas_row_blank(const u8 *img)
{
    unsigned int so = offsetof(cetrafs_node_entry_t, cas_stamp);

    return !memchr_inv(img, 0, so) && !memchr_inv(img + so + 8, 0, sizeof(cetrafs_node_entry_t) - so - 8);
}

/* Stamp 'img' (the region) with 'stamp' wherever the region holds one,
 * and re-stamp the checksum each covers. */
static void cetrafs_cas_stamp_set(enum cetrafs_stamp_kind k, u8 *img, unsigned int region_idx, unsigned int region,
                                  u64 stamp)
{
    unsigned int base = region_idx * region, s;

    switch (k) {
    case CETRAFS_SK_SB: {
        cetrafs_superblock_t *sbr = (cetrafs_superblock_t *) img;

        put_unaligned_le64(stamp, &sbr->cas_stamp);
        sbr->checksum = cpu_to_le64(0);
        sbr->checksum = cpu_to_le64((u64) ~crc32c(~0U, sbr, sizeof(*sbr)));
        break;
    }
    case CETRAFS_SK_ZG:
        put_unaligned_le64(stamp, img + offsetof(cetrafs_zone_group_t, cas_stamp));
        put_unaligned_le64(cetrafs_zg_hot_image_crc(img), img + offsetof(cetrafs_zone_group_t, hot_checksum));
        break;
    case CETRAFS_SK_BG:
        put_unaligned_le64(stamp, img + offsetof(cetrafs_block_group_t, cas_stamp));
        put_unaligned_le64(cetrafs_bg_image_crc(img, region), img + offsetof(cetrafs_block_group_t, checksum));
        break;
    case CETRAFS_SK_NODE:
        /* A FREE row stays checksum-less, as mkfs leaves it; only its
         * stamp moves (cetrafs_node_entry_blank() looks past it). */
        put_unaligned_le64(stamp, img + offsetof(cetrafs_node_entry_t, cas_stamp));
        if (!cetrafs_cas_row_blank(img))
            put_unaligned_le64(cetrafs_node_image_crc(img), img + offsetof(cetrafs_node_entry_t, checksum));
        break;
    case CETRAFS_SK_JFLAG:
        put_unaligned_le64(stamp, img + offsetof(cetrafs_node_journal_hdr_t, cas_stamp));
        break;
    case CETRAFS_SK_SEG:
        put_unaligned_le64(stamp, img + offsetof(cetrafs_seg_hdr_t, cas_stamp));
        put_unaligned_le64(cetrafs_seg_crc_prefix(img, region), img + offsetof(cetrafs_seg_hdr_t, checksum));
        break;
    case CETRAFS_SK_INODE:
        /* Both sectors the region holds; the file sector's stamp is in
         * the tail its CRC takes as zeros, so only the namespace
         * sector's CRC moves. */
        if (base == 0) {
            put_unaligned_le64(stamp, img + offsetof(cetrafs_inode_t, ns_cas_stamp));
            put_unaligned_le64(cetrafs_inode_ns_image_crc(img), img + offsetof(cetrafs_inode_t, ns_checksum));
        }
        if (base <= CETRAFS_INODE_FD_OFF && base + region > CETRAFS_INODE_FD_OFF)
            put_unaligned_le64(stamp, img + (CETRAFS_INODE_FD_OFF - base) + CETRAFS_INODE_FD_STAMP_OFF);
        break;
    case CETRAFS_SK_IBMAP:
        for (s = 0; s < region / CETRAFS_BMAP_SECTOR; s++) {
            cetrafs_bmap_trailer_t *t = cetrafs_bmap_trailer(img, s);

            put_unaligned_le64(stamp, &t->stamp);
            t->crc = cpu_to_le32(cetrafs_bmap_sector_crc(img + s * CETRAFS_BMAP_SECTOR));
        }
        break;
    case CETRAFS_SK_PF:
        for (s = 0; s < region / CETRAFS_HOT_SECTOR; s++)
            put_unaligned_le64(stamp, img + (s + 1) * CETRAFS_HOT_SECTOR - sizeof(cetrafs_pf_trailer_t) +
                                          offsetof(cetrafs_pf_trailer_t, stamp));
        break;
    default:
        break;
    }
}

/* TEST ONLY: swaps leave every G-6 stamp where it was, as before the
 * stamp (tests/kernel/cas_stamp_aba.sh). */
static bool cetrafs_cas_stamp_off_knob;
cetrafs_test_param(cas_stamp_off, cetrafs_cas_stamp_off_knob, bool, 0644);
MODULE_PARM_DESC(cas_stamp_off, "TEST ONLY: CAS swaps do not move the G-6 per-sector stamp");

static atomic64_t cetrafs_cas_unstamped = ATOMIC64_INIT(0);
static atomic64_t cetrafs_cas_stamp_decided = ATOMIC64_INIT(0);

u64 cetrafs_cas_stamp_decided_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_stamp_decided);
}

u64 cetrafs_cas_unstamped_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_unstamped);
}

/* Move a changed post-image's stamp past the pre-image's. Returns the
 * stamp written (0: none -- the region has no stamp). */
static u64 cetrafs_cas_stamp_bump(struct super_block *sb, u64 fs_lba, enum cetrafs_stamp_kind k, const u8 *old,
                                  u8 *new, unsigned int region_idx, unsigned int region)
{
    int soff = cetrafs_cas_stamp_off(k, region_idx, region);
    u64 stamp;

    if (k == CETRAFS_SK_NONE) {
        atomic64_inc(&cetrafs_cas_unstamped);
        if (READ_ONCE(cetrafs_cas_stamp_forget_records))
            pr_err_ratelimited("cetrafs: a CAS on block %llu (%s) has no G-6 stamp kind (test injection)\n",
                               (unsigned long long) fs_lba, cetrafs_block_role(sb, fs_lba));
        else
            WARN_ONCE(1, "cetrafs: a CAS on block %llu (%s) has no G-6 stamp kind\n", (unsigned long long) fs_lba,
                      cetrafs_block_role(sb, fs_lba));
        return 0;
    }
    if (soff < 0 || READ_ONCE(cetrafs_cas_stamp_off_knob))
        return 0;
    stamp = cetrafs_cas_stamp_next(sb, cetrafs_cas_stamp_get(old, soff));
    cetrafs_cas_stamp_set(k, new, region_idx, region, stamp);
    return stamp;
}

enum cetrafs_stamp_verdict {
    CETRAFS_SV_UNDECIDABLE, /* two or more swaps since: ours may be under them */
    CETRAFS_SV_LANDED,      /* one of this call's swaps is on the device */
    CETRAFS_SV_NOT_YET,     /* the image the swaps compared: none landed yet */
    CETRAFS_SV_NEVER,       /* a peer's first swap from that image won: none of ours ever lands */
};

/*
 * Judge a re-read after a swap whose outcome is unknown, by stamp: 'dev'
 * on the device, 'pre' in the image every undecided swap of this call
 * compared, 'issued' the stamps those swaps wrote. A stamp is unique
 * per swap, so "it is one of ours" and "it is the pre-image's" are exact
 * -- not "the bytes match", which a peer can reproduce. One more swap
 * than pre and none of ours: a peer's swap from the same image won, and
 * ours, comparing that image, can never land now.
 */
static enum cetrafs_stamp_verdict cetrafs_cas_stamp_judge(u64 dev, u64 pre, const u64 *issued, unsigned int n,
                                                          bool overflow)
{
    unsigned int i;
    u32 next = (u32) pre + 1;

    if (!dev || !pre)
        return CETRAFS_SV_UNDECIDABLE; /* not a stamped region */
    for (i = 0; i < n; i++)
        if (issued[i] == dev)
            return CETRAFS_SV_LANDED;
    if (dev == pre)
        return CETRAFS_SV_NOT_YET;
    /* More swaps of ours than were remembered: the stamp on the device
     * may be one of the forgotten -- never read it as a peer's. */
    if (overflow)
        return CETRAFS_SV_UNDECIDABLE;
    if ((u32) dev == (next ? next : 1))
        return CETRAFS_SV_NEVER;
    return CETRAFS_SV_UNDECIDABLE;
}

/*
 * The no-CAW half of cetrafs_cas_region_seeded(), split out so its
 * several exit paths cannot forget to drop the serialising mutex its
 * caller holds across this whole call. Everything here assumes that
 * mutex is held.
 */
static int cetrafs_cas_nocaw(struct super_block *sb,
                             u64 fs_lba,
                             unsigned int off,
                             unsigned int region,
                             u8 *old,
                             u8 *new,
                             cetrafs_cas_fn mutate,
                             void *priv,
                             enum cetrafs_stamp_kind sk,
                             unsigned int region_idx)
{
    struct buffer_head *bh = cetrafs_bread_uncached_retry(sb, fs_lba);
    int ret;

    if (!bh)
        return -EIO;
    cetrafs_bh_copy_stable_at(bh, off, old, region);
    memcpy(new, old, region);
    brelse(bh);

    ret = mutate(new, region, priv);
    if (ret)
        /* >0 == "no change needed", flattened to success. TRAP: a caller
         * for whom "nothing to do" means LOST AN ARBITRATION (exactly one
         * winner may act -- the evict arbiter, the drain's consume) must
         * carry that verdict in the mutate's ctx, never the return value:
         * this flattening told every evict it had won the inode-number
         * free and the losers double-freed the blocks. See
         * cetrafs_bmap_cas_ctx.cleared and pf_drain's ctx->consumed. */
        return (ret > 0) ? 0 : ret;
    if (!memcmp(old, new, region))
        return 0;
    cetrafs_cas_stamp_bump(sb, fs_lba, sk, old, new, region_idx, region);

    bh = cetrafs_bread_retry(sb, fs_lba);
    if (!bh)
        return -EIO;
    /* The buffer-lock update protocol, same as every other in-place
     * modification in this module: a forced-fresh reader in another
     * thread takes this lock too, so without it one can clear uptodate
     * and re-read the block straight over these bytes. */
    cetrafs_bh_begin_update(bh);
    memcpy(bh->b_data + off, new, region);
    cetrafs_bh_end_update(sb, bh);
    /* The swap is only done if it reached the device: a failed sync
     * leaves the buffer clean and !uptodate, the new image is gone, and
     * reporting success there told a namespace-lock acquire, an inode
     * bitmap claim or a record publish that it had happened. */
    ret = cetrafs_sync_buffer(sb, bh);
    brelse(bh);
    return ret;
}

/*
 * As cetrafs_cas_region(), plus an optional 'seed': the caller's own,
 * already-fresh image of the region, used as the FIRST attempt's compare
 * image instead of reading the block again.
 *
 * Nearly every caller reads the record fresh, decides from it, and then
 * calls the CAS -- which read the very same block a second time, so each
 * compare-and-swap cost two device round trips where one would do. On a
 * high-latency LUN that is the difference between ~24 and ~18 round
 * trips for a single file operation.
 *
 * A seed that turns out to be stale costs nothing but one failed CAW:
 * MISCOMPARE drops straight into the ordinary retry loop below, which
 * re-reads forced-fresh exactly as before. So this can never trade
 * correctness for speed -- the worst case is the speed we already had.
 *
 * The seed must be the full region image, not just the record: records
 * are written with their block zero-filled past the struct, and every
 * CAS mutator zero-fills the region tail for the same reason, so
 * {record bytes, then zeros} is byte-exact. If that ever stops being
 * true the CAW simply miscompares and we fall back to a re-read.
 */
/*
 * A mutator refused its image: the sector on the device fails its own
 * checksum. Every mutator that returns -EUCLEAN means exactly that, and
 * the loop has already re-read through any tear (a miscompare re-runs
 * the mutator), so the bytes really are wrong: damaged metadata found
 * on read, kind 2 (docs/internal/ERRORS.md). It used to be logged and
 * nothing else -- counted nowhere, no write refused, corruption=stop
 * not consulted. An inode record marks that inode; anything else (a
 * node row, a Zone Group, a Block Group descriptor) the volume.
 */
static void cetrafs_cas_refused_damage(struct super_block *sb, u64 fs_lba)
{
    cetrafs_sb_corrupt(sb, cetrafs_lba_ino(sb, fs_lba));
}

/* Seeds a mutator refused (a torn or edited caller copy), each costing
 * a fresh read. Nonzero means some caller seeded with a copy that was not
 * the device's image -- tests/kernel/bg_seed_torn.sh. */
static atomic64_t cetrafs_cas_seed_refused = ATOMIC64_INIT(0);

u64 cetrafs_cas_seed_refused_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_seed_refused);
}

/* Seeded verdicts other than EUCLEAN that were asked again of a fresh
 * read (see the loop): the seed disagreed with what it decided. */
static atomic64_t cetrafs_cas_seed_reverdicts = ATOMIC64_INIT(0);

u64 cetrafs_cas_seed_reverdict_count(void)
{
    return (u64) atomic64_read(&cetrafs_cas_seed_reverdicts);
}

/*
 * After a swap is known to be on the device: make this node's cached
 * copy agree with it. The swap's bytes go into any uptodate buffer, dirty
 * or not (cetrafs_cache_region_after_cas()); a block holding OTHER
 * regions, which peers swap independently, is then dropped as well --
 * when it can be.
 *
 * The non-sole case used to drop only, with cetrafs_invalidate_block(),
 * which rightly keeps a DIRTY buffer: that buffer still held the
 * pre-image of the region just swapped, and its write-back put it back
 * over the swap -- the swap undone, on the device, for every node
 * (audit 2026-11-11 C2, the CAS selftest's phase 2e,
 * tests/kernel/cas_dirty_copy_patched.sh).
 */
static void cetrafs_cas_publish_cache(struct super_block *sb, u64 fs_lba, unsigned int off, const void *src,
                                      unsigned int len, bool sole_region)
{
    cetrafs_cache_region_after_cas(sb, fs_lba, off, src, len);
    if (!sole_region)
        cetrafs_invalidate_block(sb, fs_lba);
}

/* TEST ONLY: this node dirties its cached copy of the next swapped block
 * after the swap's own flush -- a local writer landing between the
 * flush and the swap (the selftest's phase 2e). */
static bool cetrafs_cas_dirty_after_flush_once;
cetrafs_test_param(cas_dirty_after_flush_once, cetrafs_cas_dirty_after_flush_once, bool, 0644);
MODULE_PARM_DESC(cas_dirty_after_flush_once, "TEST ONLY: dirty the cached block after the next swap's flush");

static void cetrafs_cas_test_dirty(struct super_block *sb, u64 fs_lba)
{
    struct buffer_head *bh = sb_find_get_block(sb, fs_lba);

    if (!bh)
        return;
    if (buffer_uptodate(bh)) {
        cetrafs_bh_begin_update(bh); /* no change: only dirtied, by the protocol */
        cetrafs_bh_end_update(sb, bh);
    }
    brelse(bh);
}

/* TEST ONLY: the next real-CAW swap on this inode's record waits
 * cas_stall_ms between its read and its compare-and-write, where a
 * peer's change to the sector makes it miscompare (ctest
 * cas-image-check). One-shot. */
static unsigned long long cetrafs_cas_stall_ino;
cetrafs_test_param(cas_stall_ino, cetrafs_cas_stall_ino, ullong, 0644);
MODULE_PARM_DESC(cas_stall_ino, "TEST ONLY: the next CAW on this inode's record pauses before its swap");
static unsigned int cetrafs_cas_stall_ms = 3000;
cetrafs_test_param(cas_stall_ms, cetrafs_cas_stall_ms, uint, 0644);
MODULE_PARM_DESC(cas_stall_ms, "TEST ONLY: how long cas_stall_ino pauses (ms)");

#define CETRAFS_CAS_ISSUED_MAX 32

static int cetrafs_cas_region_seeded_impl(struct super_block *sb,
                                          u64 fs_lba,
                                          unsigned int region_idx,
                                          const void *seed,
                                          unsigned int seed_len,
                                          cetrafs_cas_fn mutate,
                                          void *priv,
                                          bool sole_region,
                                          bool killable,
                                          bool *image_only)
{
    const struct cetrafs_caw_info *caw = cetrafs_sb_caw(sb);
    bool have_caw = cetrafs_sb_caw_available(sb);
    unsigned int region = cetrafs_cas_region_size(sb);
    unsigned int off = region_idx * region;
    u64 dev_lba = have_caw ? fs_lba * (CETRAFS_BLOCK_SIZE / caw->logical_block_size) + region_idx : 0;
    u8 *old, *new;
    u8 *unknown = NULL; /* a swap whose outcome was unknown: its post-image, then its pre-image */
    /* G-6: the region's kind, its primary stamp's offset, and the stamps
     * this call's swaps wrote since the image they compared. */
    enum cetrafs_stamp_kind sk = cetrafs_cas_stamp_kind(sb, fs_lba);
    int soff = cetrafs_cas_stamp_off(sk, region_idx, region);
    u64 issued[CETRAFS_CAS_ISSUED_MAX];
    unsigned int nissued = 0;
    bool issued_over = false; /* a swap went out unremembered: no NEVER verdict */
    bool undecided = false; /* 'unknown' holds a swap that may still land */
    bool seeded = false; /* this attempt's image is the caller's seed, not the device's */
    unsigned long undecided_until = 0;
    int attempt, ret, extra = 0, naps = 0;

    if (!mutate || off + region > CETRAFS_BLOCK_SIZE)
        return -EINVAL;
    /* A stopped mount writes nothing (docs/internal/ERRORS.md). The
     * callers' own gates come first; this is the one every claim,
     * release and publish shares, so an operation that passed its gate
     * just before the stop is caught here instead of on the device. */
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    cetrafs_cas_op_counted();

    /* An allocation under alloc_mutex or birth_rwsem outside a NOFS
     * scope can recurse through reclaim into an evict that waits on the
     * same lock (cetrafs_sb_alloc_lock()). Loud, so every suite that
     * gets here checks it. */
    WARN_ON_ONCE(cetrafs_sb_in_reclaim_lock(sb) && !(current->flags & PF_MEMALLOC_NOFS));

    /* NOFS, not only in a reclaim-locked scope: callers hold namespace
     * locks too, and reclaim can reach an evict that wants one (audit
     * 2026-11-14 N6). */
    old = kmalloc(region, GFP_NOFS);
    new = kmalloc(region, GFP_NOFS);
    /* Up front: allocated after a timeout, a failure returned -ENOMEM
     * for a swap that may still land (audit 2026-11-06 L12). */
    unknown = kmalloc(2 * region, GFP_NOFS);
    if (!old || !new || !unknown) {
        kfree(old);
        kfree(new);
        kfree(unknown);
        return -ENOMEM;
    }

    if (!have_caw) {
        /*
         * No atomic CAW on this device, so there is no cross-node
         * atomicity to be had -- and none is needed: fs.c's mount gate
         * only ever admits ONE node to such a volume.
         *
         * One node is not one thread, though, and that distinction cost
         * real corruption. This path is a plain read / decide / write,
         * so two LOCAL threads can both read the same region, both
         * decide against the same image, and both blind-write the whole
         * region back -- last writer wins and the other update is gone.
         * Measured on a loop device: 96 of 3200 concurrent increments
         * lost, and -- because the global inode bitmap allocates through
         * exactly this path -- 15 inode numbers handed to two different
         * files each across 2400 concurrent creates, which fsck sees as
         * "nlink=1 but 2 directory entries name it". Two unrelated files
         * sharing one inode record is as bad as it sounds.
         *
         * The device-wide SCSI PR mutex this replaced happened to cover
         * it: PR exclusion was same-node as well as cross-node (cm_excl).
         * Removing PR removed that half too, and nothing replaced it --
         * the comment on cetrafs_cas_stress() reasoned that every caller
         * was already serialised by some higher lock, which held for
         * lock.c and nslock.c but not for the inode bitmap, the ZG
         * record, the pending-free queue or the journal replay claim.
         *
         * So: one node-local mutex across read-decide-write, restoring
         * exactly the same-node exclusion PR used to provide. It is a
         * leaf (no CAS mutator takes any lock), and it never runs on
         * CAW-capable hardware, where the device does this for us and
         * serialising would throw away the whole point.
         *
         * The read is still forced-fresh and still retries: a NULL from
         * it usually means another thread cleared the uptodate bit
         * between the read completing and bh_read() re-checking it, not
         * a real I/O error (without the retry a plain create() failed
         * with EIO roughly once per 300).
         */
        if (!killable) {
            cetrafs_sb_cas_lock(sb);
        } else if (cetrafs_sb_cas_lock_killable(sb)) {
            ret = -EINTR; /* nothing read, nothing written */
            goto out;
        }
        ret = cetrafs_cas_nocaw(sb, fs_lba, off, region, old, new, mutate, priv, sk, region_idx);
        if (READ_ONCE(cetrafs_cas_nocaw_stall_ms))
            msleep(xchg(&cetrafs_cas_nocaw_stall_ms, 0)); /* once */
        cetrafs_sb_cas_unlock(sb);
        goto out;
    }

    for (attempt = 0; attempt < CETRAFS_CAS_RETRIES + extra; attempt++) {
        struct buffer_head *bh;

        /* Per attempt, not per call: a fence landing during sixteen
         * contended rounds must stop the next swap, not the next call's
         * (audit 2026-11-06 L12). */
        if (attempt && cetrafs_sb_is_fenced(sb)) {
            ret = -EIO;
            goto out;
        }

        /* The flush is NOT optional, even when seeding. A CAW compares
         * against what is physically on the DEVICE, and this block may
         * still have a dirty cached copy that has not reached it -- in
         * which case the device holds the OLD bytes while the caller's
         * seed, read through that same cache, holds the new ones. The
         * compare image is then wrong and every first attempt
         * miscompares. Measured: skipping it took an empty create from
         * 297 ms to 550 ms on the real LUN, because each operation now
         * paid a wasted CAW *plus* the re-read and CAW it was trying to
         * avoid. Only the READ is skippable. */
        /* PERF(8): not optional -- docs/PERFORMANCE.md */
        ret = cetrafs_cas_flush_block(sb, fs_lba);
        if (ret && undecided && cetrafs_cas_undecided_nap(sb, undecided_until, &naps)) {
            extra++;
            continue;
        }
        if (ret)
            goto out;
        if (unlikely(READ_ONCE(cetrafs_cas_dirty_after_flush_once)) && xchg(&cetrafs_cas_dirty_after_flush_once, false))
            cetrafs_cas_test_dirty(sb, fs_lba); /* TEST ONLY: a local writer, after the flush */

        if (attempt == 0 && seed && seed_len == region) {
            /* Trust the caller's image once. A stale one just fails the
             * CAW below and the next attempt reads fresh.
             *
             * ONLY a full-region seed. A shorter one used to be
             * zero-padded to the region, and on a 4Kn device the region
             * is the WHOLE record block -- both sectors -- while every
             * seeding caller has one sector in hand. The other sector
             * was therefore compared as zeros against a record that is
             * never zero: a guaranteed MISCOMPARE, so the optimisation
             * that exists to skip a read instead cost a wasted CAW
             * round trip and then did the read anyway. Falling straight
             * through to the read is strictly cheaper.
             */
            memcpy(old, seed, region);
            seeded = true;
        } else {
            seeded = false;
            if (cetrafs_caw_late.compare && cetrafs_caw_late.before_read)
                cetrafs_caw_land_held(sb->s_bdev); /* TEST ONLY */
            bh = cetrafs_bread_uncached_retry(sb, fs_lba); /* see the no-CAW path above */
            if (!bh && undecided && cetrafs_cas_undecided_nap(sb, undecided_until, &naps)) {
                extra++;
                continue;
            }
            if (!bh) {
                ret = -EIO;
                goto out;
            }
                    cetrafs_bh_copy_stable_at(bh, off, old, region);
            brelse(bh);
        }

        /*
         * After a swap whose outcome was unknown, this read is a verdict
         * too, not just a starting point. The command can land between
         * the re-read that found the pre-image and this one -- and then
         * this read IS its post-image. Running the mutator on it applies
         * the mutation a second time, and the CAW below even succeeds,
         * since its compare image is what the device holds: a delta
         * mutator (a ZG aggregate, a BG count, a pending-free append)
         * counted twice. So: our post-image means it landed; the
         * pre-image means it still has not; anything else is a peer
         * writing after a landing we cannot rule out -- the same verdict
         * the MISCOMPARE check below gives.
         */
        if (undecided) {
            if (!memcmp(old, unknown, region)) {
                pr_warn("CAS lba=%llu: the timed-out command landed late -- taking it as done\n",
                        (unsigned long long) fs_lba);
                cetrafs_cas_publish_cache(sb, fs_lba, off, unknown, region, sole_region);
                ret = 0;
                goto out;
            }
            if (memcmp(old, unknown + region, region)) {
                /* G-6: the stamp says which. */
                enum cetrafs_stamp_verdict sv = cetrafs_cas_stamp_judge(
                    cetrafs_cas_stamp_get(old, soff), cetrafs_cas_stamp_get(unknown + region, soff), issued, nissued, issued_over);

                if (sv == CETRAFS_SV_LANDED) {
                    pr_warn("CAS lba=%llu: a timed-out command landed late -- taking it as done (by its stamp)\n",
                            (unsigned long long) fs_lba);
                    cetrafs_cas_publish_cache(sb, fs_lba, off, old, region, sole_region);
                    ret = 0;
                    goto out;
                }
                if (sv != CETRAFS_SV_NEVER) {
                    cetrafs_sb_fatal(sb, "CAS lba=%llu: the region changed after a timed-out command -- cannot "
                                         "tell whether it landed",
                                     (unsigned long long) fs_lba);
                    ret = -EIO;
                    goto out;
                }
                /* A peer's swap won from the image ours compared: none
                 * of ours can land now. Decide afresh from this read. */
                atomic64_inc(&cetrafs_cas_stamp_decided);
                undecided = false;
                nissued = 0;
                issued_over = false;
            }
        }

        memcpy(new, old, region);
        ret = mutate(new, region, priv);
        /*
         * A seed is the caller's copy, and callers edit theirs: the
         * stale-lock reclaim clears the lock fields of its own copy so
         * the open sees the lock free, without restamping it. "A stale
         * seed just fails the CAW" held only while mutators ignored the
         * image's checksum; once they refuse one that fails it (EUCLEAN),
         * a seed must never be what they refuse -- that verdict is about
         * the DEVICE. Read it fresh and ask again (a two-node reclaim of
         * a dead node's lock was refused every time otherwise).
         */
        if (ret == -EUCLEAN && seeded) {
            atomic64_inc(&cetrafs_cas_seed_refused);
            continue;
        }
        /*
         * Every other verdict on a seed is about the caller's copy too.
         * A refusal ("a peer is reading it") or a "nothing to do" from
         * a copy read before the caller's own last swap is not the
         * device's answer: an open that cleared a dead node's reader bit
         * and then claimed with its earlier copy was refused ETXTBSY over
         * the very bit it had just cleared (ctest reader-reclaim). Only
         * the device's image may decide; read it and ask again.
         */
        if (ret && seeded) {
            atomic64_inc(&cetrafs_cas_seed_reverdicts);
            continue;
        }
        if (ret) {
            ret = (ret > 0) ? 0 : ret; /* >0 == "nothing to do", success --
                                        * same TRAP as the real-CAW path
                                        * above: arbitration verdicts go in
                                        * the mutate ctx, not here */
            goto out;
        }
        if (!memcmp(old, new, region)) {
            ret = 0; /* mutator made no change */
            goto out;
        }
        {
            u64 st = cetrafs_cas_stamp_bump(sb, fs_lba, sk, old, new, region_idx, region);

            if (st && nissued < CETRAFS_CAS_ISSUED_MAX)
                issued[nissued++] = st;
            else if (st)
                issued_over = true; /* past the cap: unjudgeable, as before G-6 */
        }

        if (unlikely(READ_ONCE(cetrafs_cas_stall_ino)) && fs_lba == cetrafs_inode_lba(sb, cetrafs_cas_stall_ino) &&
            xchg(&cetrafs_cas_stall_ino, 0))
            msleep(READ_ONCE(cetrafs_cas_stall_ms)); /* TEST ONLY: between the read and the swap */
        /*
         * And again here, last, on every attempt: the gates above come
         * before a cache flush and a forced-fresh read that can wait out
         * a path failover (dmpath's resolve, 15 s), and a swap built from
         * that read went out after a lease that lapsed meanwhile -- a
         * last-writer-wins record publish stamping this node's stale
         * extent root over the tree of the node HA restarted the VM on
         * (audit 2026-11-15 B-19). One load-compare per swap. A CAW
         * already queued below this line is the A-6 residue.
         */
        if (cetrafs_sb_is_fenced(sb) && !READ_ONCE(cetrafs_cas_gate_last_off)) {
            ret = -EIO;
            goto out;
        }
        /* Once a swap is undecided, nothing may end this call short of
         * an answer: an -EINTR from a killed wait for a path stopped
         * the mount (M-21). */
        ret = cetrafs_caw(sb->s_bdev, dev_lba, 1, old, new, killable && !undecided);
        if (image_only && ret == 0 && READ_ONCE(cetrafs_cas_judged_timeout_once) &&
            xchg(&cetrafs_cas_judged_timeout_once, false))
            ret = -ETIMEDOUT; /* TEST ONLY: landed, reported timed out -- see the parameter */
        {
            /* DEBUG: every inode-bitmap CAS, with everything needed to
             * compare two nodes' wins for one bit: the exact device
             * sector, the attempt, the verdict, and the compare/write
             * bytes. The raw-path sg duel proved the array atomic even
             * cross-port, so if two nodes both win one bit the
             * divergence MUST be visible here. */
            if (cetrafs_lba_in_ibmap(sb, fs_lba))
                ctrace("IBCAS fs_lba=%llu reg=%u dev_lba=%llu att=%d ret=%d old=%16ph new=%16ph\n",
                        (unsigned long long) fs_lba, region_idx, (unsigned long long) dev_lba, attempt, ret,
                        old, new);
        }
        if (ret == 0) {
            /* The swap went straight to the device, behind the buffer
             * cache. Rather than dropping the cached copy -- which turns
             * every swap into a later device read of a block that is
             * about to be wanted again -- write the bytes we just put on
             * the device into it and leave it clean. */
            cetrafs_cas_publish_cache(sb, fs_lba, off, new, region, sole_region);
            goto out;
        }
        if (ret == -ETIMEDOUT) {
            /*
             * The command's outcome is UNKNOWN: the target never
             * answered, so the swap may or may not have landed. Issuing
             * it again is exactly what must not happen -- a mutator
             * that adds a delta would apply it twice.
             *
             * The region itself settles it. Re-read it fresh and look:
             *
             *   - it holds our post-image  -> the swap landed; done.
             *   - it holds our pre-image   -> it did not; retrying is
             *                                 provably safe, and the
             *                                 failed path is already
             *                                 out of rotation.
             *   - anything else            -> somebody wrote it in the
             *                                 meantime and we cannot
             *                                 tell whether ours landed
             *                                 first. Refuse loudly
             *                                 rather than guess.
             *
             * Byte compares, then the G-6 stamp: the post-image carries
             * a stamp no other swap writes, so "ours" is exact, and a
             * changed region is judged by its stamp before giving up
             * (cetrafs_cas_stamp_judge()). Undecidable is now only two
             * or more swaps since the image ours compared.
             */
            u8 *vb = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOIO);

            if (!vb || cetrafs_cas_verify_read(sb, fs_lba, vb)) {
                kfree(vb);
                /* Not readable NOW (the path just failed): the swap is
                 * undecided, and the next attempt's fresh read judges
                 * it once a path answers (M-21). */
                if (!undecided) {
                    memcpy(unknown, new, region);
                    memcpy(unknown + region, old, region);
                    undecided = true;
                    undecided_until = jiffies + cetrafs_cas_undecided_window(sb);
                }
                if (cetrafs_cas_undecided_nap(sb, undecided_until, &naps)) {
                    extra++;
                    continue;
                }
                if (READ_ONCE(cetrafs_cas_selftest_sb) == sb) {
                    pr_info("CAS selftest: lba=%llu would stop the mount here (outcome undecidable)\n",
                            (unsigned long long) fs_lba);
                    WRITE_ONCE(cetrafs_cas_selftest_stop_seen, true);
                } else {
                    cetrafs_sb_fatal(sb, "CAS lba=%llu: outcome unknown and the region could not be re-read",
                                     (unsigned long long) fs_lba);
                }
                ret = -EIO;
                goto out;
            }
            if (!memcmp(vb + off, new, region)) {
                pr_warn("CAS lba=%llu: command timed out but the swap IS on the device -- taking it as done\n",
                        (unsigned long long) fs_lba);
                if (image_only && soff < 0)
                    *image_only = true; /* unstamped: a peer's identical swap reads the same */
                kfree(vb);
                cetrafs_cas_publish_cache(sb, fs_lba, off, new, region, sole_region);
                ret = 0;
                goto out;
            }
            if (!memcmp(vb + off, old, region)) {
                /* Not on the device NOW. A timed-out command can still be
                 * queued on the array and land behind our back, after
                 * this re-read; keep its image, so that if the retry
                 * then MISCOMPAREs we can tell "ours landed late" from
                 * "a peer won" instead of applying the mutator again. */
                pr_warn("CAS lba=%llu: command timed out and has not landed -- retrying on another path\n",
                        (unsigned long long) fs_lba);
                kfree(vb);
                memcpy(unknown, new, region);          /* its post-image */
                memcpy(unknown + region, old, region); /* and the image it compared */
                if (!undecided)
                    undecided_until = jiffies + cetrafs_cas_undecided_window(sb);
                undecided = true;
                continue;
            }
            {
                /* G-6: the stamp says which. 'old' is the image this
                 * command compared -- every undecided one before it did
                 * too, or the read above would have decided them. */
                enum cetrafs_stamp_verdict sv = cetrafs_cas_stamp_judge(
                    cetrafs_cas_stamp_get(vb + off, soff), cetrafs_cas_stamp_get(old, soff), issued, nissued, issued_over);

                if (sv == CETRAFS_SV_LANDED) {
                    pr_warn("CAS lba=%llu: command timed out and a swap of ours IS on the device (by its stamp) "
                            "-- taking it as done\n",
                            (unsigned long long) fs_lba);
                    cetrafs_cas_publish_cache(sb, fs_lba, off, vb + off, region, sole_region);
                    kfree(vb);
                    ret = 0;
                    goto out;
                }
                if (sv == CETRAFS_SV_NEVER) {
                    pr_warn("CAS lba=%llu: command timed out and a peer's swap won (by its stamp) -- retrying\n",
                            (unsigned long long) fs_lba);
                    atomic64_inc(&cetrafs_cas_stamp_decided);
                    kfree(vb);
                    undecided = false;
                    nissued = 0;
                    issued_over = false;
                    continue;
                }
            }
            kfree(vb);
            cetrafs_sb_fatal(sb, "CAS lba=%llu: timed out and the region changed since -- cannot tell whether "
                                 "the swap landed",
                             (unsigned long long) fs_lba);
            ret = -EIO;
            goto out;
        }

        if (ret != -EBUSY && undecided && cetrafs_cas_undecided_nap(sb, undecided_until, &naps)) {
            /* A definite "not executed" (or no path) on the retry of an
             * undecided swap is not an answer about the FIRST one: wait,
             * re-read and re-judge. Ending here stopped the mount over a
             * path failover (audit 2026-11-15 M-21). */
            extra++;
            continue;
        }
        if (ret != -EBUSY)
            goto out; /* real transport error */

        atomic64_inc(&cetrafs_cas_miscompares);

        if (undecided) {
            /* A MISCOMPARE after a swap whose outcome was unknown: the
             * region moved since the re-read that found the pre-image.
             * If it now holds that swap's post-image, the timed-out
             * command landed late and is our success; running the
             * mutator again would apply it twice. Anything else may be a
             * peer writing over our late landing, which cannot be told
             * apart from a peer that simply won -- refuse rather than
             * guess, as the timeout path above does. */
            u8 *vb = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOIO);
            int vret = vb ? cetrafs_cas_verify_read(sb, fs_lba, vb) : -ENOMEM;

            if (vret && cetrafs_cas_undecided_nap(sb, undecided_until, &naps)) {
                kfree(vb);
                extra++;
                continue; /* the next attempt's read judges it */
            }
            if (!vret && !memcmp(vb + off, unknown, region)) {
                pr_warn("CAS lba=%llu: the timed-out command landed late -- taking it as done\n",
                        (unsigned long long) fs_lba);
                if (image_only && soff < 0)
                    *image_only = true;
                kfree(vb);
                cetrafs_cas_publish_cache(sb, fs_lba, off, unknown, region, sole_region);
                ret = 0;
                goto out;
            }
            if (!vret) {
                enum cetrafs_stamp_verdict sv =
                    cetrafs_cas_stamp_judge(cetrafs_cas_stamp_get(vb + off, soff),
                                            cetrafs_cas_stamp_get(unknown + region, soff), issued, nissued, issued_over);

                if (sv == CETRAFS_SV_LANDED) {
                    pr_warn("CAS lba=%llu: the timed-out command landed late -- taking it as done (by its stamp)\n",
                            (unsigned long long) fs_lba);
                    cetrafs_cas_publish_cache(sb, fs_lba, off, vb + off, region, sole_region);
                    kfree(vb);
                    ret = 0;
                    goto out;
                }
                if (sv == CETRAFS_SV_NEVER || sv == CETRAFS_SV_NOT_YET) {
                    /* NEVER: a peer's swap won from our image; ours
                     * cannot land. NOT_YET cannot follow a MISCOMPARE
                     * against that image -- treated alike: re-read. */
                    atomic64_inc(&cetrafs_cas_stamp_decided);
                    kfree(vb);
                    undecided = sv == CETRAFS_SV_NOT_YET;
                    if (!undecided) {
                        nissued = 0;
                        issued_over = false;
                    }
                    continue;
                }
            }
            kfree(vb);
            cetrafs_sb_fatal(sb, "CAS lba=%llu: the region changed after a timed-out command -- cannot tell "
                                 "whether it landed",
                             (unsigned long long) fs_lba);
            ret = -EIO;
            goto out;
        }

        /* MISCOMPARE: someone else won. Re-read and re-decide.
         *
         * The first couple of retries go straight back round -- a lost
         * race is normally resolved immediately, and sleeping would add
         * latency to the common case. Past that, back off: 16 immediate
         * spins against a genuinely contended region just burn round
         * trips and then surface as -EBUSY from an ordinary creat(),
         * which is a spurious failure of a legal operation. Same
         * reasoning as cetrafs_bread_retry()'s backoff. */
        if (attempt >= 2)
            usleep_range(50 << min(attempt - 2, 5), 200 << min(attempt - 2, 5));
    }

    ret = -EBUSY;

out:
    /*
     * A swap whose outcome was unknown, and no answer: this exit is
     * neither a "done" nor a "not done". A re-read that failed, a
     * transport error on the retry, the retry budget or a fence -- each
     * used to return a plain error, the caller took it as not applied
     * and re-accrued its delta, and the timed-out command could then
     * land too: a BG count moved twice (audit 2026-11-06 L12). Every
     * undecidable outcome stops the mount (docs/internal/ERRORS.md);
     * the paths that already said so are stopped by now.
     */
    if (undecided && ret && !cetrafs_sb_is_fenced(sb)) {
        if (READ_ONCE(cetrafs_cas_selftest_sb) == sb) {
            pr_info("CAS selftest: lba=%llu would stop the mount here (outcome undecidable, %d)\n",
                    (unsigned long long) fs_lba, ret);
            WRITE_ONCE(cetrafs_cas_selftest_stop_seen, true);
        } else {
            cetrafs_sb_fatal(sb, "CAS lba=%llu: a timed-out swap is still undecided and this call ended (%d)",
                             (unsigned long long) fs_lba, ret);
        }
        ret = -EIO;
    }
    if (ret == -EUCLEAN)
        cetrafs_cas_refused_damage(sb, fs_lba);
    kfree(unknown);
    kfree(old);
    kfree(new);
    return ret;
}

/*
 * Every swap, whatever its outcome (a timed-out one may still land),
 * moves the record's publish epoch AFTER the device has it: a refresh
 * that sampled the epoch before its read can then tell that a local
 * publish may have landed behind its read (cetrafs_rec_epoch_bump(),
 * BUG-CLASSES class 29).
 */
static int cetrafs_cas_region_seeded_publish(struct super_block *sb,
                                             u64 fs_lba,
                                             unsigned int region_idx,
                                             const void *seed,
                                             unsigned int seed_len,
                                             cetrafs_cas_fn mutate,
                                             void *priv,
                                             bool sole_region,
                                             bool killable)
{
    int ret = cetrafs_cas_region_seeded_impl(sb, fs_lba, region_idx, seed, seed_len, mutate, priv, sole_region,
                                             killable, NULL);

    cetrafs_rec_epoch_bump(sb, fs_lba);
    return ret;
}

/*
 * cetrafs_cas_region(), telling the caller when its success was decided
 * from the image alone: the command's outcome was unknown and the region
 * was found holding this swap's post-image. That is our swap -- or a
 * peer's that built the same bytes from the same pre-image, which a
 * mutator carrying no writer identity does (the inode allocator takes
 * the lowest free bit, so two creators build identical images). Such a
 * caller cannot act on the success as its own (audit 2026-11-14 B-4).
 */
int cetrafs_cas_region_judged(struct super_block *sb, u64 fs_lba, unsigned int region_idx, cetrafs_cas_fn mutate,
                              void *priv, bool *image_only)
{
    int ret;

    *image_only = false;
    ret = cetrafs_cas_region_seeded_impl(sb, fs_lba, region_idx, NULL, 0, mutate, priv, /*sole_region=*/false,
                                         /*killable=*/true, image_only);
    cetrafs_rec_epoch_bump(sb, fs_lba);
    return ret;
}

int cetrafs_cas_region(struct super_block *sb, u64 fs_lba, unsigned int region_idx, cetrafs_cas_fn mutate, void *priv)
{
    return cetrafs_cas_region_seeded(sb, fs_lba, region_idx, NULL, 0, mutate, priv);
}

int cetrafs_cas_region_seeded(struct super_block *sb,
                              u64 fs_lba,
                              unsigned int region_idx,
                              const void *seed,
                              unsigned int seed_len,
                              cetrafs_cas_fn mutate,
                              void *priv)
{
    /* A region block holds several independent regions (8 per 4 KiB),
     * each swapped by a different node at a different time -- an inode
     * bitmap, a pending-free queue. Only the swapped region's new
     * content is known, so the cached copy of the OTHERS may already be
     * stale and the whole block has to be dropped. */
    return cetrafs_cas_region_seeded_publish(sb, fs_lba, region_idx, seed, seed_len, mutate, priv,
                                             /*sole_region=*/false, /*killable=*/true);
}

/* cetrafs_cas_record() with the caller's own fresh image as the first
 * compare -- see cetrafs_cas_region_seeded(). */
int cetrafs_cas_record_seeded(struct super_block *sb,
                              u64 fs_lba,
                              const void *seed,
                              unsigned int seed_len,
                              cetrafs_cas_fn mutate,
                              void *priv)
{
    /* A RECORD block holds exactly one record; region 0 is its NAMESPACE
     * sector (v0x0005), the CAS unit of every cross-node claim. The
     * cached copy is kept and only the swapped sector's bytes patched --
     * the record's FILE sector (region 1) in this node's cache stays
     * whatever this node last knew, which is exactly as current as any
     * cached record read (freshness-gated where it matters). These are
     * also the blocks most worth keeping: the record a namespace
     * operation just updated is the record the next lookup reads. */
    return cetrafs_cas_region_seeded_publish(sb, fs_lba, 0, seed, seed_len, mutate, priv, /*sole_region=*/true,
                                             /*killable=*/true);
}

/* On a device whose atomic unit is wider than the namespace sector (4Kn:
 * one CAS region = the whole record block), the file-domain sector is
 * no region of its own -- it lives at CETRAFS_INODE_FD_OFF inside region
 * 0. Hand the mutator exactly that slice, so it sees the same
 * 512-byte image it gets on a 512-logical device. */
struct cetrafs_cas_fd_slice_ctx {
    cetrafs_cas_fn mutate;
    void *priv;
};

static int cetrafs_cas_fd_slice_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_cas_fd_slice_ctx *s = priv;

    if (len < CETRAFS_INODE_FD_OFF + CETRAFS_INODE_FD_BYTES)
        return -EINVAL;
    return s->mutate((u8 *) image + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_BYTES, s->priv);
}

/* The record's FILE-domain sector (region 1, bytes [512,1024) of the
 * record block) -- the half the file data path publishes. Same
 * keep-and-patch cache treatment as the namespace sector.
 *
 * "Region 1" only exists while a CAS region is CETRAFS_INODE_FD_OFF
 * bytes. On a 4Kn device with CAW the region is the whole block, region
 * 1 would start past its end, and every file-domain publish -- fsync,
 * fdatasync, writeback, close -- failed -EINVAL in the impl's bounds
 * check (seen as qemu's first flush after a write failing while the
 * second, with nothing left dirty, "succeeded"). There the swap goes
 * through region 0 with the mutator confined to the fd slice: a peer's
 * concurrent namespace change then miscompares and retries instead of
 * being clobbered. The caller's seed is an fd-sector image, not a block
 * image, so it is dropped and the first attempt reads fresh. */
int cetrafs_cas_record_fd_seeded(struct super_block *sb,
                                 u64 fs_lba,
                                 const void *seed,
                                 unsigned int seed_len,
                                 cetrafs_cas_fn mutate,
                                 void *priv)
{
    if (cetrafs_cas_region_size(sb) > CETRAFS_INODE_FD_OFF) {
        struct cetrafs_cas_fd_slice_ctx s = {.mutate = mutate, .priv = priv};

        return cetrafs_cas_region_seeded_publish(sb, fs_lba, 0, NULL, 0, cetrafs_cas_fd_slice_mutate, &s,
                                                 /*sole_region=*/true, /*killable=*/true);
    }
    return cetrafs_cas_region_seeded_publish(sb, fs_lba, 1, seed, seed_len, mutate, priv, /*sole_region=*/true,
                                             /*killable=*/true);
}

/* ---- self-test ------------------------------------------------------
 *
 * cetrafs_cas_record() is exercised in production by every claim path, but
 * the self-test still needs its own way to be
 * exercised. Enabled by the cas_selftest module param, run once per
 * mount right after node registration.
 *
 * Target: the padding tail of THIS node's own Node Registry row block --
 * a block this node exclusively owns, at a byte offset (256) well past
 * the 128-byte record, so the bytes touched are outside every checksum
 * and carry no meaning whatsoever. Runs before the heartbeat starts, so
 * nothing else rewrites the block underneath it.
 *
 * Checks three things: a successful swap, a MISCOMPARE correctly
 * surfacing as -EBUSY (fed a deliberately wrong compare image), and a
 * clean restore. On a device without CAW this exercises the PR-mutex
 * fallback path instead -- which is exactly what runs on the loop-device
 * test harness.
 */
/* Through cetrafs_test_param(): it writes this node's row block at every
 * mount and injects timeouts into live swaps, and was a plain parameter
 * that left no trace (audit 2026-11-11 C7). */
bool cetrafs_cas_selftest_enabled;
cetrafs_test_param(cas_selftest, cetrafs_cas_selftest_enabled, bool, 0644);
MODULE_PARM_DESC(
    cas_selftest,
    "test-only: run a CAS round-trip self-test against this node's own registry row at mount (diagnostic)");

#define CETRAFS_CAS_SELFTEST_OFF 256 /* inside the row block's zero padding */

/* A DELTA mutator for the self-test: the only kind that can show a
 * double application, because re-running it on its own post-image does
 * not converge the way an absolute write does. */
static int cetrafs_cas_selftest_inc(void *image, unsigned int len, void *priv)
{
    (void) len;
    (void) priv;
    ((u8 *) image)[CETRAFS_CAS_SELFTEST_OFF]++;
    return 0;
}

static int cetrafs_cas_selftest_set(void *image, unsigned int len, void *priv)
{
    (void) len;
    ((u8 *) image)[CETRAFS_CAS_SELFTEST_OFF] = *(u8 *) priv;
    return 0;
}

void cetrafs_cas_selftest(struct super_block *sb, u32 my_node_id)
{
    u64 lba = cetrafs_node_row_lba(sb, my_node_id);
    bool have_caw = cetrafs_sb_caw_available(sb);
    u8 marker = 0xA5, restore = 0x00;
    struct buffer_head *bh;
    bool ok = true;
    int ret;

    if (!cetrafs_cas_selftest_enabled || !lba)
        return;

    pr_info("CAS selftest: starting on row-block LBA %llu via the %s path\n", (unsigned long long) lba,
            have_caw ? "atomic CAW" : "no-CAW fallback");

    /* 1. swap a marker byte in */
    ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_set, &marker);
    if (ret) {
        pr_err("CAS selftest: swap failed: %d\n", ret);
        ok = false;
    } else {
        bh = cetrafs_bread_uncached_retry(sb, lba);
        if (!bh || (u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] != marker) {
            pr_err("CAS selftest: marker did not land on disk\n");
            ok = false;
        }
        if (bh)
            brelse(bh);
    }

    /* 2. a stale compare image must be rejected, not applied. Only the
     * CAW path can detect this -- the mutex fallback has no compare
     * step, by construction. */
    if (ok && have_caw) {
        unsigned int region = cetrafs_sb_caw(sb)->logical_block_size;
        u8 *wrong = kzalloc(region, GFP_KERNEL);
        u8 *newer = kzalloc(region, GFP_KERNEL);

        if (wrong && newer) {
            u64 dev_lba = lba * (CETRAFS_BLOCK_SIZE / region);

            wrong[CETRAFS_CAS_SELFTEST_OFF] = 0x5A; /* != what we just wrote */
            ret = cetrafs_caw(sb->s_bdev, dev_lba, 1, wrong, newer, false);
            if (ret != -EBUSY) {
                pr_err("CAS selftest: stale compare returned %d, expected -EBUSY (MISCOMPARE)\n", ret);
                ok = false;
            }
        }
        kfree(wrong);
        kfree(newer);
    }

    /* 2b. The SEEDED path (cetrafs_cas_record_seeded). It only ever runs
     * on hardware with atomic CAW, which means the loop-device test
     * suite cannot reach it at all -- so without this, the one
     * optimisation that skips a read on every claim would be covered by
     * nothing. Two cases, and the second is the one that matters:
     *
     *   - a CORRECT seed must behave exactly like the unseeded call;
     *   - a WRONG seed must still produce the right answer, by
     *     miscomparing and falling back to a fresh re-read. If that ever
     *     stopped holding, a stale seed would silently write from a
     *     stale image, which is the whole hazard the retry loop exists
     *     to make impossible.
     */
    if (ok && have_caw) {
        unsigned int region = cetrafs_sb_caw(sb)->logical_block_size;
        u8 *seed = kzalloc(region, GFP_KERNEL);
        u8 want = 0x3C;

        if (seed) {
            /* A deliberately WRONG seed: every byte zero, which cannot
             * match a row carrying our UUID and checksum. */
            ret = cetrafs_cas_record_seeded(sb, lba, seed, region, cetrafs_cas_selftest_set, &want);
            if (ret) {
                pr_err("CAS selftest: seeded swap with a STALE seed failed: %d (it must recover by re-reading)\n", ret);
                ok = false;
            } else {
                bh = cetrafs_bread_uncached_retry(sb, lba);
                if (!bh || (u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] != want) {
                    pr_err("CAS selftest: stale-seeded swap did not land the right value on disk\n");
                    ok = false;
                }
                if (bh)
                    brelse(bh);
            }

            /* And a CORRECT seed: read the region, hand it straight
             * back, and require the swap to land first time. */
            if (ok) {
                bh = cetrafs_bread_uncached_retry(sb, lba);
                if (bh) {
                    u8 want2 = 0xC3;

                    cetrafs_bh_copy_stable_at(bh, 0, seed, region);
                    brelse(bh);
                    ret = cetrafs_cas_record_seeded(sb, lba, seed, region, cetrafs_cas_selftest_set, &want2);
                    if (ret) {
                        pr_err("CAS selftest: seeded swap with a CORRECT seed failed: %d\n", ret);
                        ok = false;
                    } else {
                        bh = cetrafs_bread_uncached_retry(sb, lba);
                        if (!bh || (u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] != want2) {
                            pr_err("CAS selftest: correctly-seeded swap did not land on disk\n");
                            ok = false;
                        }
                        if (bh)
                            brelse(bh);
                    }
                }
            }
        }
        kfree(seed);
    }

    /*
     * 2c. A timed-out command must leave the mutator applied EXACTLY
     * ONCE, whichever way the ambiguity fell.
     *
     * This is the one the delta mutator exists for. An absolute write
     * converges -- re-running it on its own post-image produces the
     * same bytes and the CAS layer's "mutator made no change" exit
     * turns the second attempt into a no-op, so it can never show a
     * double application. An increment can, and so can every real
     * mutator shaped like it: the ZG free aggregate, the pool shard,
     * the pending-free append, the BG count's delta arm.
     *
     * Only on hardware with atomic CAW: without it there is no command
     * to time out.
     */
    if (ok && have_caw) {
        u8 base = 0x10;
        unsigned int phase;

        static const char *const whats[] = {"lost",
                                            "landed",
                                            "landed late",
                                            "refused not-ready on one path",
                                            "landed before the re-read",
                                            "MEDIUM ERROR after landing",
                                            "ABORTED COMMAND after landing"};

        for (phase = 0; phase < ARRAY_SIZE(whats); phase++) {
            const char *what = whats[phase];
            bool fired;

            ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_set, &base);
            if (ret) {
                pr_err("CAS selftest: could not set the %s-case baseline: %d\n", what, ret);
                ok = false;
                break;
            }

            cetrafs_caw_timeout_lost_once = phase == 0;
            cetrafs_caw_timeout_landed_once = phase == 1;
            cetrafs_caw_timeout_late_once = phase == 2;
            if (phase == 3 && strncmp(sb->s_bdev->bd_disk->disk_name, "dm-", 3)) {
                pr_info("CAS selftest: the %s case needs a dm path -- not exercised here\n", what);
                continue;
            }
            cetrafs_caw_not_ready_count = phase == 3;
            cetrafs_caw_timeout_late_preread_once = phase == 4;
            cetrafs_caw_sense_landed_once = phase == 5 ? MEDIUM_ERROR : phase == 6 ? ABORTED_COMMAND : 0;

            ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_inc, NULL);
            /* The -EIO knob only fires on a dm path; say so rather than
             * report a case that never ran as passed. */
            fired = !cetrafs_caw_not_ready_count && !cetrafs_caw_sense_landed_once;
            cetrafs_caw_timeout_landed_once = false;
            cetrafs_caw_timeout_lost_once = false;
            cetrafs_caw_timeout_late_once = false;
            cetrafs_caw_not_ready_count = 0;
            cetrafs_caw_timeout_late_preread_once = false;
            cetrafs_caw_sense_landed_once = 0;
            if (!fired) {
                pr_info("CAS selftest: the %s case needs a %s path -- not exercised here\n", what,
                        phase == 3 ? "dm" : "SCSI");
                continue;
            }

            if (ret) {
                pr_err("CAS selftest: increment across a timed-out (%s) command failed: %d\n", what, ret);
                ok = false;
                break;
            }

            bh = cetrafs_bread_uncached_retry(sb, lba);
            if (!bh) {
                pr_err("CAS selftest: could not read back the %s case\n", what);
                ok = false;
                break;
            }
            if ((u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] != (u8) (base + 1)) {
                pr_err("CAS selftest: a timed-out (%s) command left the delta applied %d time(s), expected once "
                       "(0x%02x -> 0x%02x)\n",
                       what, (int) ((u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] - base), base,
                       (u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF]);
                ok = false;
            }
            brelse(bh);
            if (!ok)
                break;
            pr_info("CAS selftest: a timed-out (%s) command applied the delta exactly once\n", what);
        }
    }

    /*
     * 2d. A timed-out command that landed, while this node holds a DIRTY
     * copy of the block: the re-read asks the device, not that copy, so
     * the outcome is decided -- taken as done, applied once, and no
     * mount stop. It used to read the cache, find the dirty copy and stop
     * the mount over a question the device could answer (audit
     * 2026-11-11 C3). See cetrafs_cas_verify_read().
     */
    if (ok && have_caw) {
        u8 base = 0x30;

        ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_set, &base);
        if (ret) {
            pr_err("CAS selftest: could not set the dirty-verify baseline: %d\n", ret);
            ok = false;
        } else {
            u8 *vb = kmalloc(CETRAFS_BLOCK_SIZE, GFP_KERNEL);

            WRITE_ONCE(cetrafs_cas_selftest_stop_seen, false);
            WRITE_ONCE(cetrafs_cas_selftest_sb, sb);
            cetrafs_caw_timeout_landed_once = true;
            cetrafs_cas_verify_dirty_once = true;
            ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_inc, NULL);
            cetrafs_caw_timeout_landed_once = false;
            cetrafs_cas_verify_dirty_once = false;
            WRITE_ONCE(cetrafs_cas_selftest_sb, NULL);
            if (READ_ONCE(cetrafs_cas_selftest_stop_seen)) {
                pr_err("CAS selftest: a timeout the device could decide stopped the mount (dirty local copy)\n");
                ok = false;
            }
            if (ret) {
                pr_err("CAS selftest: a timeout the device could decide returned %d, expected 0\n", ret);
                ok = false;
            }
            /* The dirty copy goes out as it would by writeback -- the
             * swap's region patched into it -- and the device is read
             * past the cache: applied once, and not undone. */
            bh = sb_find_get_block(sb, lba);
            if (bh) {
                if (cetrafs_bh_pending(bh))
                    (void) cetrafs_sync_buffer(sb, bh); /* the device read below is the check */
                brelse(bh);
            }
            if (!vb || cetrafs_cas_verify_read(sb, lba, vb)) {
                pr_err("CAS selftest: could not read back the dirty-verify case\n");
                ok = false;
            } else if (vb[CETRAFS_CAS_SELFTEST_OFF] != (u8) (base + 1)) {
                pr_err("CAS selftest: a timeout decided past a dirty copy left the delta applied %d time(s), "
                       "expected once\n",
                       (int) (vb[CETRAFS_CAS_SELFTEST_OFF] - base));
                ok = false;
            }
            kfree(vb);
            if (ok)
                pr_info("CAS selftest: a timeout decided from the device past a dirty local copy, applied once\n");
        }
    }

    /*
     * 2e. A swap while this node holds a DIRTY copy of the block -- a
     * local writer landing after the swap's own flush: once that copy is
     * written back, the device must still hold the swap. The record CAS
     * is a non-sole region swap, whose cache step used to only drop the
     * buffer -- and a dirty one is kept, pre-image and all (audit
     * 2026-11-11 C2, cetrafs_cas_publish_cache()). CAW only: the
     * fallback writes the swap through the buffer itself.
     */
    if (ok && have_caw) {
        u8 val = 0x77;

        bh = cetrafs_bread_retry(sb, lba);
        if (!bh) {
            pr_err("CAS selftest: could not read the block to dirty it\n");
            ok = false;
        } else {
            WRITE_ONCE(cetrafs_cas_dirty_after_flush_once, true);
            ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_set, &val);
            WRITE_ONCE(cetrafs_cas_dirty_after_flush_once, false);
            if (cetrafs_bh_pending(bh))
                (void) cetrafs_sync_buffer(sb, bh); /* the device read below is the check */
            brelse(bh);
            if (ret) {
                pr_err("CAS selftest: a swap over a dirty local copy failed: %d\n", ret);
                ok = false;
            } else {
                bh = cetrafs_bread_uncached_retry(sb, lba);
                if (!bh || (u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] != val) {
                    pr_err("CAS selftest: writing back a dirty local copy undid a swap (device holds 0x%02x, "
                           "swapped 0x%02x)\n",
                           bh ? (u8) bh->b_data[CETRAFS_CAS_SELFTEST_OFF] : 0, val);
                    ok = false;
                } else {
                    pr_info("CAS selftest: a swap over a dirty local copy survives its write-back\n");
                }
                if (bh)
                    brelse(bh);
            }
        }
    }

    /* 3. restore the padding byte */
    ret = cetrafs_cas_record(sb, lba, cetrafs_cas_selftest_set, &restore);
    if (ret) {
        pr_err("CAS selftest: restore failed: %d\n", ret);
        ok = false;
    }

    pr_info("CAS selftest: %s\n", ok ? "PASSED" : "FAILED");
}

/* ---- concurrent CAS stress ------------------------------------------
 *
 * The self-test above proves one CAS works. It says nothing about what
 * the primitive exists FOR: that two mutators racing on the same record
 * cannot lose each other's update. That property is unobservable on the
 * loop-device harness -- there is no CAW there, so cetrafs_cas_region()
 * takes its plain read-fresh / mutate / write fallback and the question
 * does not arise -- which left the compare-and-swap itself, the thing
 * every claim path in this filesystem now rests on, covered only by a
 * single-threaded round trip.
 *
 * So: N threads each increment the same counter M times through
 * cetrafs_cas_record(). Every increment that returns success must be
 * present in the final value, so the counter must read exactly N*M. A
 * lost update is a CAS that overwrote a value it never compared
 * against; under CAW that cannot happen, because a racing write makes
 * the device MISCOMPARE and the attempt is retried against the fresh
 * image.
 *
 * Same scratch bytes as the self-test (this node's own row block, well
 * past the record, outside every checksum), as a u32 at offset 256 --
 * and it runs at mount before the heartbeat starts, so nothing else is
 * rewriting that block underneath it.
 *
 * This asserts on BOTH paths, and that is the point. It used to merely
 * REPORT on the no-CAW path, on the reasoning that lost updates were
 * expected there because every production caller was already serialised
 * by some higher lock (nslock's ns_mutex, lock.c's lock_mutex, or being
 * the single heartbeat thread). That reasoning was wrong for four of the
 * eight callers -- the global inode bitmap above all, which fs.c
 * explicitly exempts from alloc_mutex BECAUSE the CAS was believed to be
 * atomic -- and the under-count this printed as "expected" was a real
 * filesystem bug the whole time: two files on one inode number. The
 * no-CAW path now takes a node-local mutex (see cetrafs_cas_nocaw()), so
 * "no lost updates" is a property of the primitive itself and is
 * asserted as one, whatever the device can do.
 */
static unsigned int cetrafs_cas_stress_threads;
cetrafs_test_param(cas_stress, cetrafs_cas_stress_threads, uint, 0644);
MODULE_PARM_DESC(cas_stress,
                 "test-only: run N threads racing to increment one record through CAS at mount (diagnostic)");

static unsigned int cetrafs_cas_stress_iters = 50;
cetrafs_test_param(cas_stress_iters, cetrafs_cas_stress_iters, uint, 0644);
MODULE_PARM_DESC(cas_stress_iters, "test-only: increments per cas_stress thread (default 50)");

struct cetrafs_cas_stress_ctx {
    struct super_block *sb;
    u64 lba;
    atomic_t ok_count;
    atomic_t err_count;
    atomic_t running;
    wait_queue_head_t done;
    unsigned int iters;
    /*
     * On the HEAP, with a reference per participant.
     *
     * This used to live on the launcher's stack. The last thread does
     * atomic_dec_and_test(&running) and then wake_up(&done) -- and
     * between those two the waiter can observe zero, return, and take
     * its stack frame with it, leaving wake_up() writing into a frame
     * that no longer exists.
     *
     * kthread_stop() is NOT the way back: it was tried, and without a
     * get_task_struct() it was a use-after-free of the task itself
     * (refcount_warn_saturate, then an Oops in mount). A reference
     * count on the context is what makes the last toucher the one who
     * frees it, whichever that turns out to be.
     */
    atomic_t refs;
};

static void cetrafs_cas_stress_put(struct cetrafs_cas_stress_ctx *ctx)
{
    if (atomic_dec_and_test(&ctx->refs))
        kfree(ctx);
}

static int cetrafs_cas_stress_inc(void *image, unsigned int len, void *priv)
{
    u32 v;

    (void) len;
    (void) priv;
    memcpy(&v, (u8 *) image + CETRAFS_CAS_SELFTEST_OFF, sizeof(v));
    v++;
    memcpy((u8 *) image + CETRAFS_CAS_SELFTEST_OFF, &v, sizeof(v));
    return 0;
}

static int cetrafs_cas_stress_thread(void *arg)
{
    struct cetrafs_cas_stress_ctx *ctx = arg;
    unsigned int i;

    for (i = 0; i < ctx->iters; i++) {
        int ret = cetrafs_cas_record(ctx->sb, ctx->lba, cetrafs_cas_stress_inc, NULL);

        if (ret == 0)
            atomic_inc(&ctx->ok_count);
        else
            atomic_inc(&ctx->err_count);
        cond_resched();
    }

    /* Signal completion by counter, and never touch this thread's
     * task_struct again -- a kthread that returns on its own drops the
     * reference kthread_run() handed back, so the kthread_stop() this
     * used to do was a use-after-free (refcount_warn_saturate, then an
     * Oops in mount, reproduced on the first run against real CAW). */
    if (atomic_dec_and_test(&ctx->running))
        wake_up(&ctx->done);
    cetrafs_cas_stress_put(ctx); /* the waiter may already be gone */
    return 0;
}

static int cetrafs_cas_stress_zero(void *image, unsigned int len, void *priv)
{
    u32 z = 0;

    (void) len;
    (void) priv;
    memcpy((u8 *) image + CETRAFS_CAS_SELFTEST_OFF, &z, sizeof(z));
    return 0;
}

void cetrafs_cas_stress(struct super_block *sb, u32 my_node_id)
{
    u64 lba = cetrafs_node_row_lba(sb, my_node_id);
    bool have_caw = cetrafs_sb_caw_available(sb);
    struct cetrafs_cas_stress_ctx *ctxp;
    struct buffer_head *bh;
    unsigned int n = cetrafs_cas_stress_threads;
    unsigned int i, started = 0;
    u32 final = 0;
    u64 mc_before;
    int ret;

    if (!n || !lba)
        return;
    if (n > 64)
        n = 64;

    ctxp = kzalloc(sizeof(*ctxp), GFP_KERNEL);
    if (!ctxp)
        return;
    atomic_set(&ctxp->refs, 1); /* the launcher's own */
#define ctx (*ctxp)
    ctx.sb = sb;
    ctx.lba = lba;
    ctx.iters = cetrafs_cas_stress_iters ? cetrafs_cas_stress_iters : 1;
    atomic_set(&ctx.ok_count, 0);
    atomic_set(&ctx.err_count, 0);
    atomic_set(&ctx.running, 0);
    init_waitqueue_head(&ctx.done);

    ret = cetrafs_cas_record(sb, lba, cetrafs_cas_stress_zero, NULL);
    if (ret) {
        pr_err("CAS stress: could not zero the counter: %d\n", ret);
        cetrafs_cas_stress_put(ctxp);
        return;
    }
    mc_before = cetrafs_cas_miscompare_count();

    pr_info("CAS stress: %u threads x %u increments via the %s path\n", n, ctx.iters,
            have_caw ? "atomic CAW" : "no-CAW fallback");

    /* Count the thread in BEFORE creating it: a thread that finishes
     * while the spawn loop is still running must not drive the counter
     * to zero early and let the wait below return under us. */
    for (i = 0; i < n; i++) {
        struct task_struct *t;

        atomic_inc(&ctx.running);
        atomic_inc(&ctx.refs); /* the thread's own, dropped as it exits */
        t = kthread_run(cetrafs_cas_stress_thread, ctxp, "cetrafs_cas%u", i);
        if (IS_ERR(t)) {
            atomic_dec(&ctx.refs);
            atomic_dec(&ctx.running);
            break;
        }
        started++;
    }

    wait_event(ctx.done, atomic_read(&ctx.running) == 0);

    bh = cetrafs_bread_uncached_retry(sb, lba);
    if (bh) {
        memcpy(&final, bh->b_data + CETRAFS_CAS_SELFTEST_OFF, sizeof(final));
        brelse(bh);
    }

    {
        int ok = atomic_read(&ctx.ok_count);
        int err = atomic_read(&ctx.err_count);

        pr_info("CAS stress: %u threads, %d successful increments, %d errors, counter reads %u, %llu miscompares\n",
                started, ok, err, final, (unsigned long long) (cetrafs_cas_miscompare_count() - mc_before));
        if ((int) final == ok)
            pr_info("CAS stress: PASSED -- no lost updates (%s path)\n",
                    have_caw ? "atomic CAW" : "serialised no-CAW fallback");
        else
            pr_err("CAS stress: FAILED -- %d increments succeeded but the counter reads %u (%d lost)\n", ok, final,
                   ok - (int) final);
    }

    cetrafs_cas_record(sb, lba, cetrafs_cas_stress_zero, NULL);
#undef ctx
    cetrafs_cas_stress_put(ctxp);
}

/* Records live in region 0 of their own block -- the common case. */
int cetrafs_cas_record(struct super_block *sb, u64 fs_lba, cetrafs_cas_fn mutate, void *priv)
{
    return cetrafs_cas_region_seeded(sb, fs_lba, 0, NULL, 0, mutate, priv);
}

/*
 * cetrafs_cas_record() for a swap nothing may abandon: the journal
 * flag's flip (entries committed while it still reads CLEAN are skipped
 * by the next replay) and the park that follows a fence (it is what
 * makes the fenced node's late DIRTY flip miscompare). Every other CAS
 * may be interrupted by a fatal signal while it waits for a multipath
 * path to be resolved (-EINTR, nothing issued); this one waits that
 * resolution out, bounded as before.
 */
int cetrafs_cas_record_nointr(struct super_block *sb, u64 fs_lba, cetrafs_cas_fn mutate, void *priv)
{
    return cetrafs_cas_region_seeded_publish(sb, fs_lba, 0, NULL, 0, mutate, priv, /*sole_region=*/false,
                                             /*killable=*/false);
}
