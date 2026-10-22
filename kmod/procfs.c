// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * procfs.c -- /proc/fs/cetrafs/<device>/ introspection.
 *
 * Read-only diagnostic text dumps, one subdirectory per mounted instance
 * (named by sb->s_id, the device's informational name -- same
 * /proc/fs/<fstype>/<device> convention ext4/nfsd/jbd2 use). Chosen over
 * /sys/fs/ per the original design discussion: sysfs's
 * one-value-per-attribute convention is a worse fit for multi-line text
 * dumps like these (the same reason ext4 exposes mb_groups this way
 * rather than through sysfs). Three files per mount, all read-only:
 *
 *  - info: topology + live usage -- block size, total/free blocks and
 *    inodes, ZG/BG counts and sizes, this node's own ZG/BG ownership.
 *  - properties: static format/feature info -- on-disk version, feature
 *    flags, and whether the underlying device actually supports SCSI PR
 *    (i.e. whether real clustering safety is available on this mount).
 *  - cluster: the live Node Registry -- every non-FREE row's UUID,
 *    state, hb_seq, last_seen, and whether this node currently considers
 *    it stale.
 *  - controls: the one WRITABLE file -- per-mount switches an operator
 *    can flip on a live mount. See cetrafs_proc_controls_write().
 *
 * The read-only three are each a single seq_file view
 * (proc_create_single_data()) with 'sb' as private data -- no state of
 * their own beyond the live superblock they read fresh on every open,
 * so there is nothing to keep in sync.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/fs.h>
#include <linux/moduleparam.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>

#include "kmod.h"

/* /proc/fs/cetrafs itself -- created once at module init (kmod.c), torn
 * down at module exit. Holds one subdirectory per mounted instance. */
static struct proc_dir_entry *cetrafs_proc_root;

int cetrafs_proc_module_init(void)
{
    cetrafs_proc_root = proc_mkdir("fs/cetrafs", NULL);
    if (!cetrafs_proc_root) {
        pr_err("failed to create /proc/fs/cetrafs\n");
        return -ENOMEM;
    }
    return 0;
}

void cetrafs_proc_module_exit(void)
{
    /* Recursive -- harmless even if a mount's subdirectory somehow
     * outlived its umount, which shouldn't be reachable: the VFS won't
     * let this module unload while any filesystem instance (and thus
     * its proc_mount_exit() call) is still outstanding. */
    proc_remove(cetrafs_proc_root);
    cetrafs_proc_root = NULL;
}

struct cetrafs_proc_mount {
    struct proc_dir_entry *dir;
};

/* Gap between whole-volume foreign-descriptor sweeps. Tunable because
 * statfs_no_bg_sweep.sh and statfs_keeps_bg_cache.sh OBSERVE statfs via
 * this file's counters -- rate-limiting it unconditionally made those
 * suites blind, which is a worse failure than the cost it saves. At 0
 * every read sweeps, which is what they set. */
static unsigned int cetrafs_bg_sweep_min_secs = CETRAFS_BG_SWEEP_MIN_SECS;
module_param_named(bg_sweep_min_secs, cetrafs_bg_sweep_min_secs, uint, 0644);
MODULE_PARM_DESC(bg_sweep_min_secs, "minimum seconds between foreign BG descriptor sweeps (0 = every info read)");

static int cetrafs_proc_info_show(struct seq_file *m, void *v)
{
    struct super_block *sb = m->private;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 free_inodes = 0, total_data_blocks = 0, free_data_blocks = 0;
    u32 zg_count, bg_count, my_node_id, z;
    int ret, stats_err = 0;

    if (!raw_sb)
        return -EINVAL;

    zg_count = le32_to_cpu(raw_sb->zone_group_count);
    bg_count = le32_to_cpu(raw_sb->block_group_count);

    /*
     * The answers that need NO device I/O come first, and nothing below
     * may abort before they are printed.
     *
     * This file used to print the live free-space figures first and
     * return their error, so a device that had gone away made the WHOLE
     * file -EIO -- and `fenced:` and `write_ready:` are exactly what an
     * operator wants when the device has gone away. Both are answerable
     * from memory. Found by pulling the device out from under a live
     * mount; nothing else reaches it.
     */
    if (cetrafs_sb_get_node_id(sb, &my_node_id))
        my_node_id = CETRAFS_NODE_ID_NONE;
    seq_printf(m, "this_node_id: %u\n", my_node_id);
    /* Mounting with zero owned ZGs is normal (every ZG already claimed
     * by a live peer), not a mount failure -- but it means this node
     * can't allocate a single new block until one frees up. Surfaced
     * here so that's visible without reading dmesg or inferring it
     * from a failed write. */
    seq_printf(m, "write_ready: %s\n", cetrafs_sb_owns_any_zg(sb) ? "yes" : "no");
    /* The cross-node exclusive open lock -- off means this mount claims no
     * lock and refuses no open (nofilelock; set at mount, fixed for life). */
    seq_printf(m, "file_lock: %s\n", cetrafs_sb_file_lock_enabled(sb) ? "on" : "off");
    seq_printf(m, "fenced: %s\n", cetrafs_sb_is_fenced(sb) ? "yes" : "no");
    /* The exact value fs.c's fill_super() stamped into sb->s_maxbytes --
     * see cetrafs_compute_max_file_size() (zonegroup.c) for the formula.
     * Read straight off the live super_block, not recomputed here, so
     * this always reflects what the VFS is actually enforcing. */
    seq_printf(m, "max_file_size_bytes: %lld\n", (long long) sb->s_maxbytes);

    seq_printf(m, "block_size: %u\n", le32_to_cpu(raw_sb->block_size));
    seq_printf(m, "total_blocks: %llu\n", (unsigned long long) le64_to_cpu(raw_sb->total_blocks));
    seq_printf(m, "zone_group_count: %u\n", zg_count);
    seq_printf(m, "block_group_count: %u\n", bg_count);
    seq_printf(m, "bg_size_blocks: %llu\n", (unsigned long long) le64_to_cpu(raw_sb->bg_size_blocks));

    seq_printf(m, "inodes_count: %u\n", le32_to_cpu(raw_sb->inodes_count));
    ret = cetrafs_sb_get_free_inodes(sb, &free_inodes);
    if (ret)
        seq_printf(m, "free_inodes: unavailable (%d)\n", ret);
    else
        seq_printf(m, "free_inodes: %llu\n", (unsigned long long) free_inodes);

    bool sweep_foreign = false;

    /*
     * Refresh the FOREIGN descriptors at most once per
     * CETRAFS_BG_SWEEP_MIN_SECS, not on every read of this file.
     *
     * Each refresh invalidates a descriptor, so the next read of it is
     * a 4 KiB device read plus a CRC. This node owns a single Zone
     * Group of sixteen, so a sweep drops ~1900 of 2047 descriptors --
     * and anything polling this file (the Proxmox storage plugin, a
     * monitoring loop, me with a diagnostic one-liner) made the whole
     * volume's descriptors cold over and over. Measured on the
     * deployment LUN as bg_desc_refreshed climbing from 3840 to 13440
     * while a guest was writing: ~9600 device reads competing with it
     *. docs/PERFORMANCE.md invariant 3 predicted exactly
     * this and named pvestatd as the trigger.
     *
     * The numbers below are explicitly a cache -- free counts accrue in
     * memory and reconcile at ownership boundaries -- so serving a few
     * seconds of staleness to a status poll costs nothing that matters,
     * while re-reading two thousand descriptors per poll costs the
     * allocator its warm cache mid-stream.
     */
    {
        unsigned long now = jiffies;
        unsigned long last = cetrafs_sb_bg_sweep_last(sb);

        if (!last || !cetrafs_bg_sweep_min_secs ||
            time_after(now, last + cetrafs_bg_sweep_min_secs * HZ)) {
            cetrafs_sb_set_bg_sweep_last(sb, now);
            sweep_foreign = true;
        }
    }

    for (z = 0; z < bg_count; z++) {
        u64 total, free;

        if (sweep_foreign)
            cetrafs_bg_desc_refresh_foreign(sb, z);
        ret = cetrafs_bg_data_block_stats(sb, z, &total, &free);
        if (ret) {
            stats_err = ret;
            break;
        }
        total_data_blocks += total;
        free_data_blocks += free;
    }
    if (stats_err) {
        seq_printf(m, "total_data_blocks: unavailable (%d)\n", stats_err);
        seq_printf(m, "free_data_blocks: unavailable (%d)\n", stats_err);
    } else {
        seq_printf(m, "total_data_blocks: %llu\n", (unsigned long long) total_data_blocks);
        seq_printf(m, "free_data_blocks: %llu\n", (unsigned long long) free_data_blocks);
    }

    /*
     * How many compare-and-swaps this module has had REJECTED by the
     * device because the on-disk image had changed under them -- i.e.
     * how much genuine cross-node contention this host is seeing. Each
     * one was retried against a fresh image, so a rising count is
     * healthy traffic, not errors; a count stuck at zero on a volume
     * two nodes are both working means they are not actually meeting.
     *
     * Module-wide rather than per-mount (the counter lives in caw.c and
     * the primitive is shared), which is why it is not labelled with
     * this device.
     */
    seq_printf(m, "cas_miscompares: %llu\n", cetrafs_cas_miscompare_count());
    seq_printf(m, "cas_ops: %llu\n", cetrafs_cas_op_count());
    seq_printf(m, "record_writes: %llu\n", cetrafs_record_write_count());
    seq_printf(m, "pending_free_appends: %llu\n", cetrafs_pending_free_append_count());
    seq_printf(m, "foreign_free_leaks: %llu\n", cetrafs_foreign_free_leak_count());
    seq_printf(m, "scrub_reclaimed: %llu\n", cetrafs_scrub_reclaimed_count());
    seq_printf(m, "scrub_orphan_inodes_reclaimed: %llu\n", cetrafs_scrub_orphans_count());
    seq_printf(m, "scrub_cycles: %llu\n", cetrafs_scrub_cycle_count());
    seq_printf(m, "scrub_last_run_unix: %llu\n", cetrafs_scrub_last_start_unix());
    seq_printf(m, "scrub_last_run_ms: %llu\n", cetrafs_scrub_last_duration_ms());
    /* Descriptor sweeps that LEFT this node's own BG descriptors cached
     * vs ones they forced back to the device. kept must rise on any
     * volume this node owns ZGs on -- it is what keeps
     * cetrafs_alloc_pick_bg()'s per-block reads off the wire. */
    seq_printf(m, "bg_desc_kept: %llu\n", cetrafs_bg_desc_kept_count());
    seq_printf(m, "bg_desc_refreshed: %llu\n", cetrafs_bg_desc_refreshed_count());
    /* Allocation-cursor hits vs full owned-BG scans in
     * cetrafs_alloc_pick_bg(), which runs once per allocated block.
     * scan climbing in step with cursor means the per-block path is
     * reading (and CRC-ing) every owned BG descriptor again. */
    seq_printf(m, "bg_pick_cursor: %llu\n", cetrafs_bg_pick_cursor_count());
    seq_printf(m, "bg_pick_scan: %llu\n", cetrafs_bg_pick_scan_count());
    /* Existing-block mappings vs the blocks they covered. Equal means
     * every caller is coming back per 4 KiB; blocks > calls means
     * cetrafs_get_block() is answering with contiguous runs. */
    seq_printf(m, "map_calls: %llu\n", cetrafs_map_call_count());
    seq_printf(m, "map_blocks: %llu\n", cetrafs_map_block_count());
    seq_printf(m, "zg_pending_deltas: %u\n", cetrafs_sb_pending_zg_deltas(sb));
    seq_printf(m, "journal_replays: %llu\n", cetrafs_journal_replay_count());
    seq_printf(m, "journal_replay_declines: %llu\n", cetrafs_journal_replay_decline_count());
    seq_printf(m, "file_cache_drops: %llu\n", cetrafs_file_cache_drop_count());
    seq_printf(m, "journal_writes: %llu\n", cetrafs_journal_write_count());
    seq_printf(m, "bg_geom_reads: %llu\n", cetrafs_bg_geom_read_count());
    seq_printf(m, "pf_drains: %llu\n", cetrafs_pf_drain_count());
    seq_printf(m, "pf_full_scans: %llu\n", cetrafs_pf_full_scans_count());
    seq_printf(m, "pf_drain_blocks: %llu\n", cetrafs_pf_drain_blocks_count());
    seq_printf(m, "bg_recounts: %llu\n", cetrafs_bg_recount_count());
    seq_printf(m, "pf_drop_runs: %llu\n", cetrafs_pf_drop_runs_count());
    seq_printf(m, "pf_drop_blocks: %llu\n", cetrafs_pf_drop_blocks_count());
    seq_printf(m, "giveback_blocks: %llu\n", cetrafs_giveback_block_count());
    seq_printf(m, "tree_blocks: %llu\n", cetrafs_tree_block_count());
    seq_printf(m, "tree_reads: %llu\n", cetrafs_tree_read_count());
    seq_printf(m, "file_cache_reconciles: %llu\n", cetrafs_file_cache_reconcile_count());
    seq_printf(m, "journal_replay_applied: %llu\n", cetrafs_journal_replay_applied_count());
    seq_printf(m, "journal_replay_skipped: %llu\n", cetrafs_journal_replay_skipped_count());
    /* Nonzero means replay caught an entry whose target another node had
     * already rewritten and refused to roll it back: a cross-node
     * corruption prevented. Worth alerting on. */
    seq_printf(m, "journal_replay_refused: %llu\n", cetrafs_journal_replay_refused_count());
    seq_printf(m, "journal_replay_torn: %llu\n", cetrafs_journal_replay_torn_count());

    seq_puts(m, "\nzone_groups:\n");
    for (z = 0; z < zg_count; z++) {
        struct cetrafs_zg_info info;

        ret = cetrafs_zg_get_info(sb, z, &info);
        if (ret) {
            /* Degrade, do not abort: the fields above this point are
             * answerable from memory and must survive a device that has
             * gone away. */
            seq_printf(m, "  zg %u: unavailable (%d)\n", z, ret);
            continue;
        }

        seq_printf(m, "  zg %u: owner=", z);
        if (info.owner_node_id == CETRAFS_NODE_ID_NONE)
            seq_puts(m, "none");
        else
            seq_printf(m, "%u%s", info.owner_node_id, info.owner_node_id == my_node_id ? " (this node)" : "");
        /* No per-ZG journal size anymore -- journals are per-node since
         * the per-node journal design (see the superblock's
         * node_journal_start/node_journal_blocks). */
        seq_printf(m, " first_bg=%u bg_count=%u free_data_blocks=%llu\n", info.first_bg_id, info.bg_count,
                   (unsigned long long) info.free_data_blocks);
    }

    return 0;
}

static int cetrafs_proc_properties_show(struct seq_file *m, void *v)
{
    struct super_block *sb = m->private;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 incompat;
    bool first = true;

    if (!raw_sb)
        return -EINVAL;

    incompat = le64_to_cpu(raw_sb->features_incompat);

    seq_printf(m, "version: 0x%04x\n", le16_to_cpu(raw_sb->version));
    seq_printf(m, "block_size: %u\n", le32_to_cpu(raw_sb->block_size));
    seq_printf(m, "cluster_id: %u\n", le32_to_cpu(raw_sb->cluster_id));
    seq_printf(m, "features_compat: 0x%llx\n", (unsigned long long) le64_to_cpu(raw_sb->features_compat));
    seq_printf(m, "features_ro_compat: 0x%llx\n", (unsigned long long) le64_to_cpu(raw_sb->features_ro_compat));

    seq_printf(m, "features_incompat: 0x%llx (", (unsigned long long) incompat);
#define SHOW_FEAT(bit, name)                               \
    do {                                                   \
        if (incompat & (bit)) {                            \
            seq_printf(m, "%s%s", first ? "" : ",", name); \
            first = false;                                 \
        }                                                  \
    } while (0)
    SHOW_FEAT(CETRAFS_FEAT_INCOMPAT_EXTENTS, "EXTENTS");
    SHOW_FEAT(CETRAFS_FEAT_INCOMPAT_GLOBAL_ITBL, "GLOBAL_ITBL");
    SHOW_FEAT(CETRAFS_FEAT_INCOMPAT_NODE_REGISTRY, "NODE_REGISTRY");
#undef SHOW_FEAT
    seq_puts(m, ")\n");

    /* Atomic compare-and-swap capability of the backing device -- the
     * ONLY cross-node mutual exclusion this filesystem has. A device
     * reporting available=no can only ever be mounted by one node at a
     * time, which fs.c's foreign-claim mount gate enforces. */
    {
        const struct cetrafs_caw_info *caw = cetrafs_sb_caw(sb);

        if (caw)
            seq_printf(m, "caw: class=%s logical_block_size=%u max_caw_blocks=%u available=%s\n",
                       cetrafs_caw_class_name(caw->klass), caw->logical_block_size, caw->max_caw_blocks,
                       cetrafs_sb_caw_available(sb) ? "yes" : "no");
    }

    /* The one dynamic fact here: whether *this* device's queue actually
     * supports SCSI PR, which is what phase 10's ZG-claiming mutex (and
     * phase 9's node-registration claim) needs to be more than a
     * best-effort check -- see pr.c/zonegroup.c. */

    return 0;
}

static int cetrafs_proc_cluster_show(struct seq_file *m, void *v)
{
    struct super_block *sb = m->private;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 count, idx, my_node_id;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    count = le32_to_cpu(raw_sb->node_table_count);

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    for (idx = 0; idx < count; idx++) {
        cetrafs_node_entry_t ne;
        bool stale = false;
        const u8 *u;

        ret = cetrafs_node_get_entry(sb, idx, &ne);
        if (ret) {
            /* Degrade per row rather than failing the file: a device
             * that has gone away must not make the cluster view
             * unreadable, and an unreadable row IS information. -EIO
             * means every remaining row will fail the same way. */
            seq_printf(m, "node %u: unreadable (%d)\n", idx, ret);
            if (ret == -EIO)
                break;
            continue;
        }
        if (ne.state == CETRAFS_NODE_STATE_FREE)
            continue;

        ret = cetrafs_node_is_stale(sb, idx, &stale);
        if (ret)
            return ret;

        u = ne.node_uuid;
        seq_printf(m,
                   "node %u: state=%s uuid=%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x "
                   "hb_seq=%llu last_seen=%llu label=%s stale=%s%s\n",
                   idx, cetrafs_le32(ne.state) == CETRAFS_NODE_STATE_REGISTERED ? "REGISTERED" : "UNKNOWN", u[0], u[1], u[2], u[3],
                   u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15],
                   (unsigned long long) cetrafs_le64(ne.hb_seq), (unsigned long long) cetrafs_le64(ne.last_seen), ne.label, stale ? "yes" : "no",
                   idx == my_node_id ? " (this node)" : "");
    }

    return 0;
}

/*
 * controls -- the one writable file. Reads back as "key: value" lines;
 * accepts "key=value" or "key value", one setting per write.
 *
 * Both switches exist for the same reason: the defragmenter pins a
 * file's cross-node EXCLUSIVE lock while it relocates, so a peer is
 * refused ANY open -- reads included -- for the duration. That is
 * accepted for a VM datastore, where one node owns an image anyway, and
 * wrong for a volume where it is not, so it has to be switchable on a
 * live mount rather than at build or mount time.
 *
 *   defrag       off stops defragmentation entirely, the ioctl
 *                included -- the only setting under which nothing on
 *                this mount pins that lock for an optimisation.
 *   auto_defrag  off stops the background janitor alone; a deliberate
 *                defrag.cetra run still works.
 *
 * Per MOUNT, deliberately: the module params are module-wide, and one
 * node may own the images on this volume while another only reads them.
 * Not persisted -- a switch that survived a remount would be a mount
 * option or an on-disk flag, and this is neither.
 */
static int cetrafs_proc_controls_show(struct seq_file *m, void *v)
{
    struct super_block *sb = m->private;

    seq_printf(m, "defrag: %s\n", cetrafs_sb_defrag_enabled(sb) ? "on" : "off");
    seq_printf(m, "auto_defrag: %s\n", cetrafs_sb_auto_defrag_enabled(sb) ? "on" : "off");
    seq_printf(m, "hb_interval_secs: %u\n", cetrafs_sb_hb_interval_secs(sb));
    seq_printf(m, "stale_secs: %u\n", cetrafs_sb_stale_secs(sb));
    return 0;
}

static int cetrafs_proc_controls_open(struct inode *inode, struct file *file)
{
    return single_open(file, cetrafs_proc_controls_show, pde_data(inode));
}

static int cetrafs_proc_parse_bool(const char *val, bool *out)
{
    if (!strcmp(val, "on") || !strcmp(val, "1") || !strcmp(val, "yes") || !strcmp(val, "true")) {
        *out = true;
        return 0;
    }
    if (!strcmp(val, "off") || !strcmp(val, "0") || !strcmp(val, "no") || !strcmp(val, "false")) {
        *out = false;
        return 0;
    }
    return -EINVAL;
}

static ssize_t cetrafs_proc_controls_write(struct file *file, const char __user *ubuf, size_t len, loff_t *ppos)
{
    struct super_block *sb = pde_data(file_inode(file));
    char buf[64];
    char *key, *val;
    bool on;

    /* An unparseable write changes NOTHING: the value is decoded and the
     * key recognised before anything is set, so a typo cannot leave half
     * a setting applied. */
    if (len == 0 || len >= sizeof(buf))
        return -EINVAL;
    if (copy_from_user(buf, ubuf, len))
        return -EFAULT;
    buf[len] = '\0';
    key = strim(buf);

    val = strpbrk(key, "= \t");
    if (!val)
        return -EINVAL;
    *val++ = '\0';
    val = strim(val);
    key = strim(key);

    /* The integer settings first: cluster TIMING, where a bool parse
     * would be nonsense.
     *
     * Bounded on both sides. Zero would mean "beat never" or "nothing
     * is ever stale", and a staleness window shorter than a couple of
     * beats declares a healthy peer dead on ordinary jitter -- the very
     * failure the peer-advertised floor exists to prevent, which is
     * still applied on top of whatever is set here. */
    if (!strcmp(key, "hb_interval_secs") || !strcmp(key, "stale_secs")) {
        unsigned int v;

        if (kstrtouint(val, 10, &v))
            return -EINVAL;

        if (!strcmp(key, "hb_interval_secs")) {
            /* Range, then the ratio against the CURRENT stale_secs. The
             * cross-field check is order-dependent on purpose: to widen
             * the beat, raise stale_secs first; to narrow it, narrow the
             * beat first. A one-knob interface would avoid that, but two
             * knobs match what ctest and the info file already use. */
            if (v < CETRAFS_HB_INTERVAL_MIN_SECS || v > CETRAFS_HB_INTERVAL_MAX_SECS) {
                pr_warn("%s: controls: hb_interval_secs=%u out of range [%u,%u]\n", sb->s_id, v,
                        CETRAFS_HB_INTERVAL_MIN_SECS, CETRAFS_HB_INTERVAL_MAX_SECS);
                return -EINVAL;
            }
            if (cetrafs_sb_stale_secs(sb) < (unsigned int) CETRAFS_STALE_MIN_BEATS * v) {
                pr_warn("%s: controls: hb_interval_secs=%u would leave stale_secs=%u below %u beats; "
                        "raise stale_secs first\n",
                        sb->s_id, v, cetrafs_sb_stale_secs(sb), CETRAFS_STALE_MIN_BEATS);
                return -EINVAL;
            }
            cetrafs_sb_set_hb_interval_secs(sb, v);
        } else {
            if (v < CETRAFS_STALE_MIN_SECS || v > CETRAFS_STALE_MAX_SECS) {
                pr_warn("%s: controls: stale_secs=%u out of range [%u,%u]\n", sb->s_id, v, CETRAFS_STALE_MIN_SECS,
                        CETRAFS_STALE_MAX_SECS);
                return -EINVAL;
            }
            if (v < (unsigned int) CETRAFS_STALE_MIN_BEATS * cetrafs_sb_hb_interval_secs(sb)) {
                pr_warn("%s: controls: stale_secs=%u is below %u x hb_interval_secs=%u\n", sb->s_id, v,
                        CETRAFS_STALE_MIN_BEATS, cetrafs_sb_hb_interval_secs(sb));
                return -EINVAL;
            }
            cetrafs_sb_set_stale_secs(sb, v);
        }
        pr_info("%s: controls: %s -> %u\n", sb->s_id, key, v);
        return len;
    }

    if (cetrafs_proc_parse_bool(val, &on))
        return -EINVAL;

    if (!strcmp(key, "defrag"))
        cetrafs_sb_set_defrag_enabled(sb, on);
    else if (!strcmp(key, "auto_defrag"))
        cetrafs_sb_set_auto_defrag_enabled(sb, on);
    else
        return -EINVAL;

    pr_info("%s: controls: %s -> %s\n", sb->s_id, key, on ? "on" : "off");
    return len;
}

static const struct proc_ops cetrafs_proc_controls_ops = {
    .proc_open = cetrafs_proc_controls_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
    .proc_write = cetrafs_proc_controls_write,
};

/*
 * One subdirectory per mounted instance, named after sb->s_id (the
 * device's informational name -- already set by the VFS by the time
 * fill_super() runs, for a single-device filesystem like this one).
 * Called from fs.c's fill_super() once this node's identity/ZG
 * ownership/journal state are all established, since every show()
 * function above depends on them; torn down from cetrafs_free_sb_info(),
 * before anything else, so no reader can be mid-read against state
 * that's about to be freed.
 */
int cetrafs_proc_mount_init(struct super_block *sb, struct cetrafs_proc_mount **out_pm)
{
    struct cetrafs_proc_mount *pm;

    pm = kzalloc(sizeof(*pm), GFP_KERNEL);
    if (!pm)
        return -ENOMEM;

    pm->dir = proc_mkdir(sb->s_id, cetrafs_proc_root);
    if (!pm->dir) {
        kfree(pm);
        return -ENOMEM;
    }

    if (!proc_create_single_data("info", 0444, pm->dir, cetrafs_proc_info_show, sb) ||
        !proc_create_single_data("properties", 0444, pm->dir, cetrafs_proc_properties_show, sb) ||
        !proc_create_single_data("cluster", 0444, pm->dir, cetrafs_proc_cluster_show, sb) ||
        !proc_create_data("controls", 0644, pm->dir, &cetrafs_proc_controls_ops, sb)) {
        proc_remove(pm->dir);
        kfree(pm);
        return -ENOMEM;
    }

    *out_pm = pm;
    return 0;
}

void cetrafs_proc_mount_exit(struct cetrafs_proc_mount *pm)
{
    if (!pm)
        return;

    proc_remove(pm->dir); /* recursive: removes the files under it too */
    kfree(pm);
}
