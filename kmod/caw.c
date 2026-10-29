// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * caw.c -- generic cross-transport COMPARE AND WRITE (atomic test-and-set)
 * primitive + capability discovery.
 *
 * STANDALONE: nothing in the filesystem calls these yet.
 * This is the foundation for a future move of the cluster-coordination
 * hot paths from the device-wide SCSI PR mutex to lock-free per-record
 * compare-and-swap. Built and probed now so the
 * primitive and the hardware capability are known before anything is
 * rebuilt on top of them.
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
 *    kernel exposes NO module-callable API for fused NVMe passthrough
 *    (nvme_submit_sync_cmd and friends are internal to the nvme driver,
 *    unexported, and generic passthrough cannot express the fused
 *    linkage). So the NVMe backend is a deliberate, documented stub
 *    returning -EOPNOTSUPP -- implementing it needs either an nvme-driver
 *    change to export a fused primitive or an in-tree home for this code.
 *    The real deployment target (an FC/iSCSI LUN) presents SCSI anyway.
 *
 * Block size: the atomic unit is one LOGICAL block (bdev_logical_block_
 * size()) -- 512 on a 512-logical LUN, 4096 on a 4Kn one. The filesystem
 * block size (4096) is unrelated; a caller that wants an atomic record
 * update supplies a logical-block-sized, logical-block-aligned region.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
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
module_param_named(caw_fail_path_once, cetrafs_caw_fail_path_once, bool, 0644);
MODULE_PARM_DESC(caw_fail_path_once, "TEST ONLY: fail the next CAW issued over a dm path, once");

static bool cetrafs_caw_fail_discover;
module_param_named(caw_fail_discover, cetrafs_caw_fail_discover, bool, 0644);
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
 * MISCOMPARE (another writer changed the region), -EIO on other failure. */
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

    buf = kmalloc((size_t) half * 2, GFP_KERNEL);
    if (!buf)
        return -ENOMEM;
    sense = kzalloc(SCSI_SENSE_BUFFERSIZE, GFP_KERNEL);
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
     * (now-stale) compare image. The retries below are ours, and only
     * for conditions where the target states the command was NOT
     * executed:
     *
     *  - UNIT ATTENTION: a one-shot notification, cleared by the act of
     *    reporting it, and the command it aborted never ran. On a
     *    two-node cluster these are routine rather than exceptional:
     *    ASC 0x2A covers RESERVATIONS PREEMPTED / RESERVATIONS RELEASED
     *    / REGISTRATIONS PREEMPTED, i.e. exactly what the OTHER node's
     *    PR and CAW traffic generates ("sd 30:0:0:1: Parameters
     *    changed" in dmesg). Treating one as -EIO failed a plain
     *    create() with EIO on real two-node hardware.
     *  - ABORTED COMMAND: the standard retryable transport error.
     *
     * Retrying is safe for CAW specifically because the command did not
     * execute: the compare image is still the image we decided against,
     * so a retry is the same atomic compare-and-swap, not a blind
     * re-write. Anything else -- a real medium error, a reservation
     * conflict -- still fails immediately.
     */
    for (attempt = 0; attempt <= CETRAFS_CAW_RETRIES; attempt++) {
        memset(sense, 0, SCSI_SENSE_BUFFERSIZE);
        memset(&sshdr, 0, sizeof(sshdr));

                if (lba >= 16512 && lba < 16520)
            ctrace("CAWPATH lba=%llu via %s\n", (unsigned long long) lba,
                    dev_name(&sdev->sdev_gendev));
        ret = scsi_execute_cmd(sdev, cdb, REQ_OP_DRV_OUT, buf, half * 2, CETRAFS_CAW_TIMEOUT_JIFFIES, 0, &args);
        if (!ret)
            break;

        if (scsi_sense_valid(&sshdr)) {
            if (sshdr.sense_key == MISCOMPARE) {
                ret = -EBUSY;
                break;
            }
            if (sshdr.sense_key == UNIT_ATTENTION || sshdr.sense_key == ABORTED_COMMAND) {
                if (attempt < CETRAFS_CAW_RETRIES) {
                    pr_info_ratelimited("CAW lba=%llu retrying after sense key 0x%x asc=0x%02x ascq=0x%02x\n",
                                        (unsigned long long) lba, sshdr.sense_key, sshdr.asc, sshdr.ascq);
                    continue;
                }
                pr_err("CAW lba=%llu still failing after %d retries (sense key 0x%x asc=0x%02x ascq=0x%02x)\n",
                       (unsigned long long) lba, CETRAFS_CAW_RETRIES, sshdr.sense_key, sshdr.asc, sshdr.ascq);
            } else {
                /* Anything else -- RESERVATION CONFLICT, a medium
                 * error, ILLEGAL REQUEST -- is fatal to this swap. Say
                 * what the target actually reported: without this the
                 * caller sees a bare -EIO (which surfaces as EIO from an
                 * ordinary create()) and there is nothing anywhere to
                 * debug it from. */
                pr_err_ratelimited("CAW lba=%llu failed: sense key 0x%x asc=0x%02x ascq=0x%02x\n",
                                   (unsigned long long) lba, sshdr.sense_key, sshdr.asc, sshdr.ascq);
            }
        } else {
            pr_err_ratelimited("CAW lba=%llu failed with no valid sense (scsi_execute_cmd returned %d)\n",
                               (unsigned long long) lba, ret);
        }
        ret = -EIO;
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

    sdev = cetrafs_caw_get_sdev(bdev);
    if (!sdev)
        sdev = cetrafs_dmpath_sdev(bdev); /* dm (multipath): probe via a path -- see dmpath.c */
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
        rc = scsi_get_vpd_page(sdev, 0xB0, vpd, 64);
        if (rc == 0) {
            out->max_caw_blocks = vpd[5];
        } else {
            /* The device did not give us Block Limits. That genuinely
             * may mean "no such page" on an old target, so it is not an
             * error -- but it is said out loud, because the alternative
             * reading (a transient failure on a device that does have
             * CAW) silently downgrades the safety model. */
            pr_warn(
                "CAW: %s did not return the Block Limits VPD page (%d) -- "
                "treating as no atomic CAW\n",
                bdev->bd_disk->disk_name, rc);
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
int cetrafs_caw(struct block_device *bdev, u64 lba, unsigned int nblocks, const void *compare, const void *write_data)
{
    struct scsi_device *sdev;
    unsigned int lbs;

    if (!bdev || !bdev->bd_disk || !compare || !write_data)
        return -EINVAL;
    if (nblocks == 0)
        return -EINVAL;
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
        return ret;
    }

    /*
     * Not SCSI itself: a device-mapper node, i.e. the multipath case.
     * Issue over a path underneath (dmpath.c), and on a TRANSPORT error
     * -- never on -EBUSY, which is a MISCOMPARE and a legitimate lost
     * race -- drop that path and retry once on another. Without the
     * retry a single path failure surfaces as a failed claim, and since
     * heartbeat renewal is itself a compare-and-swap, a path that stays
     * broken gets this node declared dead and fenced by its peers.
     */
    {
        unsigned int attempt;
        int ret = -EOPNOTSUPP;

        for (attempt = 0; attempt < 2; attempt++) {
            sdev = cetrafs_dmpath_sdev(bdev);
            if (!sdev)
                break;

            if (cetrafs_caw_fail_path_once) { /* test knob, see its MODULE_PARM_DESC */
                cetrafs_caw_fail_path_once = false;
                ret = -EIO;
            } else {
                ret = cetrafs_caw_scsi(sdev, lba, nblocks, compare, write_data, lbs);
            }

            if (ret != -EIO) { /* success, or MISCOMPARE, or a non-path error */
                scsi_device_put(sdev);
                return ret;
            }

            cetrafs_dmpath_failed(bdev, sdev);
            scsi_device_put(sdev);
        }
        if (ret != -EOPNOTSUPP)
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
 * another node changed the region first. This is the replacement shape
 * for every "take the PR mutex, read-decide-write, release" claim in
 * the codebase -- same correctness, no device-wide
 * serialization, one round trip.
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
static void cetrafs_cas_flush_block(struct super_block *sb, u64 fs_lba)
{
    struct buffer_head *bh = sb_find_get_block(sb, fs_lba);

    if (!bh)
        return;
    if (buffer_dirty(bh))
        sync_dirty_buffer(bh);
    brelse(bh);
}

/* Size of one CAS region: the device's atomic unit where there is one,
 * else the format's hot-sector rule. A filesystem block holds
 * CETRAFS_BLOCK_SIZE / this many regions, indexed from 0. */
unsigned int cetrafs_cas_region_size(struct super_block *sb)
{
    const struct cetrafs_caw_info *caw = cetrafs_sb_caw(sb);

    return cetrafs_sb_caw_available(sb) ? caw->logical_block_size : CETRAFS_HOT_SECTOR;
}

/*
 * CAS region 'region_idx' of filesystem block 'fs_lba'. Records live in
 * region 0 (the hot sector); bitmaps use every region of their blocks,
 * which is why this is indexed rather than fixed at the start.
 */
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
                             void *priv)
{
    struct buffer_head *bh = cetrafs_bread_uncached_retry(sb, fs_lba);
    int ret;

    if (!bh)
        return -EIO;
    memcpy(old, bh->b_data + off, region);
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

    bh = cetrafs_bread_retry(sb, fs_lba);
    if (!bh)
        return -EIO;
    /* The buffer-lock update protocol, same as every other in-place
     * modification in this module: a forced-fresh reader in another
     * thread takes this lock too, so without it one can clear uptodate
     * and re-read the block straight over these bytes. */
    cetrafs_bh_begin_update(bh);
    memcpy(bh->b_data + off, new, region);
    cetrafs_bh_end_update(bh);
    sync_dirty_buffer(bh);
    brelse(bh);
    return 0;
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
static int cetrafs_cas_region_seeded_impl(struct super_block *sb,
                                          u64 fs_lba,
                                          unsigned int region_idx,
                                          const void *seed,
                                          unsigned int seed_len,
                                          cetrafs_cas_fn mutate,
                                          void *priv,
                                          bool sole_region)
{
    const struct cetrafs_caw_info *caw = cetrafs_sb_caw(sb);
    bool have_caw = cetrafs_sb_caw_available(sb);
    unsigned int region = cetrafs_cas_region_size(sb);
    unsigned int off = region_idx * region;
    u64 dev_lba = have_caw ? fs_lba * (CETRAFS_BLOCK_SIZE / caw->logical_block_size) + region_idx : 0;
    u8 *old, *new;
    int attempt, ret;

    if (!mutate || off + region > CETRAFS_BLOCK_SIZE)
        return -EINVAL;

    cetrafs_cas_op_counted();

    old = kmalloc(region, GFP_KERNEL);
    new = kmalloc(region, GFP_KERNEL);
    if (!old || !new) {
        kfree(old);
        kfree(new);
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
        cetrafs_sb_cas_lock(sb);
        ret = cetrafs_cas_nocaw(sb, fs_lba, off, region, old, new, mutate, priv);
        cetrafs_sb_cas_unlock(sb);
        goto out;
    }

    for (attempt = 0; attempt < CETRAFS_CAS_RETRIES; attempt++) {
        struct buffer_head *bh;

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
        cetrafs_cas_flush_block(sb, fs_lba);

        if (attempt == 0 && seed && seed_len && seed_len <= region) {
            /* Trust the caller's image once. A stale one just fails the
             * CAW below and the next attempt reads fresh. */
            memcpy(old, seed, seed_len);
            if (seed_len < region)
                memset(old + seed_len, 0, region - seed_len);
        } else {
            bh = cetrafs_bread_uncached_retry(sb, fs_lba); /* see the no-CAW path above */
            if (!bh) {
                ret = -EIO;
                goto out;
            }
            memcpy(old, bh->b_data + off, region);
            brelse(bh);
        }

        memcpy(new, old, region);
        ret = mutate(new, region, priv);
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

        ret = cetrafs_caw(sb->s_bdev, dev_lba, 1, old, new);
        {
            /* DEBUG: every inode-bitmap CAS, with everything needed to
             * compare two nodes' wins for one bit: the exact device
             * sector, the attempt, the verdict, and the compare/write
             * bytes. The raw-path sg duel proved the array atomic even
             * cross-port, so if two nodes both win one bit the
             * divergence MUST be visible here. */
            const cetrafs_superblock_t *_rsb = cetrafs_sb_raw(sb);

            if (_rsb && fs_lba >= le64_to_cpu(_rsb->inode_bmap_start) &&
                fs_lba < le64_to_cpu(_rsb->inode_bmap_start) + le64_to_cpu(_rsb->inode_bmap_blocks))
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
            if (sole_region)
                cetrafs_cache_region_after_cas(sb, fs_lba, off, new, region);
            else
                cetrafs_invalidate_block(sb, fs_lba);
            goto out;
        }
        if (ret != -EBUSY)
            goto out; /* real transport error */

        atomic64_inc(&cetrafs_cas_miscompares);

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
    kfree(old);
    kfree(new);
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
    return cetrafs_cas_region_seeded_impl(sb, fs_lba, region_idx, seed, seed_len, mutate, priv,
                                          /*sole_region=*/false);
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
    return cetrafs_cas_region_seeded_impl(sb, fs_lba, 0, seed, seed_len, mutate, priv, /*sole_region=*/true);
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

        return cetrafs_cas_region_seeded_impl(sb, fs_lba, 0, NULL, 0, cetrafs_cas_fd_slice_mutate, &s,
                                              /*sole_region=*/true);
    }
    return cetrafs_cas_region_seeded_impl(sb, fs_lba, 1, seed, seed_len, mutate, priv, /*sole_region=*/true);
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
bool cetrafs_cas_selftest_enabled;
module_param_named(cas_selftest, cetrafs_cas_selftest_enabled, bool, 0644);
MODULE_PARM_DESC(
    cas_selftest,
    "test-only: run a CAS round-trip self-test against this node's own registry row at mount (diagnostic)");

#define CETRAFS_CAS_SELFTEST_OFF 256 /* inside the row block's zero padding */

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
            ret = cetrafs_caw(sb->s_bdev, dev_lba, 1, wrong, newer);
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

                    memcpy(seed, bh->b_data, region);
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
module_param_named(cas_stress, cetrafs_cas_stress_threads, uint, 0644);
MODULE_PARM_DESC(cas_stress,
                 "test-only: run N threads racing to increment one record through CAS at mount (diagnostic)");

static unsigned int cetrafs_cas_stress_iters = 50;
module_param_named(cas_stress_iters, cetrafs_cas_stress_iters, uint, 0644);
MODULE_PARM_DESC(cas_stress_iters, "test-only: increments per cas_stress thread (default 50)");

struct cetrafs_cas_stress_ctx {
    struct super_block *sb;
    u64 lba;
    atomic_t ok_count;
    atomic_t err_count;
    atomic_t running;
    wait_queue_head_t done;
    unsigned int iters;
};

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
    struct cetrafs_cas_stress_ctx ctx;
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
        t = kthread_run(cetrafs_cas_stress_thread, &ctx, "cetrafs_cas%u", i);
        if (IS_ERR(t)) {
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
}

/* Records live in region 0 of their own block -- the common case. */
int cetrafs_cas_record(struct super_block *sb, u64 fs_lba, cetrafs_cas_fn mutate, void *priv)
{
    return cetrafs_cas_region_seeded(sb, fs_lba, 0, NULL, 0, mutate, priv);
}
