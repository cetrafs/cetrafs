// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * lock.c -- the cross-node exclusive open-file lock.
 *
 * A whole-file, VMFS-style lock ("exactly one node has this open for
 * writing"), not POSIX byte-range fcntl. Opening for write while
 * unlocked claims CETRAFS_LOCK_EXCLUSIVE for this node; any open, read
 * or write, from a different node is then -ETXTBSY. Also home to
 * cetrafs_inode_info and the alloc_inode/free_inode plumbing, since the
 * local counts below need somewhere per-inode to live.
 *
 * Three rules, each guarding a real corruption window:
 *
 *  - The on-disk claim drops when this node's LAST local write-opener
 *    closes, not on any close by the holder. Two local write opens and a
 *    release on the first would let a peer claim the file out from under
 *    the second. Hence lock_writer_count.
 *
 *  - A foreign claim is -ETXTBSY only while the holder's heartbeat is
 *    fresh (node.c's cetrafs_node_is_stale()). Once stale the open
 *    proceeds and a write-open reclaims the lock, so a crashed node does
 *    not wedge the file forever.
 *
 *  - The write-side claim is a CAS plus a readback, like every other
 *    contested claim here. Without it two nodes can both read
 *    LOCK_NONE, both write their own ownership, and both believe they
 *    hold it. A miscompare or a readback mismatch returns -ETXTBSY.
 *    Read-only opens write nothing and never needed it; release only
 *    ever clears this node's own confirmed ownership.
 *
 * On this node's FIRST local open, cetrafs_lock_open() also refreshes
 * the in-core stat fields and drops stale page cache from the same fresh
 * read -- otherwise a file written and closed on one node reads back as
 * 0 bytes on the other. Only the first: a second local opener must keep
 * seeing this node's own unflushed writes.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/atomic.h>
#include <linux/buffer_head.h>
#include <linux/delay.h>
#include <linux/filelock.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/mutex.h>
#include <linux/pagemap.h>
#include <linux/slab.h>
#include <linux/timekeeping.h>

#include "kmod.h"

/* How many times the freshness gate decided a PEER had republished a
 * file and dropped this node's cached extent tree + page cache for it.
 * Expected to be ~0 on a node writing its own files: a nonzero rate
 * there means the gate is firing on our own publishes, which collapses
 * I/O to a continuous re-read of the LUN while nothing fails and dmesg
 * stays silent. That shipped once; file_cache_drops is how a test sees
 * it. */
static atomic64_t cetrafs_file_cache_drops = ATOMIC64_INIT(0);

/* Reconciles COMPLETED by the deferred worker. Every drop must be
 * followed by one: until it lands the inode reads every tree block
 * forced-fresh, which is a device round trip per read. A drops count
 * that outruns this one means inodes are stuck on the slow path --
 * which is exactly what "the VM is extremely slow" looked like. */
static atomic64_t cetrafs_file_cache_reconciles = ATOMIC64_INIT(0);

u64 cetrafs_file_cache_reconcile_count(void)
{
    return (u64) atomic64_read(&cetrafs_file_cache_reconciles);
}

/* Default-mount lock suspensions and resumptions (flock(LOCK_UN)/(LOCK_EX)
 * on a file this node auto-locked). A suspend that is never resumed shows
 * up here as a gap, which is what an orchestrator leaking handoff windows
 * looks like from outside. */
static atomic64_t cetrafs_lock_suspends = ATOMIC64_INIT(0);
static atomic64_t cetrafs_lock_resumes = ATOMIC64_INIT(0);

u64 cetrafs_lock_suspend_count(void)
{
    return (u64) atomic64_read(&cetrafs_lock_suspends);
}

u64 cetrafs_lock_resume_count(void)
{
    return (u64) atomic64_read(&cetrafs_lock_resumes);
}

/* Poll interval for a blocking flock(LOCK_EX) waiting on a held lock
 * (local or a peer). The on-disk claim is a non-blocking CAS, so blocking
 * is an interruptible retry, same as the cluster filesystems' glock wait. */
#define CETRAFS_FLOCK_POLL_MS 100

/*
 * Private per-inode state. lock_mutex serializes this node's own
 * concurrent local opens/closes of the same inode against each other
 * (so two local opens racing to claim the lock, or two local closes
 * racing to release it, can't both see a stale on-disk snapshot);
 * cross-node exclusion is the on-disk lock_mode/lock_owner_node
 * themselves, not this mutex -- it has no reach outside this node.
 */
struct cetrafs_inode_info {
    struct mutex lock_mutex;
    atomic_t lock_writer_count;     /* this node's local open-for-write refcount */
    atomic_t read_opener_count;     /* this node's local open-for-READ refcount:
                                     * the on-disk presence bit is set on 0->1 and cleared on
                                     * 1->0, so repeated local opens cost nothing on the wire */
    atomic_t lock_local_open_count; /* this node's local open refcount, read+write alike */
    /*
     * Speculative allocation reservation: a contiguous run claimed in
     * the bitmap ahead of need and handed out one block at a time by
     * cetrafs_get_block() without re-entering the allocator.
     *
     * __block_write_begin() hands get_block a single block at a time, so
     * a qemu-img convert made 588,415 allocator calls for 2.24 GiB.
     * Claiming a run collapses that by the run length, and because the
     * run is contiguous the extents MERGE, so the tree stays small and
     * the journalled per-extent leaf write collapses with it.
     *
     * resv_remaining blocks from resv_next are MARKED IN THE BITMAP but
     * referenced by no extent, so whatever is left must be freed on
     * release or evict -- cetrafs_inode_drop_reservation(). That is the
     * dangerous part; the background scrub is the safety net, not the
     * plan.
     *
     * Guarded by its OWN spinlock, NOT lock_mutex, and that is
     * load-bearing: cetrafs_lock_release() holds lock_mutex across
     * filemap_write_and_wait(), which can re-enter cetrafs_get_block()
     * via writepages -- the very caller that takes a reservation.
     * Reusing lock_mutex self-deadlocks on an unmapped block at
     * writeback. (Allocation normally happens at write_begin, so
     * writeback finds everything mapped and never gets there, which is
     * why no test hangs. A filesystem must not rely on that.)
     *
     * A spinlock suffices: every critical section is a few assignments.
     * Freeing a stale remainder does I/O and happens after the unlock.
     */
    spinlock_t resv_lock;
    u64 resv_next;      /* next free LBA of the run */
    u32 resv_remaining; /* blocks left in it */
    u32 resv_bg;        /* which BG they came from (for freeing) */

    /*
     * The same run, published to the mount so the background scrub can
     * see it -- guarded by the SB's resv_list_lock, not resv_lock above.
     *
     * The scrub frees a block whose bitmap bit is set and which no
     * inode's extent tree references. A reserved run is exactly that,
     * for as long as the file stays open, so without this the scrub
     * reclaims a live reservation and the owner then hands those blocks
     * out anyway -- two files, one block. The span covers the WHOLE run
     * including the part already consumed: over-covering only ever makes
     * the scrub keep a block, and the consumed part is extent-referenced
     * anyway.
     */
    struct cetrafs_resv_span resv_span;

    /* The record's stat fields as this node last saw them, under
     * resv_lock (it is the inode's general-purpose short spinlock; this
     * is a handful of field copies, never I/O). See
     * cetrafs_stat_baseline in kmod.h for why ->write_inode needs it. */
    struct cetrafs_stat_baseline stat_baseline;

    /*
     * The last extent cetrafs_tree_lookup() resolved for this inode --
     * ext4's old i_cached_extent, and for the same reason.
     *
     * The buffered write path hands get_block ONE block at a time by
     * contract, so a 1 MiB write is 256 lookups, and each walks the
     * tree from the record down. On a compact file that costs nothing
     * (the root slots exclude everything). On a file with thousands of
     * extents -- a VM image written in place for months -- the
     * ei_block_end range filter stops excluding, because every leaf
     * ends up covering a wide, sparse span: measured at 6.68 leaf+index
     * reads per lookup on an 8221-extent file, against 0.00 on a
     * 2-extent one, and the per-block cost went 1.15 us -> 4.98 us with
     * throughput halved. Consecutive blocks almost always fall inside
     * the extent the previous lookup just resolved, so remembering one
     * extent answers them with no walk at all.
     *
     * KEYED ON THE RECORD IT CAME FROM (depth, entries, blocks). Every
     * caller of cetrafs_tree_lookup() passes a freshly-read record, so
     * a mutation that changed the map -- an append, a split, a truncate,
     * a punch -- changes the key and the entry simply misses. That is
     * what makes this safe WITHOUT having to find and annotate every
     * writer: there is no "did someone forget to invalidate" to get
     * wrong. The one mutation that can leave all three identical is a
     * relocation (defrag) that moves an extent without changing its
     * length, and that drops the entry explicitly.
     *
     * Only consulted while cetrafs_lock_held_for_write_locally() holds
     * -- the same predicate that decides a CACHED leaf block may be
     * trusted at all (cetrafs_read_tree_bh()). The entry is derived
     * from those very blocks, so it is valid exactly as long as they
     * are and never a window wider. Guarded by resv_lock.
     */
    bool ext_valid;
    bool ext_uninit;
    u16 ext_key_depth;
    u16 ext_key_entries;
    u64 ext_key_blocks;
    u32 ext_block; /* first file-relative block the extent covers */
    u32 ext_len;   /* how many blocks it covers */
    u64 ext_lba;   /* device block ext_block lives at */

    u64 generation; /* on-disk cetrafs_inode_t.generation this object was
                     * instantiated from (v0x0008) -- the cross-node
                     * inode-number-reuse detector; see inode.c */

    /* nofilelock metadata-freshness gate. With the exclusive lock OFF there
     * is nothing to guarantee "no peer can be changing this file", so a
     * cached extent tree / inode record is trustworthy only while this node
     * is the SOLE opener. A foreign bit in the on-disk read_open_nodes
     * presence mask means the file is open on another node too -- a handoff
     * in progress (a live migration) -- so metadata must be read fresh for
     * the duration. The mask is re-read at most once/sec (cheap) and the
     * verdict cached between, so steady-state I/O by the sole opener pays
     * nothing. Only consulted under nofilelock; the default lock uses
     * lock_writer_count. */
    bool foreign_open_cached;           /* last verdict: a peer also has it open */
    bool foreign_open_valid;            /* checked at least once this object's life */
    unsigned long foreign_open_checked; /* jiffies of the last presence read */

    /* Defrag pin (defrag.c, incremental mover): while set, the mover is
     * relying on this node's on-disk exclusive lock staying held, so the
     * last-writer close defers the on-disk release to the mover's own
     * cetrafs_lock_defrag_end(). Opens/closes/writes proceed completely
     * normally throughout -- the incremental mover holds inode_lock only
     * per small chunk, and the file-level lock it pins is OURS either
     * way (pre-held by local writers, or claimed by the mover itself
     * when there were none). */
    bool defrag_pinned;
    atomic_t defrag_queued; /* dedup: one pending background request per inode */

    /* Userspace-driven explicit whole-file lock (flock(2), cetrafs_flock).
     * Option A / fd-scoped: the fd that acquired the lock, NULL when this
     * node does not hold it. Released by flock(LOCK_UN) or by that fd's
     * close, so a crashing holder cannot wedge the file. Only ever set
     * under nofilelock -- the default mount's lock is automatic. Guarded by
     * lock_mutex. */
    struct file *explicit_lock_file;

    /* DEFAULT mount only: this node has surrendered this inode's
     * automatic lock on request (flock(LOCK_UN)) while still holding it
     * open for write. The lock is gone from the record, so a peer may
     * claim it; our writers carry on untouched, because the lock only
     * ever gated open(). Taken back by flock(LOCK_EX), or dropped when
     * the last local writer closes.
     *
     * While set, this inode must be INDISTINGUISHABLE from a nofilelock
     * inode -- on the device (our bit is published in read_open_nodes,
     * which a default-mount writer otherwise never sets) and in core
     * (both cache predicates below take the nofilelock branch). That is
     * what lets every destructive path -- unlink, rename, link,
     * truncate, setxattr, evict, scrub -- keep working unchanged: they
     * all ask the device "is anyone still using this file?", and
     * presence is the only answer left once the lock is gone.
     *
     * Guarded by lock_mutex for mutation; READ_ONCE on the per-block
     * read path, where it must stay a plain in-core bool. */
    bool lock_suspended;

    /* Serializes THIS node's own threads over the per-inode namespace
     * lock (nslock.c); the on-disk field arbitrates between nodes. Kept
     * separate from lock_mutex, which guards open/close refcounting --
     * a namespace op and an open of the same inode must not block each
     * other. */
    struct mutex ns_mutex;

    /* A record update staged by the operation the namespace lock is
     * bracketing, applied by the RELEASE instead of being written
     * separately.
     *
     * The release is already a compare-and-swap of this very record --
     * it has to be, since the lock lives in the record -- so carrying
     * the operation's own field updates in it costs nothing and saves a
     * whole synchronous 4 KiB write, ~38 ms on the real LUN. It is also
     * strictly safer than what it replaces: a blind write followed by a
     * separate CAS becomes one atomic verify-and-update.
     *
     * Written to the buffer cache unsynced when staged, so a later read
     * INSIDE the same operation (rename touching one directory twice,
     * say) sees it; the staged copy is what the release actually
     * publishes, because the CAS compares against the DEVICE and a
     * cached-only image would miscompare and be re-read away.
     *
     * Guarded by ns_mutex, which the staging and the release both hold.
     */
    bool ns_staged;
    bool ns_staged_fd; /* the staged record also changed FILE-domain fields (dir growth/shrink) */
    cetrafs_inode_t ns_record;
    u32 ns_nlink_base; /* device nlink when the record was staged -- lets the CAS publish nlink as a DELTA, not a
                          wholesale overwrite that reverts a peer's change */

    /* The task currently holding this inode's namespace lock (NULL when
     * unheld). Lets cetrafs_write_vfs_inode() tell "the caller itself
     * holds the lock -- the write is the operation's own persist
     * (setattr)" from "some other local thread holds it -- the record is
     * that operation's to publish, drop the writeback dirt". Guarded by
     * ns_mutex: set after acquire, cleared before release unlocks. */
    struct task_struct *ns_holder;

    /* v0x0005 FILE-DOMAIN SHADOW: the per-block hot path's deferred
     * record updates (extent root, size, blocks, times) live HERE, in
     * core, never in a dirty buffer -- a dirty record buffer was a time
     * bomb whose eventual whole-block flush republished stale namespace
     * -sector bytes over peers' CAS updates (the residual).
     * Published to the record's file sector (one region-1 CAS) at
     * durability boundaries: close, fsync, writeback, eviction, truncate
     * /defrag entry. Guarded by fd_lock; fd_dirty says the shadow is
     * ahead of the device. While dirty, every file-path read of this
     * inode's extent state must overlay the shadow (the device's file
     * sector is behind). */
    spinlock_t fd_lock;
    bool fd_dirty;
    cetrafs_inode_t fd_shadow;

    /* Lost-update guards for the shadow (2026-10-27, the ~15k-blocks-
     * per-fill leak and its cross-link sibling).
     *
     * fd_seq counts stages. A publisher snapshots the shadow and its
     * seq, CASes OUTSIDE fd_lock, and only then clears fd_dirty -- IF
     * the seq is still the one it took. The old protocol cleared dirty
     * at take time, so a get_block() landing inside the publisher's CAS
     * window found no overlay, rebuilt its tree from the lagging device
     * record, and staged that regressed tree over everything in flight:
     * every extent being published leaked, and the file read zeroes
     * over the lost range.
     *
     * fd_pub_mutex serialises every PUBLISHER of this record's file
     * sector (writeback's CAS, and the rebuild-then-publish paths:
     * truncate, punch, fallocate, defrag). Without it, writeback can
     * snapshot the pre-rebuild shadow, lose the race to a rebuild's
     * publish, and land the OLD tree over the new one -- the rebuild
     * then frees the old tree's blocks while the device still
     * references them, and the next allocation cross-links two files.
     * Ordering: inode_lock -> fd_pub_mutex; the mutex is a leaf. */
    u64 fd_seq;
    struct mutex fd_pub_mutex;

    /* Directories: the dirent_seq at which this node last read this
     * directory's dirent blocks forced-fresh. While the on-disk seq
     * still matches, the cached blocks are known current and can be
     * read without touching the device (see dir.c). U64_MAX = nothing
     * cached yet. */
    u64 dirent_seq_cached;

    /* Regular files: the file_seq at which this node last reconciled its
     * cached extent tree. U64_MAX until the first check, so the first
     * one always mismatches and reads fresh -- same cold-start posture
     * as dirent_seq_cached above. */
    u64 file_seq_cached;

    /* Set when the gate sees a PEER's stamp: this inode's cached tree
     * blocks may name the wrong physical blocks, so every tree read must
     * go to the device until a safe context can reconcile. Sticky on
     * purpose -- a leaf nobody happens to re-read would otherwise stay
     * cached and become trusted again the moment the gate goes quiet. */
    bool tree_cache_cold;

    /* Clears tree_cache_cold from a context that holds no buffer lock.
     * The gate itself runs on the per-block path and must not do the
     * work (it deadlocks there); waiting for the next open() instead
     * pinned a running VM's disk to a device round trip per tree read
     * for the life of the guest -- measured at 28068 forced-fresh reads
     * to 229 cached in five seconds, while a plain dd to the same
     * filesystem ran at 600 MB/s. */
    struct work_struct cold_work;

    struct inode vfs_inode;
};

/*
 * Give back whatever is left of this inode's speculative run.
 *
 * The reserved blocks are set in the bitmap and referenced by nothing,
 * so skipping this leaks every one of them. Called from the close path
 * and from evict, i.e. on every way out -- including the error ones,
 * which is why it takes no locks it might not get and is safe to call
 * when there is no reservation.
 */
void cetrafs_inode_drop_reservation(struct inode *inode)
{
    struct cetrafs_inode_info *ci = container_of(inode, struct cetrafs_inode_info, vfs_inode);
    struct super_block *sb = inode->i_sb;
    u64 lba;
    u32 n;

    if (!ci)
        return;

    spin_lock(&ci->resv_lock);
    lba = ci->resv_next;
    n = ci->resv_remaining;
    ci->resv_remaining = 0;
    ci->resv_next = 0;
    spin_unlock(&ci->resv_lock);

    /* Free FIRST, unpublish after: the span still covers these blocks
     * while we hand them back, so a scrub running concurrently skips
     * them rather than racing us to free the same bits. */
    while (n--)
        cetrafs_free_data_block(sb, lba++);

    cetrafs_resv_unpublish(sb, &ci->resv_span);
}

static inline struct cetrafs_inode_info *CETRAFS_I(struct inode *inode)
{
    return container_of(inode, struct cetrafs_inode_info, vfs_inode);
}

/*
 * Take the next block of the reservation, but ONLY if it is the block
 * the caller actually wants -- 'want_lba' is the contiguity hint, the
 * LBA right after the file's last extent. Handing out a run block that
 * is not contiguous with the file would start a new extent and lose the
 * merge, which is the entire point of reserving.
 *
 * want_lba == 0 means "no preference" (a file's first block), and the
 * reservation is taken.
 */
bool cetrafs_inode_take_reserved(struct inode *inode, u64 want_lba, u64 *out_lba)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    bool got = false;

    spin_lock(&ci->resv_lock);
    if (ci->resv_remaining && (!want_lba || want_lba == ci->resv_next)) {
        *out_lba = ci->resv_next++;
        ci->resv_remaining--;
        got = true;
    }
    spin_unlock(&ci->resv_lock);
    return got;
}

/* Install a fresh run, giving back any stale remainder first. */
void cetrafs_inode_set_reservation(struct inode *inode, u64 next, u32 count, u32 bg)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    u64 old_lba;
    u32 old_n;

    spin_lock(&ci->resv_lock);
    old_lba = ci->resv_next;
    old_n = ci->resv_remaining;
    ci->resv_next = next;
    ci->resv_remaining = count;
    ci->resv_bg = bg;
    spin_unlock(&ci->resv_lock);

    /* Give the old remainder back while the published span still covers
     * it (so the scrub leaves those bits to us), then re-point the span
     * at the new run.
     *
     * That leaves the NEW run unpublished for the duration of the frees.
     * It is not reachable: the scrub only frees blocks that were ALREADY
     * bitmap-set at its first pass, and every block of a run the
     * allocator just handed out was FREE at that pass -- so none of them
     * can be a candidate in the cycle now running. */
    while (old_n--)
        cetrafs_free_data_block(sb, old_lba++);

    cetrafs_resv_publish(sb, &ci->resv_span, next, count);
}

void cetrafs_inode_stat_baseline_set(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    spin_lock(&ci->resv_lock);
    ci->stat_baseline.mode = cetrafs_le32(raw->mode);
    ci->stat_baseline.uid = cetrafs_le32(raw->uid);
    ci->stat_baseline.gid = cetrafs_le32(raw->gid);
    ci->stat_baseline.nlink = cetrafs_le32(raw->nlink);
    ci->stat_baseline.size = cetrafs_le64(raw->size);
    ci->stat_baseline.blocks = cetrafs_le64(raw->blocks);
    ci->stat_baseline.atime = cetrafs_le64(raw->atime);
    ci->stat_baseline.mtime = cetrafs_le64(raw->mtime);
    ci->stat_baseline.ctime = cetrafs_le64(raw->ctime);
    ci->stat_baseline.valid = true;
    spin_unlock(&ci->resv_lock);
}

/* ------ the cached extent (see cetrafs_inode_info.ext_valid) ------ */

/*
 * Test-only: keep trusting a remembered extent after the map changed.
 *
 * Disables BOTH halves of what makes the entry safe -- the key check,
 * and the explicit drops on the paths that move or remove extents
 * without changing the key. Either alone is not a negative control:
 * with the drops still in place an ignored key changes nothing
 * observable (the drops catch it), which is how the first version of
 * tests/kernel/extent_cache.sh came to pass its own control and prove
 * nothing. Flip this and the content assertions must FAIL.
 */
static bool cetrafs_ext_cache_trust_stale;
module_param_named(ext_cache_trust_stale, cetrafs_ext_cache_trust_stale, bool, 0644);
MODULE_PARM_DESC(ext_cache_trust_stale,
                 "TEST ONLY: keep a remembered extent after the map changed (reproduces a stale "
                 "extent mapping: reads land on the wrong blocks)");

/* Turns the remembered extent off entirely -- the A/B control, and the
 * escape hatch if it ever needs to be taken out of the picture on a
 * live mount. */
static bool cetrafs_ext_cache_enabled = true;
module_param_named(ext_cache, cetrafs_ext_cache_enabled, bool, 0644);
MODULE_PARM_DESC(ext_cache, "remember the last extent resolved per inode (default on)");

static atomic64_t cetrafs_ext_cache_hits = ATOMIC64_INIT(0);
static atomic64_t cetrafs_ext_cache_misses = ATOMIC64_INIT(0);

u64 cetrafs_ext_cache_hit_count(void)
{
    return (u64) atomic64_read(&cetrafs_ext_cache_hits);
}

u64 cetrafs_ext_cache_miss_count(void)
{
    return (u64) atomic64_read(&cetrafs_ext_cache_misses);
}

/* The record fields the entry is keyed on -- see the struct comment for
 * why these three, and for the one mutation they cannot catch. */
static bool cetrafs_ext_key_matches(const struct cetrafs_inode_info *ci, const cetrafs_inode_t *raw)
{
    return ci->ext_key_depth == cetrafs_le16(raw->eh.eh_depth) &&
           ci->ext_key_entries == cetrafs_le16(raw->eh.eh_entries) && ci->ext_key_blocks == cetrafs_le64(raw->blocks);
}

/*
 * Answer 'iblock' from the remembered extent, or say no.
 *
 * Reports the same three things a tree walk would: the device block,
 * how much of the extent follows contiguously (what lets get_block
 * answer a multi-block mapping), and whether it is still preallocated.
 */
bool cetrafs_inode_ext_cache_lookup(struct inode *inode,
                                    const cetrafs_inode_t *raw,
                                    u32 iblock,
                                    u64 *out_lba,
                                    u32 *out_run,
                                    bool *out_uninit)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    bool hit = false;

    if (!cetrafs_ext_cache_enabled)
        return false;

    spin_lock(&ci->resv_lock);
    if (ci->ext_valid && (cetrafs_ext_cache_trust_stale || cetrafs_ext_key_matches(ci, raw)) &&
        iblock >= ci->ext_block && iblock < ci->ext_block + ci->ext_len) {
        *out_lba = ci->ext_lba + (iblock - ci->ext_block);
        if (out_run)
            *out_run = ci->ext_len - (iblock - ci->ext_block);
        if (out_uninit)
            *out_uninit = ci->ext_uninit;
        hit = true;
    }
    spin_unlock(&ci->resv_lock);

    atomic64_inc(hit ? &cetrafs_ext_cache_hits : &cetrafs_ext_cache_misses);
    return hit;
}

/* Remember the extent a walk just resolved, against the record it was
 * resolved from. */
void cetrafs_inode_ext_cache_store(struct inode *inode,
                                   const cetrafs_inode_t *raw,
                                   u32 ext_block,
                                   u32 ext_len,
                                   u64 ext_lba,
                                   bool uninit)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    if (!ext_len || !cetrafs_ext_cache_enabled)
        return;

    spin_lock(&ci->resv_lock);
    ci->ext_key_depth = cetrafs_le16(raw->eh.eh_depth);
    ci->ext_key_entries = cetrafs_le16(raw->eh.eh_entries);
    ci->ext_key_blocks = cetrafs_le64(raw->blocks);
    ci->ext_block = ext_block;
    ci->ext_len = ext_len;
    ci->ext_lba = ext_lba;
    ci->ext_uninit = uninit;
    ci->ext_valid = true;
    spin_unlock(&ci->resv_lock);
}

/*
 * Forget it.
 *
 * The key catches every mutation that changes depth, entry count or
 * block count. A RELOCATION changes none of them -- same extent, same
 * length, different device blocks -- so defrag drops the entry by hand,
 * and so does the open-time handoff that drops the cached tree blocks
 * this entry was derived from.
 */
void cetrafs_inode_ext_cache_drop(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    if (cetrafs_ext_cache_trust_stale)
        return; /* test-only, see the knob */

    spin_lock(&ci->resv_lock);
    ci->ext_valid = false;
    spin_unlock(&ci->resv_lock);
}

bool cetrafs_inode_stat_baseline_get(struct inode *inode, struct cetrafs_stat_baseline *out)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    bool valid;

    spin_lock(&ci->resv_lock);
    *out = ci->stat_baseline;
    valid = ci->stat_baseline.valid;
    spin_unlock(&ci->resv_lock);
    return valid;
}

/*
 * Re-baseline from the in-core stat block, for the paths that persist it
 * through a CAS stamp rather than through ->write_inode.
 *
 * After a stamping CAS commits, the record carries exactly these values,
 * so they are the new "what this node last saw on disk". Without this
 * the close path leaves the baseline at whatever the record held when
 * the inode was instantiated, and the next writeback then reads every
 * field it has since changed as still-ours -- which is precisely the
 * blind stamp the merge exists to prevent. Found by the merge assertion
 * in tests/kernel/write_inode_guards.sh, which failed with the merge
 * already in place.
 */
void cetrafs_inode_stat_baseline_from_incore(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    spin_lock(&ci->resv_lock);
    ci->stat_baseline.mode = inode->i_mode;
    ci->stat_baseline.uid = i_uid_read(inode);
    ci->stat_baseline.gid = i_gid_read(inode);
    ci->stat_baseline.nlink = inode->i_nlink;
    ci->stat_baseline.size = i_size_read(inode);
    ci->stat_baseline.blocks = inode->i_blocks;
    ci->stat_baseline.atime = (u64) inode_get_atime_sec(inode);
    ci->stat_baseline.mtime = (u64) inode_get_mtime_sec(inode);
    ci->stat_baseline.ctime = (u64) inode_get_ctime_sec(inode);
    ci->stat_baseline.valid = true;
    spin_unlock(&ci->resv_lock);
}

void cetrafs_inode_set_generation(struct inode *inode, u64 gen)
{
    CETRAFS_I(inode)->generation = gen;
}

u64 cetrafs_inode_get_generation(struct inode *inode)
{
    return CETRAFS_I(inode)->generation;
}

u64 cetrafs_inode_dirent_seq_cached(struct inode *inode)
{
    return CETRAFS_I(inode)->dirent_seq_cached;
}

void cetrafs_inode_set_dirent_seq_cached(struct inode *inode, u64 seq)
{
    CETRAFS_I(inode)->dirent_seq_cached = seq;
}

/* Test-only: make note_local_file_seq a no-op, simulating a publish
 * path that stamps but forgets to record what it stamped -- which is
 * exactly the bug that shipped (cetrafs_write_vfs_inode did not record
 * its own stamp). With this set, the owner decode is the ONLY thing
 * standing between a local write loop and a self-invalidation storm,
 * which is the property file_local_write_cache.sh needs to test. */
static bool cetrafs_file_seq_skip_note;
module_param_named(file_seq_skip_note, cetrafs_file_seq_skip_note, bool, 0644);
MODULE_PARM_DESC(file_seq_skip_note, "TEST ONLY: do not record our own file_seq publishes");

/*
 * Adopt a file_seq this node just wrote itself.
 *
 * The freshness gate treats "the record's file_seq differs from the one
 * my cache was reconciled at" as "a peer changed this file", and throws
 * the cached extent tree away. Our OWN publishes move it too, and the
 * cache they leave behind is correct by construction -- we are the ones
 * who changed it. Without this a writing node would discard its own
 * tree once per second on the growing-file hot path.
 */
void cetrafs_inode_note_local_file_seq(struct inode *inode, u64 seq)
{
    if (cetrafs_file_seq_skip_note)
        return;
    CETRAFS_I(inode)->file_seq_cached = seq;
}

/* The seq our last file-sector publish stamped (U64_MAX: none noted for
 * this in-core object). inode.c's refresh uses it to recognise a read
 * our own publish has superseded. */
u64 cetrafs_inode_local_file_seq(struct inode *inode)
{
    return CETRAFS_I(inode)->file_seq_cached;
}

/*
 * Stage this operation's final update to a record the namespace lock
 * covers, instead of writing it synchronously.
 *
 * Only legal for an inode in the lock set, and only for the operation's
 * LAST update to that record -- a later stage simply replaces an
 * earlier one, which is what rename touching one directory twice
 * wants. The copy is also pushed into the buffer cache unsynced so a
 * read later in the same operation sees it; it is the staged copy, not
 * the cached block, that the release publishes.
 */
void cetrafs_inode_stage_record(struct inode *inode, const cetrafs_inode_t *rec, bool fd_too)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    cetrafs_inode_t base;

    memcpy(&ci->ns_record, rec, sizeof(ci->ns_record));
    /* Snapshot the device's CURRENT nlink as the base for this staged
     * change. nlink is an accumulator mutated by every node that names
     * this inode; publishing the staged value wholesale reverts a
     * peer's change made since this operation read the record. The
     * namespace-lock CAS at release re-reads the device and applies
     * (staged_nlink - base) to whatever it then finds, so a concurrent
     * delta from another node survives. Read here, under the lock this
     * operation holds, so the base is the value the staged delta is
     * actually relative to. A read failure leaves base == staged, i.e.
     * the old wholesale behaviour for that one publish. */
    cetrafs_invalidate_raw_inode(inode->i_sb, inode->i_ino);
    if (cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, &base) == 0)
        ci->ns_nlink_base = cetrafs_le32(base.nlink);
    else
        ci->ns_nlink_base = cetrafs_le32(rec->nlink);
    ci->ns_staged = true;
    ci->ns_staged_fd = fd_too;
}

/* The staged image, for a later step of the SAME operation that needs
 * to read a record it has already updated -- a rename whose source and
 * destination are one directory does exactly that.
 *
 * It has to come from here rather than from the buffer cache, and that
 * is the whole point of staging: writing the image into the cache
 * (even unsynced) hands it to writeback, which puts it on the device,
 * which is the device round trip this exists to avoid. It also breaks
 * the release itself, since a compare-and-swap compares against the
 * DEVICE and would be seeded with an image that is not there yet. */
u32 cetrafs_inode_staged_nlink_base(struct inode *inode)
{
    return CETRAFS_I(inode)->ns_nlink_base;
}

bool cetrafs_inode_peek_staged_record(struct inode *inode, cetrafs_inode_t *out)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    if (!ci->ns_staged)
        return false;
    memcpy(out, &ci->ns_record, sizeof(*out));
    return true;
}

bool cetrafs_inode_take_staged_record(struct inode *inode, cetrafs_inode_t *out, bool *out_fd_too)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    if (!ci->ns_staged)
        return false;
    memcpy(out, &ci->ns_record, sizeof(*out));
    if (out_fd_too)
        *out_fd_too = ci->ns_staged_fd;
    ci->ns_staged = false;
    ci->ns_staged_fd = false;
    return true;
}

/* ---- file-domain shadow accessors (see the field's comment) ---- */

/* Record the hot path's latest file-domain state. 'raw' is the full
 * record the path was working on; only its file sector is kept. */
void cetrafs_inode_fd_stage(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    spin_lock(&ci->fd_lock);
    cetrafs_inode_fd_copy(&ci->fd_shadow, raw);
    /* Identity for the publish's echo check. */
    ci->fd_shadow.ino = raw->ino;
    ci->fd_shadow.generation = raw->generation;
    ci->fd_dirty = true;
    ci->fd_seq++;
    spin_unlock(&ci->fd_lock);
    ctrace("FDSTAGE ino=%llu blocks=%llu entries=%u depth=%u from=%pS\n", (unsigned long long) inode->i_ino,
           (unsigned long long) cetrafs_le64(raw->blocks), (unsigned int) cetrafs_le16(raw->eh.eh_entries),
           (unsigned int) cetrafs_le16(raw->eh.eh_depth), __builtin_return_address(0));
}

/* Overlay the shadow's file sector onto 'raw' if it is ahead of the
 * device -- every file-path read of extent state goes through this. */
void cetrafs_inode_fd_overlay(struct inode *inode, cetrafs_inode_t *raw)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    spin_lock(&ci->fd_lock);
    if (ci->fd_dirty)
        cetrafs_inode_fd_copy(raw, &ci->fd_shadow);
    spin_unlock(&ci->fd_lock);
}

/* The dirty flag, read under the lock -- the "before" half of the
 * torn-read check below. */
bool cetrafs_inode_fd_dirty_snap(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    bool v;

    spin_lock(&ci->fd_lock);
    v = ci->fd_dirty;
    spin_unlock(&ci->fd_lock);
    return v;
}

/* cetrafs_inode_fd_overlay() with the torn-read check that the plain
 * call cannot make: the caller sampled the dirty flag BEFORE reading the
 * record, and if it was set then but is clear now, a publisher's
 * CAS-then-clear landed in between -- so the record the caller read may
 * PREDATE the publish whose content the (now clean) shadow no longer
 * carries. Proceeding would rebuild the tree from that lagging record
 * and stage it over everything published, silently dropping extents:
 * exactly how a two-writer fill with auto-defrag lost a 223-block
 * extent out of a file's middle (2026-10-28). -EAGAIN tells the caller
 * to re-read; a read STARTED after the flag was seen clear includes the
 * publish, because every publisher writes the record before it clears
 * the flag. */
int cetrafs_inode_fd_overlay_checked(struct inode *inode, cetrafs_inode_t *raw, bool dirty_before)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    int ret = 0;

    spin_lock(&ci->fd_lock);
    if (ci->fd_dirty)
        cetrafs_inode_fd_copy(raw, &ci->fd_shadow);
    else if (dirty_before)
        ret = -EAGAIN;
    spin_unlock(&ci->fd_lock);
    return ret;
}

/*
 * TEST ONLY: restore the pre-2026-10-27 bug where take cleared the
 * dirty flag immediately. With it set, a get_block landing inside a
 * publisher's CAS window finds fd_dirty=false, so its overlay is a
 * no-op, it rebuilds the file's tree from the LAGGING device record,
 * and stages that near-empty tree over everything in flight -- every
 * extent allocated since the publisher's snapshot is dropped from the
 * shadow while its bitmap bit stays set, i.e. leaked. This is the knob
 * tests/kernel/enospc_fill_no_leak.sh flips to prove it catches the
 * regression; nothing in production sets it.
 */
static bool cetrafs_fd_take_clears_dirty;
module_param_named(fd_take_clears_dirty, cetrafs_fd_take_clears_dirty, bool, 0644);
MODULE_PARM_DESC(fd_take_clears_dirty, "TEST ONLY: restore the shadow lost-update leak");

/* Snapshot the shadow for publishing. Returns false when there is
 * nothing pending. Deliberately does NOT clear the dirty flag: the
 * publish happens outside fd_lock, and anything staged meanwhile must
 * survive it. The publisher reports back with
 * cetrafs_inode_fd_published(*out_seq) once its write landed (or was
 * superseded), and the flag clears only if nothing staged since. */
bool cetrafs_inode_fd_take(struct inode *inode, cetrafs_inode_t *out, u64 *out_seq)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    bool was;

    spin_lock(&ci->fd_lock);
    was = ci->fd_dirty;
    if (was)
        memcpy(out, &ci->fd_shadow, sizeof(*out));
    *out_seq = ci->fd_seq;
    if (unlikely(cetrafs_fd_take_clears_dirty))
        ci->fd_dirty = false; /* the bug, on purpose (test knob) */
    spin_unlock(&ci->fd_lock);
    if (was)
        ctrace("FDTAKE ino=%llu blocks=%llu entries=%u depth=%u\n", (unsigned long long) inode->i_ino,
               (unsigned long long) cetrafs_le64(out->blocks), (unsigned int) cetrafs_le16(out->eh.eh_entries),
               (unsigned int) cetrafs_le16(out->eh.eh_depth));
    return was;
}

/* The publish that took (or overlaid) the shadow at 'seq' has landed --
 * or published something strictly newer built from it. Clear the dirty
 * flag ONLY if nothing staged since; a newer stage must survive to the
 * next boundary, or its extents leak exactly the way the old
 * clear-at-take protocol leaked them. */
void cetrafs_inode_fd_published(struct inode *inode, u64 seq)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    spin_lock(&ci->fd_lock);
    if (ci->fd_seq == seq)
        ci->fd_dirty = false;
    spin_unlock(&ci->fd_lock);
}

u64 cetrafs_inode_fd_seq(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    u64 seq;

    spin_lock(&ci->fd_lock);
    seq = ci->fd_seq;
    spin_unlock(&ci->fd_lock);
    return seq;
}

/* Every publisher of this record's FILE sector runs its snapshot-CAS-
 * report sequence under this mutex -- see the field's comment. */
void cetrafs_inode_fd_pub_lock(struct inode *inode)
{
    mutex_lock(&CETRAFS_I(inode)->fd_pub_mutex);
}

void cetrafs_inode_fd_pub_unlock(struct inode *inode)
{
    mutex_unlock(&CETRAFS_I(inode)->fd_pub_mutex);
}

/* Overlay AND claim: the caller is about to rebuild/publish the file
 * domain itself (truncate, fallocate, defrag), so the shadow's content
 * is folded into 'raw' and the pending flag cleared -- from here the
 * caller's own publish carries it. An error path that bails without
 * publishing leaves the folded extents unpublished: blocks allocated and
 * referenced by nothing durable, which is the leak-safe direction (the
 * scrub reclaims), never a double reference. */
void cetrafs_inode_fd_fold(struct inode *inode, cetrafs_inode_t *raw)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    spin_lock(&ci->fd_lock);
    if (ci->fd_dirty)
        cetrafs_inode_fd_copy(raw, &ci->fd_shadow);
    ci->fd_dirty = false;
    spin_unlock(&ci->fd_lock);
}

bool cetrafs_inode_fd_dirty(struct inode *inode)
{
    return CETRAFS_I(inode)->fd_dirty;
}

void cetrafs_inode_ns_mutex_lock(struct inode *inode)
{
    mutex_lock(&CETRAFS_I(inode)->ns_mutex);
}

/* See ns_holder's comment in struct cetrafs_inode_info. */
void cetrafs_inode_ns_holder_set(struct inode *inode, bool held)
{
    CETRAFS_I(inode)->ns_holder = held ? current : NULL;
}

bool cetrafs_inode_ns_held_by_current(struct inode *inode)
{
    return CETRAFS_I(inode)->ns_holder == current;
}

void cetrafs_inode_ns_mutex_unlock(struct inode *inode)
{
    mutex_unlock(&CETRAFS_I(inode)->ns_mutex);
}

struct kmem_cache *cetrafs_inode_cache;

/* Defined further down, next to the gate that schedules it. */
static void cetrafs_inode_cold_work(struct work_struct *w);

/*
 * Per-IDENTITY state: everything here describes the FILE this object
 * currently represents, so it must be re-initialized every time the
 * object takes on a new identity -- cetrafs_iget()'s I_NEW fill path
 * calls this (cetrafs_inode_identity_init()), not just the slab ctor.
 *
 * The slab constructor alone is NOT enough: it runs once per slab
 * OBJECT, never on recycle, so a recycled object arrives carrying
 * whatever these fields held when its previous file was evicted. Most
 * fields have a provable back-to-initial-at-free invariant (argued at
 * cetrafs_alloc_vfs_inode()), but defrag_queued does not: a background
 * defrag request holds no inode reference, so an eviction can free the
 * object with the dedup latch still SET -- and the next file unlucky
 * enough to recycle that slot had its auto-defrag permanently disabled
 * (every consider() declined "already queued", and the worker that
 * clears the latch is exactly what the latch was blocking). Caught by
 * a full-gate trace on an 8-core node: the armed index-gate trigger hit
 * "decline latch" on a freshly-created file no one had ever queued
 * (2026-10-29). The freshness caches (foreign_open_*, *_seq_cached,
 * tree_cache_cold) are reset here for the same reason: inherited, they
 * are not merely stale, they are the WRONG FILE's answers.
 */
static void cetrafs_inode_identity_init_ci(struct cetrafs_inode_info *ci)
{
    ci->fd_dirty = false;
    ci->fd_seq = 0;
    ci->resv_next = 0;
    ci->resv_remaining = 0;
    ci->stat_baseline.valid = false;
    ci->resv_span.start = 0;
    ci->resv_span.count = 0;
    ci->foreign_open_cached = true; /* safe default: read fresh until proven sole opener */
    ci->foreign_open_valid = false;
    ci->foreign_open_checked = 0;
    ci->defrag_pinned = false;
    atomic_set(&ci->defrag_queued, 0);
    ci->explicit_lock_file = NULL;
    ci->lock_suspended = false;
    ci->dirent_seq_cached = U64_MAX;
    ci->file_seq_cached = U64_MAX;
    ci->tree_cache_cold = false;
    /* A slab object is recycled across identities; a remembered extent
     * carried over would map the PREVIOUS file's blocks. */
    ci->ext_valid = false;
}

void cetrafs_inode_identity_init(struct inode *inode)
{
    cetrafs_inode_identity_init_ci(CETRAFS_I(inode));
}

static void cetrafs_inode_init_once(void *foo)
{
    struct cetrafs_inode_info *ci = foo;

    mutex_init(&ci->lock_mutex);
    spin_lock_init(&ci->resv_lock);
    spin_lock_init(&ci->fd_lock);
    mutex_init(&ci->fd_pub_mutex);
    INIT_LIST_HEAD(&ci->resv_span.link);
    atomic_set(&ci->lock_writer_count, 0);
    atomic_set(&ci->read_opener_count, 0);
    atomic_set(&ci->lock_local_open_count, 0);
    mutex_init(&ci->ns_mutex);
    INIT_WORK(&ci->cold_work, cetrafs_inode_cold_work);
    cetrafs_inode_identity_init_ci(ci);
    inode_init_once(&ci->vfs_inode);
}

int cetrafs_init_inode_cache(void)
{
    cetrafs_inode_cache = kmem_cache_create("cetrafs_inode_cache", sizeof(struct cetrafs_inode_info), 0,
                                            SLAB_RECLAIM_ACCOUNT | SLAB_ACCOUNT, cetrafs_inode_init_once);
    if (!cetrafs_inode_cache)
        return -ENOMEM;
    return 0;
}

void cetrafs_destroy_inode_cache(void)
{
    kmem_cache_destroy(cetrafs_inode_cache);
    cetrafs_inode_cache = NULL;
}

/* ->alloc_inode: the constructor above already ran inode_init_once() and
 * zeroed the refcount for a freshly-created slab object; a recycled one
 * already has lock_writer_count==0 from the matching release path below
 * (an inode is never freed back to the slab while a local write-opener
 * still holds it open). lock_suspended rides on the same invariant:
 * suspending requires a local writer, and the last writer's close clears
 * it, so a recycled object can never arrive still believing it has
 * surrendered a lock. */
struct inode *cetrafs_alloc_vfs_inode(struct super_block *sb)
{
    struct cetrafs_inode_info *ci = alloc_inode_sb(sb, cetrafs_inode_cache, GFP_KERNEL);

    if (!ci)
        return NULL;
    return &ci->vfs_inode;
}

void cetrafs_free_vfs_inode(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    /* The reconcile worker holds an igrab reference, so it cannot still
     * be running here -- but a cancel is the cheap proof of that rather
     * than an assumption, and it also covers a queued-but-never-run item
     * on an unmount race. */
    cancel_work_sync(&ci->cold_work);

    /* ->evict_inode unconditionally drops the reservation, which
     * unpublishes this entry, so by here it must be off the mount's
     * list. Freeing it while still linked would corrupt that list --
     * and the next scrub would walk into freed memory. The ctor leaves
     * a recycled object with an empty link, so this also proves the
     * recycle invariant rather than assuming it. */
    WARN_ON_ONCE(!list_empty(&ci->resv_span.link));

    kmem_cache_free(cetrafs_inode_cache, ci);
}

/* ---- on-disk lock field as an atomic compare-and-swap --------------
 *
 * The whole-file lock lives in three fields of the inode record, and the
 * record sits alone in the first sector of its own block (v0x0007/9), so
 * taking or releasing the lock is one CAS of that sector.
 * This replaces "take the PR mutex, read, decide, write, read back to
 * see whether the write stuck" -- the swap itself now carries the
 * decision: it only lands if the record is still byte-for-byte what the
 * decision was made against, so a lost race cannot be mistaken for a
 * win. (That silent double-claim is the exact bug this file's
 * header describes; CAS makes it unrepresentable rather than merely
 * checked-for.)
 *
 * Staleness of a foreign holder cannot be judged inside the mutator (it
 * needs I/O against the Node Registry), so the caller decides first and
 * passes the verdict in: a steal is accepted ONLY from the exact owner
 * id it validated. Anything else the mutator sees -- a different owner,
 * a re-locked file, a replaced inode -- rejects the swap.
 */
/* Reader-presence modes for cetrafs_lock_cas_ctx. */
enum cetrafs_reader_op {
    CETRAFS_READER_NONE = 0,
    CETRAFS_READER_SET,
    CETRAFS_READER_CLEAR,
};

struct cetrafs_lock_cas_ctx {
    u32 my_node_id;
    u64 generation; /* inode must still be this incarnation (v0x0008) */
    bool claim;     /* true: take the lock; false: release ours */
    bool allow_steal;
    bool steal_release; /* clear the lock to NONE if it is EXCLUSIVE and
                         * owned by steal_from -- a steal-to-NONE, used
                         * under nofilelock to clear a stale foreign lock
                         * we are bypassing rather than claiming (we never
                         * auto-claim there). Independent of claim/release. */
    u32 steal_from;     /* meaningful when allow_steal or steal_release */

    /* Reader presence. When set, this CAS is purely about
     * read_open_nodes and leaves the write lock alone -- the two are
     * orthogonal and a reader must never disturb a writer's claim. */
    enum cetrafs_reader_op reader_op;

    /* Release path only: also stamp this inode's in-core stat fields
     * into the same swap. The close path used to persist them with one
     * full read-modify-write and then clear the lock bits with a SECOND
     * one on the very same record, back to back -- two synchronous
     * round trips where one does, which on a real LUN is tens of
     * milliseconds per file. NULL keeps the lock-only
     * behaviour for every other caller. */
};

static int cetrafs_lock_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_lock_cas_ctx *ctx = priv;
    cetrafs_inode_t rec;

    /* v0x0005: the image is the record's NAMESPACE SECTOR (512 bytes) --
     * everything this mutate touches (locks, presence) lives there. */
    if (len < CETRAFS_INODE_NS_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);

    if (cetrafs_le64(rec.generation) != ctx->generation)
        return -ESTALE; /* number reused for a different file */

    if (ctx->reader_op != CETRAFS_READER_NONE) {
        u64 bit = 1ULL << (ctx->my_node_id % CETRAFS_MAX_READER_NODES);
        u64 want = (ctx->reader_op == CETRAFS_READER_SET) ? (cetrafs_le64(rec.read_open_nodes) | bit)
                                                          : (cetrafs_le64(rec.read_open_nodes) & ~bit);

        if (want == cetrafs_le64(rec.read_open_nodes))
            return 1; /* already in the desired state -- nothing to do */
        rec.read_open_nodes = cetrafs_cpu_to_le64(want);
        cetrafs_inode_stamp_crc_ns(&rec);
        memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
        return 0;
    }

    if (ctx->steal_release) {
        /* Clear a foreign lock to NONE (no new owner). Only lands if the
         * record still shows the exact stale owner we decided to displace,
         * so a live re-lock or a reclaim by someone else is left alone. */
        if (cetrafs_le32(rec.lock_mode) != CETRAFS_LOCK_EXCLUSIVE ||
            cetrafs_le32(rec.lock_owner_node) != ctx->steal_from)
            return 1; /* not that owner any more -- nothing to clear */
        rec.lock_owner_node = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        rec.lock_mode = CETRAFS_LOCK_NONE;
        cetrafs_inode_stamp_crc_ns(&rec);
        memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
        return 0;
    }

    if (ctx->claim) {
        bool free_now = (rec.lock_mode == CETRAFS_LOCK_NONE);
        bool stealable = ctx->allow_steal && cetrafs_le32(rec.lock_mode) == CETRAFS_LOCK_EXCLUSIVE &&
                         cetrafs_le32(rec.lock_owner_node) == ctx->steal_from;

        if (!free_now && !stealable)
            return -ETXTBSY; /* held by someone else, or taken since we looked */

        rec.lock_owner_node = cetrafs_cpu_to_le32(ctx->my_node_id);
        rec.lock_mode = cetrafs_cpu_to_le32(CETRAFS_LOCK_EXCLUSIVE);
    } else {
        if (cetrafs_le32(rec.lock_mode) != CETRAFS_LOCK_EXCLUSIVE ||
            cetrafs_le32(rec.lock_owner_node) != ctx->my_node_id)
            return 1; /* not ours any more -- nothing to release, not an error */

        rec.lock_owner_node = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        rec.lock_mode = CETRAFS_LOCK_NONE;
        /* v0x0005: the stat fields live in the FILE sector now and are
         * published by cetrafs_write_vfs_inode()'s own sector-1 CAS at
         * this same close boundary (see cetrafs_lock_release()); this
         * swap carries only the lock-clear. */
    }

    cetrafs_inode_stamp_crc_ns(&rec);
    memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
    return 0;
}

/* 'seed' is the caller's own freshly-read copy of this record, handed to
 * the CAS so it need not read the same block again -- see
 * cetrafs_cas_region_seeded(). NULL is always safe (and simply costs the
 * read). */
static int cetrafs_lock_cas(struct inode *inode, struct cetrafs_lock_cas_ctx *ctx, const cetrafs_inode_t *seed)
{
    return cetrafs_cas_record_seeded(inode->i_sb, cetrafs_inode_lba(inode->i_sb, inode->i_ino), seed,
                                     seed ? CETRAFS_INODE_NS_BYTES : 0, cetrafs_lock_cas_mutate, ctx);
}

/* Clear the on-disk lock this node holds -- defined far below, next to
 * defrag_end which also uses it, but forward-declared here for the
 * explicit-lock close cleanup in cetrafs_lock_release(). */
static int cetrafs_lock_clear_on_disk(struct inode *inode, bool stamp_stat);
/* Withdraw this node from read_open_nodes -- defined with the suspension
 * code below, used by the close path above it. */
static void cetrafs_lock_presence_put(struct inode *inode);


/*
 * ->open: called for every open() of a regular file, read-only opens
 * included -- a read-only open from another node must still be rejected
 * while the lock is held, by design. Only an open with FMODE_WRITE
 * ever claims the lock or counts toward lock_writer_count, and only a
 * write-open's claim ever writes the on-disk lock fields -- which is
 * exactly the part that needs cross-node mutual exclusion, below.
 *
 * Every open (read or write) counts toward lock_local_open_count, and
 * the first one back to zero local openers refreshes this node's in-core
 * stat fields + page cache from the fresh 'raw' read below (inode.c's
 * cetrafs_apply_raw_to_vfs_inode(), gated by raw.mtime actually being
 * newer than what's cached -- see its own comment for why "first local
 * open" alone isn't a safe enough condition on its own).
 */
/*
 * Test-only: make the reader-set publish CAS fail, so the path taken
 * when it does can actually be exercised. Without a knob it is only
 * reachable through CAS retry exhaustion or a device error, neither of
 * which a test can provoke -- and the bug it hid (an unbalanced counter
 * that permanently stopped this node from ever publishing again) is
 * invisible until long afterwards.
 */
static bool cetrafs_lock_fail_reader_publish;
module_param_named(lock_fail_reader_publish, cetrafs_lock_fail_reader_publish, bool, 0644);
MODULE_PARM_DESC(lock_fail_reader_publish, "test-only: force the reader-set publish to fail");

int cetrafs_lock_open(struct inode *inode, struct file *file)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    bool want_write = (file->f_mode & FMODE_WRITE) != 0;
    /* nofilelock mount: claim no exclusive lock and refuse no open. The
     * open-boundary stat refresh, the local open counts and the read
     * presence set below all still run -- only the EXCLUSIVE claim/check
     * is skipped. */
    bool lock_on = cetrafs_sb_file_lock_enabled(sb);
    cetrafs_inode_t raw;
    u32 my_node_id;
    bool reclaim_from_stale = false;
    u32 stale_owner = CETRAFS_NODE_ID_NONE;
    int ret;

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    if (want_write && cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced: no new write claims */

    mutex_lock(&ci->lock_mutex);

    /* No PR mutex here any more: the claim below is a single
     * atomic compare-and-swap, which supplies its own atomicity against
     * every other node. On hardware without CAW, cetrafs_cas_record()
     * takes the cluster mutex internally for exactly the old critical
     * section -- so this path is unchanged there, just no longer
     * hand-rolled here. */

    /* The one read in this function that must see a peer's current
     * claim, not whatever this node happened to cache earlier (e.g. a
     * prior read-only open of this same file) -- see
     * cetrafs_invalidate_raw_inode()'s own comment. */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);

    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        goto out_pr_unlock;

    /* Enforcement honors a lock that is actually PRESENT on disk, in BOTH
     * mount modes -- this is not gated on lock_on. The default mount AND a
     * nofilelock mount both refuse an open while a live peer holds the
     * EXCLUSIVE lock. What nofilelock turns off is only the AUTOMATIC claim
     * on write-open (below, which stays gated on lock_on): under nofilelock
     * no lock is ever present unless userspace set one via flock(LOCK_EX),
     * so ordinary migration flows are unaffected and only an explicit lock
     * blocks a peer -- which is exactly its purpose. (dir.c's unlink/rename
     * already enforce a present lock in both modes; this aligns open() with
     * them.) */
    if (cetrafs_le32(raw.lock_mode) == CETRAFS_LOCK_EXCLUSIVE && cetrafs_le32(raw.lock_owner_node) != my_node_id) {
        bool stale = false;

        /* an earlier phase: a foreign claim left behind by a node whose
         * heartbeat has gone stale is reclaimable rather than a
         * permanent -ETXTBSY -- see node.c's cetrafs_node_is_stale()
         * for what "stale" means and its caveats. Only mutate the local
         * copy here; nothing gets persisted unless this open goes on to
         * actually claim it below (a mere read-open just gets to
         * proceed, same as if it found the file genuinely unlocked). */
        ret = cetrafs_node_is_stale(sb, cetrafs_le32(raw.lock_owner_node), &stale);
        if (ret)
            goto out_pr_unlock;

        if (!stale) {
            ret = -ETXTBSY;
            goto out_pr_unlock;
        }

        /* Before granting access past a dead holder's lock, replay its
         * per-node journal: if it crashed mid-operation on
         * this very file (e.g. mid-write of an extent-leaf block its
         * exclusive lock protected), that must be repaired before anyone
         * reads or builds on those blocks. One-shot (the dead node's
         * flag goes clean on the first successful replay). Passing
         * cluster_mutex_held per whether this open's own claim path
         * already took it (write-opens do, read-only bypasses don't). */
        /* We hold no cluster mutex here any more (the claim is a CAS), so
         * replay takes its own -- which is also what serializes
         * concurrent replayers of the same dead node. */
        /* ...unless this is a read-only mount, where both halves of
         * that are writes an observer must not make: fencing CASes the
         * peer's registry row, and replay writes into its data region.
         * So we do neither and let the read through -- what it sees may
         * be the dead node's unrepaired metadata, which is why it is
         * logged. A node that can write will repair it when it reclaims
         * the lock or the Zone Group. */
        if (sb_rdonly(sb)) {
            pr_warn(
                "lock: ino=%llu read-only mount: reading past node %u's stale lock "
                "WITHOUT replaying its journal -- its metadata may be unrepaired\n",
                (unsigned long long) inode->i_ino, raw.lock_owner_node);
        } else {
            cetrafs_node_fence_peer(sb, cetrafs_le32(raw.lock_owner_node), "a file lock");
            ret = cetrafs_journal_replay_node(sb, cetrafs_le32(raw.lock_owner_node), /*wait_for_claim=*/false);
            if (ret) {
                pr_err("lock: ino=%llu could not replay stale node %u's journal (%d), refusing open\n",
                       (unsigned long long) inode->i_ino, raw.lock_owner_node, ret);
                goto out_pr_unlock;
            }
        }

        pr_warn("lock: ino=%llu reclaiming a stale lock from node %u\n", (unsigned long long) inode->i_ino,
                raw.lock_owner_node);
        /* Record the verdict for the CAS below instead of editing the
         * local copy: the swap must be told exactly whose claim it is
         * allowed to displace, and a read-only open just proceeds
         * without persisting anything at all. */
        reclaim_from_stale = true;
        stale_owner = cetrafs_le32(raw.lock_owner_node);
        raw.lock_mode = CETRAFS_LOCK_NONE;
        raw.lock_owner_node = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    }

    /* A SUSPENDED inode must not be silently re-locked by the next local
     * write-open: the window belongs to whoever asked for it, and an
     * unrelated opener closing it would strand the peer mid-handoff. The
     * window is taken back explicitly, by flock(LOCK_EX). */
    if (lock_on && want_write && !ci->lock_suspended && (raw.lock_mode == CETRAFS_LOCK_NONE || reclaim_from_stale)) {
        /* One atomic compare-and-swap carries the whole claim: no
         * write-then-verify-readback, because the swap can only
         * land on the exact record the decision above was made against.
         * A steal is permitted only from the specific stale owner whose
         * liveness was just checked. */
        struct cetrafs_lock_cas_ctx ctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .claim = true,
            .allow_steal = reclaim_from_stale,
            .steal_from = stale_owner,
        };

        ret = cetrafs_lock_cas(inode, &ctx, &raw);
        if (ret) {
            if (ret == -ETXTBSY)
                pr_warn("lock: ino=%llu lost the race claiming the write lock\n", (unsigned long long) inode->i_ino);
            goto out_pr_unlock;
        }
    }

    /* nofilelock: we honor a present lock (above) but never auto-claim one,
     * so a stale foreign lock we just decided to bypass would otherwise
     * linger on disk forever, every future open re-paying the staleness
     * check (a Node Registry read) to step past it. Clear it to NONE --
     * steal-to-NONE, not steal-to-self, since nofilelock must not claim.
     * Best-effort and never on a read-only mount (an observer writes
     * nothing; the stale branch above already skipped fence+replay there). */
    if (!lock_on && reclaim_from_stale && !sb_rdonly(sb)) {
        struct cetrafs_lock_cas_ctx cctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .steal_release = true,
            .steal_from = stale_owner,
        };
        int cret = cetrafs_lock_cas(inode, &cctx, &raw);

        if (cret < 0)
            pr_warn_ratelimited("lock: ino=%llu could not clear stale foreign lock from node %u: %d\n",
                                (unsigned long long) inode->i_ino, stale_owner, cret);
    }

    /*
     * #3: "first local open" alone is not
     * proof this node has no unflushed state to lose. close() does not
     * force synchronous inode-metadata writeback -- write_inode() (and
     * so the on-disk size/mtime/nlink fields) only catches up later, via
     * ordinary lazy writeback or an explicit sync -- so a close followed
     * immediately by a local reopen hits local_open_count==0 while the
     * raw record this function just read is still the pre-write
     * snapshot. Unconditionally refreshing from it clobbered this node's
     * own correct, newer in-core i_size/page-cache content with that
     * stale on-disk zero, found via the simplest possible repro (write a
     * file, close it, cat it back, same mount, same process group: read
     * back empty, size 0) -- not a cross-node race at all, just this
     * node racing its own writeback.
     *
     * The question that actually decides it is WHOSE publish this record
     * is carrying: a peer's (take it) or our own pre-writeback one (keep
     * the in-core state). file_seq answers exactly that -- it names the
     * node that last stamped the file sector, and it is stamped on every
     * such publish including create, so it is never absent.
     *
     * This used to ask raw.mtime > our cached mtime instead. That gets
     * the local case right for the same reason, but it is wrong across
     * nodes: mtime has ONE-SECOND granularity, so a peer that wrote and
     * closed within the same second as our last known mtime is not
     * "strictly newer" and the refresh is skipped -- we open holding a
     * stale i_size and read the peer's data beyond it as a hole. The
     * identical mistake in the lock-resume path survived a two-node run
     * on slow hardware and failed the moment it met a faster three-node
     * one; this is the same bug in the path that predates it, and it is
     * reachable in BOTH mount modes.
     */
    if (atomic_read(&ci->lock_local_open_count) == 0 &&
        CETRAFS_FILE_SEQ_NODE(cetrafs_le64(raw.file_seq)) != (u32) (my_node_id & 0xFFFFu)) {
        /* -EUCLEAN means the record changed type without changing
         * generation: corruption worth logging, but not worth failing a
         * read on -- the right outcome is simply not to apply it.
         *
         * -ESTALE is different, and it is why this is not just a log
         * line: the record describes a file the namespace no longer has
         * (deleted, or its number reused for another file). This read is
         * strictly fresher than the one d_revalidate made a moment ago,
         * so it can see a peer's unlink that the revalidate missed --
         * and proceeding would open a dead file's extents, which the
         * allocator may already have given to somebody else. Fail the
         * open; the next lookup resolves it correctly or reports it
         * gone. */
        int rret = cetrafs_apply_raw_to_vfs_inode(inode, &raw);

        if (rret)
            pr_warn_ratelimited("ino=%llu open-boundary refresh refused: %d\n", (unsigned long long) inode->i_ino,
                                rret);
        if (rret == -ESTALE) {
            ret = -ESTALE;
            goto out_pr_unlock;
        }
    }
    atomic_inc(&ci->lock_local_open_count);

    if (want_write)
        atomic_inc(&ci->lock_writer_count);

    /*
     * Publish this node into the file's open-presence set (read_open_nodes),
     * on the first local opener (0->1), one CAW. Read-opens ALWAYS publish,
     * so a peer about to unlink the file sees that destroying its blocks
     * would pull them from under a live reader. Write-opens publish too, but
     * ONLY under nofilelock: there is no exclusive lock there to mark this
     * node as a holder, so presence is the sole cross-node signal that the
     * file is open here -- and a peer reads it (cetrafs_lock_held_for_write_
     * locally) to know a migration handoff is in progress and switch its
     * metadata reads to fresh. Under the default lock a writer is already
     * marked by the exclusive lock, so it does not publish. The bit tracks
     * ANY opener, driven by read_opener_count, which a write-open bumps too
     * in the nofilelock case. A failure here FAILS the open -- see below.
     */
    if (!(want_write && lock_on) && atomic_inc_return(&ci->read_opener_count) == 1) {
        struct cetrafs_lock_cas_ctx rctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .reader_op = CETRAFS_READER_SET,
        };
        int rret = cetrafs_lock_fail_reader_publish ? -EIO : cetrafs_lock_cas(inode, &rctx, &raw);

        if (rret < 0) {
            /*
             * Fail the open, reader and writer alike. An opener that runs
             * UNPUBLISHED is invisible to every peer that asks "is anyone
             * using this file?": a nofilelock write-open's peers keep
             * trusting cached metadata and read its changes stale, and a
             * read-open's peer unlink sees no reader and frees the blocks
             * under this fd. Read-opens used to be waved through here as
             * "the pre-existing hazard, not a new one", leaving the
             * publish to "the next open" -- but the publish only runs on
             * the counter's 0->1 edge, so for a long-lived fd (a running
             * VM image, held open for months) a single transient failure
             * meant running invisible for the fd's entire life, not until
             * some retry. There is no partial on-disk state to undo (the
             * CAS either landed or did not), a device that cannot
             * complete one CAW is about to fail this opener's reads
             * anyway, and the caller can simply retry the open -- so
             * refuse loudly instead.
             *
             * ->release is NOT called for a failed open, so unwind every
             * count this open bumped.
             */
            pr_warn_ratelimited("ino=%llu could not publish this node as an opener: %d -- refusing the open\n",
                                (unsigned long long) inode->i_ino, rret);
            atomic_dec(&ci->read_opener_count);
            if (want_write)
                atomic_dec(&ci->lock_writer_count);
            atomic_dec(&ci->lock_local_open_count);
            ret = rret;
            goto out_pr_unlock;
        }
    }

    /* Force the next freshness check to go to the device instead of
     * riding the one-second verdict cache. open() is the moment a
     * handoff actually lands -- qemu starting a VM on the node HA moved
     * it to -- and it is the one moment a second of staleness is not a
     * rounding error but the difference between a disk that opens and
     * one that does not. */
    ci->foreign_open_valid = false;

    /* The one safe place to do the heavy half of a reconcile: no buffer
     * is locked here and no folio is held, unlike the per-block gate.
     * A peer rewrote this file's layout, so its cached DATA pages may be
     * the wrong blocks' contents. Clean pages only -- dirty ones are our
     * own unwritten data and are never dropped. */
    if (READ_ONCE(ci->tree_cache_cold)) {
        /* Re-read: the tree we must stop believing in has to be walked
         * from the record as it stands NOW, not from whatever this open
         * validated itself against a moment ago.
         *
         * Into 'raw', deliberately -- nothing reads it past this point,
         * and a second cetrafs_inode_t here is 652 more bytes of stack.
         * That took this frame to 1384 and broke the build on a kernel
         * configured with CONFIG_FRAME_WARN=1024 (Proxmox's), while the
         * arm64 dev kernel's 2048 said nothing. */
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        if (cetrafs_read_raw_inode(sb, inode->i_ino, &raw) == 0)
            cetrafs_tree_invalidate_cached(inode, &raw);
        if (inode->i_mapping)
            invalidate_mapping_pages(inode->i_mapping, 0, -1);
        WRITE_ONCE(ci->tree_cache_cold, false);
        atomic64_inc(&cetrafs_file_cache_reconciles);
    }

    ret = 0;

out_pr_unlock:
    mutex_unlock(&ci->lock_mutex);
    return ret;
}

/*
 * ->release: drops this node's local open count (read or write alike --
 * the counterpart to cetrafs_lock_open()'s refresh-on-first-open above,
 * so the *next* open, once this node has nothing left open locally,
 * knows to treat raw's stat fields as fresh again) and, for a
 * write-opener, drops the local write-open count too, releasing the
 * on-disk claim only once that reaches zero (the last local
 * write-opener).
 */
int cetrafs_lock_release(struct inode *inode, struct file *file)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    bool want_write = (file->f_mode & FMODE_WRITE) != 0;
    bool lock_on = cetrafs_sb_file_lock_enabled(sb);

    mutex_lock(&ci->lock_mutex);

    /* If this fd held the userspace explicit lock (flock(LOCK_EX)) and
     * never released it via flock(LOCK_UN), its close releases it --
     * the fd-scoped lifetime (Option A) that bounds a crashing holder. */
    if (ci->explicit_lock_file == file) {
        (void) cetrafs_lock_clear_on_disk(inode, /*stamp_stat=*/false);
        ci->explicit_lock_file = NULL;
    }

    atomic_dec(&ci->lock_local_open_count);

    /* Withdraw this node from the file's open-presence set, mirroring
     * lock_open's publish: read-closes always; write-closes too under
     * nofilelock (where the open published presence). One CAW on the last
     * local opener (1->0). If it fails the bit is left set -- the SAFE
     * direction: a peer merely keeps reading metadata fresh a little
     * longer, and the next reclaim of this node's row (or its next
     * open/close cycle) clears it. */
    if (!(want_write && lock_on) && atomic_dec_return(&ci->read_opener_count) == 0) {
        u32 my_node_id;
        cetrafs_inode_t raw;

        if (cetrafs_sb_get_node_id(sb, &my_node_id) == 0 && cetrafs_read_raw_inode(sb, inode->i_ino, &raw) == 0) {
            struct cetrafs_lock_cas_ctx rctx = {
                .my_node_id = my_node_id,
                .generation = cetrafs_le64(raw.generation),
                .reader_op = CETRAFS_READER_CLEAR,
            };
            int rret = cetrafs_lock_cas(inode, &rctx, &raw);

            if (rret < 0)
                pr_warn_ratelimited("ino=%llu could not withdraw this node from the opener set: %d\n",
                                    (unsigned long long) inode->i_ino, rret);
        }
    }

    if (!want_write) {
        mutex_unlock(&ci->lock_mutex);
        return 0;
    }

    if (atomic_dec_return(&ci->lock_writer_count) == 0) {
        cetrafs_inode_t raw;
        bool lock_cleared;
        /* Closing while the lock is suspended: there is no lock to clear
         * (we gave it back), but the presence bit suspension published in
         * its place is ours to withdraw -- it is the only thing still
         * telling peers this file is in use here. Done AFTER the flushes
         * below for the same reason suspension does them first: the
         * signal must not disappear before the data is durable. */
        bool was_suspended = ci->lock_suspended;
        int ret;
        ktime_t t0 = ktime_get();
        ktime_t t_data, t_inode, t_bg, t_leaf;

        /*
         * Flush this node's own dirty data pages to the real device
         * before releasing the cross-node lock. Needed now that
         * file.c's cetrafs_get_block() no longer syncs its per-block
         * inode update on every allocation (see
         * inode.c's cetrafs_write_raw_inode() comment) -- the actual
         * file *data* was already only ever written back
         * asynchronously, so without this, a different node opening
         * this file the instant after this close() releases the lock
         * could see stale/incomplete content that just hadn't reached
         * the shared device yet. The final write_raw_inode() below
         * (sync=true) then durably persists the lock-clear along with
         * whatever extent/size bookkeeping is already sitting
         * unsynced in the buffer cache from this write session.
         */
        ret = filemap_write_and_wait(inode->i_mapping);
        if (ret)
            pr_err("lock release: ino=%llu failed to flush dirty data: %d\n", (unsigned long long) inode->i_ino, ret);
        t_data = ktime_get();

        /*
         * The in-core i_size/i_mtime/nlink reach the on-disk record only
         * via cetrafs_write_vfs_inode(), which the VFS calls on its own
         * delayed writeback schedule, never synchronously from
         * write()/close(). Without this call a write() followed by
         * close()+reopen reads back the PRE-write size and mtime --
         * nothing persisted them -- and silently regresses the in-core
         * state to stale. Calling it here makes the last writer's close
         * a durability boundary for the stat fields, not just the data.
         *
         * They are not persisted by their own write, though: the
         * lock-clearing CAS at the bottom of this function stamps them
         * into the SAME swap. Two synchronous read-modify-writes of one
         * 4096-byte record cost tens of milliseconds each on a real
         * LUN, and folding them also tightens ordering -- a peer can
         * never see the lock released with the new size not yet durable.
         */
        t_inode = ktime_get();

        /*
         * Durably flush any BG/ZG free_data_blocks adjustment this write
         * session deferred (alloc.c's cetrafs_bg_adjust_free_blocks(),
         * zonegroup.c's cetrafs_zg_adjust_free_blocks(), batched via
         * fs.c's cetrafs_sb_mark_bg_free_dirty()/_mark_zg_free_dirty())
         * -- same reasoning as the data/inode flushes just above: a
         * peer's statfs reading "cold" right after this close must see
         * this write's real space consumption, not whatever's left over
         * until the next unrelated sync happens to run.
         */
        ret = cetrafs_flush_dirty_free_counts(sb);
        if (ret)
            pr_err("lock release: ino=%llu failed to flush BG/ZG free counts: %d\n", (unsigned long long) inode->i_ino,
                   ret);
        t_bg = ktime_get();

        /*
         * If this file spilled into an external extent-leaf block
         * (file.c's cetrafs_get_block()), a plain contiguous append
         * only *merges* into the leaf's last entry -- no journal, no
         * sync, deferred just like the inode's own hot-path writes (see
         * that function's comment). filemap_write_and_wait() above
         * never touches this: it's a raw metadata block, not part of
         * this inode's own page-cache mapping. Without an explicit
         * flush here, a peer opening this file right after this close
         * could still read a stale (shorter) leaf and miss the tail of
         * what was just written -- same durability-boundary reasoning
         * as the data and inode flushes above, just for this one extra
         * piece of metadata.
         */
        /* The allocation bits BEFORE anything below publishes a
         * reference to them -- the extent-leaf flush, and the record
         * stamp further down, which is a CAS and therefore reaches the
         * device immediately. Unconditional: an INLINE extent (depth 0,
         * no leaf to flush) names blocks just as durably once the
         * record is stamped. */
        cetrafs_alloc_flush_bitmaps(sb);

        /*
         * v0x0005: the hot path's record updates live in the in-core
         * file-domain shadow, never in a dirty buffer -- the "zombie
         * flush" this spot used to need is gone by construction. The
         * shadow itself is published below by write_vfs_inode()'s file
         * -sector CAS (the !stat_persisted path, which nofilelock and
         * the lock-clear path both reach). Here we only make sure the
         * TREE-block flush below sees the shadow's view of the tree.
         * (Combined read+overlay: torn-read-safe vs a concurrent
         * publish -- see cetrafs_read_raw_inode_overlaid().)
         */
        ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw);

        if (!ret && cetrafs_le16(raw.eh.eh_magic) == CETRAFS_EXT_MAGIC && cetrafs_le16(raw.eh.eh_depth) >= 1)
            cetrafs_flush_tree_blocks(inode, &raw);
        t_leaf = ktime_get();

        lock_cleared = false;
        if (was_suspended) {
            cetrafs_lock_presence_put(inode);
            ci->lock_suspended = false;
        }

        if (was_suspended) {
            /* lock_mode is NONE by our own doing -- not an error, and
             * nothing to clear. */
        } else if (!lock_on) {
            /* nofilelock mount: this open never claimed the lock, so there
             * is nothing to clear -- lock_mode is NONE, not EXCLUSIVE, and
             * treating that as an error would log on every close. The
             * stat-persist fallback below is what keeps the close a
             * durability boundary. */
        } else if (READ_ONCE(ci->defrag_pinned)) {
            /* The incremental defrag mover is mid-pass and depends on
             * the on-disk lock staying ours: every flush above still
             * ran (the durability boundary peers rely on is intact),
             * only the lock-clear is deferred -- the mover's own
             * cetrafs_lock_defrag_end() performs it if no new writer
             * has appeared by then. */
        } else if (ret) {
            pr_err("lock release: failed to read ino=%llu raw inode: %d\n", (unsigned long long) inode->i_ino, ret);
        } else if (cetrafs_le32(raw.lock_mode) != CETRAFS_LOCK_EXCLUSIVE) {
            pr_err("lock release: ino=%llu lock_mode=%u, expected EXCLUSIVE -- leaving as-is\n",
                   (unsigned long long) inode->i_ino, raw.lock_mode);
        } else {
            u32 my_node_id;

            ret = cetrafs_sb_get_node_id(sb, &my_node_id);
            if (ret) {
                pr_err("lock release: failed to get node id: %d\n", ret);
            } else if (cetrafs_le32(raw.lock_owner_node) != my_node_id) {
                pr_err("lock release: ino=%llu held by node %u, not us (%u) -- leaving as-is\n",
                       (unsigned long long) inode->i_ino, raw.lock_owner_node, my_node_id);
            } else {
                /* One compare-and-swap that both persists this inode's
                 * stat fields and clears our lock -- see the comment on
                 * the removed write_vfs_inode() call above. It only
                 * lands on a record still showing OUR claim, so a lock
                 * reclaimed from us meanwhile is left alone rather than
                 * blindly stomped (which the old blind write did not
                 * check for). */
                struct cetrafs_lock_cas_ctx ctx = {
                    .my_node_id = my_node_id,
                    .generation = cetrafs_le64(raw.generation),
                    .claim = false,
                };

                ret = cetrafs_lock_cas(inode, &ctx, &raw);
                if (ret < 0)
                    pr_err("lock release: failed to write ino=%llu raw inode: %d\n", (unsigned long long) inode->i_ino,
                           ret);
                else
                    lock_cleared = true;
                /* v0x0005: the lock-clear swap no longer carries the stat
                 * fields -- they live in the FILE sector, published by
                 * write_vfs_inode()'s own CAS below, always. */
            }
        }

        /*
         * The combined swap above only runs when we actually clear the
         * lock. Every other path -- the defrag mover holding it pinned,
         * a lock already reclaimed from us, a failed read -- still owes
         * the stat fields their own write, which is exactly what this
         * function has always guaranteed at a last-writer close. Losing
         * that was a real regression when the two writes were first
         * folded together: a close while the defragmenter held the lock
         * pinned silently never persisted the new size.
         */
        {
            /* The close boundary's FILE-sector publish (v0x0005): size,
             * blocks, times and any pending hot-path extent shadow, by
             * region-1 CAS -- every close path takes it, locked or
             * nofilelock, lock-clear or deferred. */
            int sret = cetrafs_write_vfs_inode(inode);

            if (sret)
                pr_err("lock release: ino=%llu failed to persist inode state: %d\n", (unsigned long long) inode->i_ino,
                       sret);
        }

        /*
         * Breakdown timing for this close's durability flush, added
         * directly in response to "1M in 9 seconds, how are
         * those spent?" on real hardware -- every other timing added
         * this session covered coordination round trips rather than
         * this file's data, which is the one phase most likely to
         * dominate a real write's wall time and the one this codebase
         * had no visibility into at all. Always logged since
         * this fires at most once per write-open file close, not on a
         * hot per-block path.
         */
        /* Automatic defrag trigger (defrag.c): this close just made the
         * final extent layout of a write session durable -- the one
         * natural moment to judge fragmentation. Depth-0 counts are in
         * hand; depth-1 costs one (cached) leaf-header read. Everything
         * past the threshold check happens in a background worker. */
        /* Only consider the janitor once the lock really is free for it
         * to claim. This used to read `raw.lock_mode`, which worked only
         * because the old lock-clear mutated that local copy in place --
         * an accidental coupling that silently disabled auto-defrag the
         * moment the clear moved into a compare-and-swap operating on
         * its own image. Ask the thing we actually mean instead. */
        if (lock_cleared && cetrafs_le16(raw.eh.eh_magic) == CETRAFS_EXT_MAGIC) {
            /* The real total extent count across ALL depths -- this is
             * the reliable fragmentation trigger (the in-flight nudge in
             * get_block only has a per-leaf count and never fires at the
             * depth-1->2 transition). cetrafs_defrag_consider() then gates
             * on the SIZE-RELATIVE fragmentation index, so a depth-2 file
             * that genuinely needs collapsing gets queued here at close. */
            u32 extents = cetrafs_tree_extent_count(inode, &raw);

            if (extents) {
                u64 nblk = CETRAFS_DIV_ROUND_UP(cetrafs_le64(raw.size), CETRAFS_BLOCK_SIZE);

                cetrafs_defrag_consider(inode, extents, nblk);
            }
        }

        pr_debug("lock release: ino=%llu close timing (us): data=%lld inode=%lld bg=%lld leaf=%lld total=%lld\n",
                 (unsigned long long) inode->i_ino, (long long) ktime_us_delta(t_data, t0),
                 (long long) ktime_us_delta(t_inode, t_data), (long long) ktime_us_delta(t_bg, t_inode),
                 (long long) ktime_us_delta(t_leaf, t_bg), (long long) ktime_us_delta(ktime_get(), t0));
    }

    mutex_unlock(&ci->lock_mutex);
    return 0;
}

/*
 * Does *this* node currently have 'inode' open for write (i.e. is it the
 * live holder of the cross-node exclusive lock right now, locally)?
 *
 * Exposed for dir.c's cetrafs_d_revalidate(), which refreshes an already-
 * cached positive dentry's stat fields from a fresh disk read on every
 * lookup (see its own comment) -- but must never do that while
 * *this* node is the one actively writing the file: its in-core i_size/
 * mtime/etc. are ahead of whatever is currently durable on disk, and
 * blindly overwriting them with a stale on-disk snapshot would regress
 * this node's own in-flight write, the exact regression inode.c's
 * cetrafs_apply_raw_to_vfs_inode() callers have always had to guard
 * against. Unlike that guard's old mtime-comparison approach, this one
 * doesn't miss metadata-only changes that don't bump mtime (chmod,
 * truncate, link's nlink bump) -- it's also strictly simpler and more
 * directly tied to the actual invariant that matters: whether a local
 * writer is mid-flight, not when the disk last happened to change.
 */
/*
 * Does a LIVE node other than us currently have this file open? Routed
 * through cetrafs_lock_foreign_reader_exists(), which reads the on-disk
 * read_open_nodes presence mask FRESH (a peer sets its bit on the device,
 * invisible to our buffer cache otherwise) AND -- crucially -- ignores a
 * bit belonging to a STALE (dead) node, opportunistically clearing it. So
 * a peer that died holding the file open does NOT pin us on the slow fresh
 * path forever: once its row goes stale it is ignored, and the stale bit is
 * cleared so later checks are cheap again. Conservative on error: if we
 * cannot tell (no node id, or the read fails), assume a peer is present and
 * read fresh -- safe, just slow. (Under nofilelock the mask carries writers
 * too, since lock_open publishes them there, so "reader" here means "any
 * opener".)
 */
/*
 * Test-only: force the foreign-opener verdict true, so a test can exercise
 * the "a peer is present -> read metadata fresh" path deterministically. A
 * real peer's presence cannot be simulated on the loop harness: poking a
 * foreign bit into read_open_nodes is overwritten by this node's OWN open
 * publishing its bit (the publish CAS's forced-fresh read returns the dirty
 * / loop-cached record, not the poke, then ORs our bit over it), and the
 * detection of a real live foreign opener is already covered by
 * read_presence.sh. Same approach as nocaw_force_live_peer / fence_skip_
 * precheck for an equally un-simulable condition.
 */
/* Test-only: ignore file_seq, restoring the pre-fix predicate ("no peer
 * has it open right now" => trust the cache). This is the negative
 * control for the staleness tests: with it set they MUST fail, which is
 * the only thing proving they test anything. Never set in production. */

u64 cetrafs_file_cache_drop_count(void)
{
    return (u64) atomic64_read(&cetrafs_file_cache_drops);
}


/* Test-only: skip the "was this my own publish?" decode, so the gate
 * treats every stamp as a peer's. The negative control for
 * file_local_write_cache.sh -- with it set, a purely local write
 * workload must start dropping its own cache. */
static bool cetrafs_file_seq_ignore_owner;
module_param_named(file_seq_ignore_owner, cetrafs_file_seq_ignore_owner, bool, 0644);
MODULE_PARM_DESC(file_seq_ignore_owner, "TEST ONLY: treat our own file_seq publishes as a peer's");

static bool cetrafs_file_seq_ignore;
module_param_named(file_seq_ignore, cetrafs_file_seq_ignore, bool, 0644);
MODULE_PARM_DESC(file_seq_ignore, "TEST ONLY: ignore file_seq freshness (reproduces the stale-cache bug)");

static bool cetrafs_force_foreign_opener;
module_param_named(force_foreign_opener, cetrafs_force_foreign_opener, bool, 0644);
MODULE_PARM_DESC(force_foreign_opener, "TEST ONLY: nofilelock metadata reads always treat a peer as present (fresh)");

/*
 * One forced-fresh record read, two answers -- and a reconcile.
 *
 * "Is a peer open?" was never enough on its own. It describes RIGHT
 * NOW, and it is consulted to decide whether a cache filled at some
 * EARLIER time is still good. A peer that wrote this file and closed it
 * is not open, so the old predicate said "trust your cache" about a
 * cache that predates those writes -- and a survivor mapped a VM image
 * through a frozen extent tree while a freshly-mounted node read the
 * same file perfectly. Directories hit the identical wall
 * a day earlier and were given dirent_seq; regular files were left
 * behind.
 *
 * So the same fresh record that answers the presence question also
 * carries file_seq, and a value different from the one our cache was
 * reconciled at means somebody republished this file's layout. The
 * stale tree blocks are dropped THEN, not merely marked suspect: a leaf
 * nobody re-reads during the untrusted window would otherwise survive
 * and be trusted again the moment the gate goes quiet.
 */
/*
 * Finish a reconcile the freshness gate could only flag.
 *
 * Runs on the system workqueue: no buffer is locked here and no folio is
 * held, which is the whole point -- cetrafs_invalidate_block() takes
 * lock_buffer() unconditionally, and doing that from the gate deadlocked
 * against a leaf the same call stack already held.
 *
 * Until this runs, the inode reads every tree block forced-fresh. That is
 * correct but it is a device round trip per read, so the window has to be
 * milliseconds, not "until someone reopens the file" -- a running VM never
 * reopens its disk.
 */
static void cetrafs_inode_cold_work(struct work_struct *w)
{
    struct cetrafs_inode_info *ci = container_of(w, struct cetrafs_inode_info, cold_work);
    struct inode *inode = &ci->vfs_inode;
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t *raw;

    raw = kmalloc(sizeof(*raw), GFP_NOFS);
    if (raw) {
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        if (cetrafs_read_raw_inode(sb, inode->i_ino, raw) == 0)
            cetrafs_tree_invalidate_cached(inode, raw);
        kfree(raw);
    }
    /* Clean pages only -- dirty ones are our own unwritten data. */
    if (inode->i_mapping)
        invalidate_mapping_pages(inode->i_mapping, 0, -1);

    /* Only now is the cache known good again. Clearing earlier would
     * re-bless leaf buffers nobody had re-read yet. */
    WRITE_ONCE(ci->tree_cache_cold, false);
    atomic64_inc(&cetrafs_file_cache_reconciles);
    iput(inode);
}

/* Defined below, next to the public wrapper it came from. */
static int cetrafs_foreign_reader_from_raw(struct super_block *sb,
                                           u64 ino,
                                           const cetrafs_inode_t *rawp,
                                           u32 my_node_id,
                                           bool *out_exists);

static bool cetrafs_inode_has_foreign_opener(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    cetrafs_inode_t raw;
    u32 my_node_id;
    bool exists = false;
    u64 seq;

    if (cetrafs_force_foreign_opener)
        return true;
    if (cetrafs_sb_get_node_id(sb, &my_node_id) != 0)
        return true;

    /* Forced-fresh: a peer publishes on the device, and our buffer cache
     * is exactly what we are here to question. */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    if (cetrafs_read_raw_inode(sb, inode->i_ino, &raw) != 0)
        return true; /* cannot tell -> assume present, read fresh */

    seq = cetrafs_le64(raw.file_seq);
    if (!cetrafs_file_seq_ignore && seq != ci->file_seq_cached) {
        /* Whose publish is this? Our OWN writeback moves the stamp on
         * every durability boundary, and the cache it leaves behind is
         * correct by construction -- we are the ones who changed the
         * tree. Treating that as a peer's change throws away this
         * file's extent tree and its entire page cache once a second,
         * on the node actually running the VM: I/O collapses to
         * re-reading the LUN continuously, and dmesg says nothing
         * because nothing is failing. Found in testing.
         *
         * Decoded from the stamp rather than tracked, so a publish path
         * that forgets to record what it stamped cannot resurrect it. */
        if (cetrafs_file_seq_ignore_owner || CETRAFS_FILE_SEQ_NODE(seq) != (my_node_id & 0xFFFFu)) {
            /* Only RECORD it. This runs on the per-block path --
             * cetrafs_get_block() and cetrafs_read_tree_bh() both reach
             * here -- and the extent-tree writers hold a leaf buffer
             * LOCKED across their journal write by protocol. Dropping
             * cached blocks from here called lock_buffer() on a buffer
             * this very call stack already held, wedging the task in D
             * state with nothing in dmesg: a VM's I/O simply stopped and
             * even strace could not attach.
             *
             * Nothing is lost by deferring. cetrafs_read_tree_bh() reads
             * FORCED-FRESH whenever this inode is not trusted, and the
             * flag below is what keeps it untrusted -- so every tree
             * block is refetched as it is used, with no blocking work on
             * this path at all. The page cache, which needs a real
             * sweep, is handled at open (a safe context). */
            atomic64_inc(&cetrafs_file_cache_drops);
            WRITE_ONCE(ci->tree_cache_cold, true);
            /* Hand the actual dropping to a context that can take buffer
             * locks. igrab keeps the inode alive across the handoff; if
             * the work is already queued, drop the reference we just
             * took so it stays balanced. */
            if (igrab(inode)) {
                if (!schedule_work(&ci->cold_work))
                    iput(inode);
            }
        }
        ci->file_seq_cached = seq;
    }

    if (cetrafs_foreign_reader_from_raw(sb, inode->i_ino, &raw, my_node_id, &exists) != 0)
        return true;
    return exists;
}

/*
 * Rate-limited wrapper: re-read the presence mask at most once per second
 * per inode and cache the verdict. The hot path (metadata read per I/O)
 * then costs a jiffies compare and a cached bool, not a device read --
 * which is the whole point, since under nofilelock this gates whether a
 * VM's every block I/O re-reads the extent tree from the LUN.
 */
bool cetrafs_inode_foreign_opener_cached(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    unsigned long now = jiffies;

    if (!ci->foreign_open_valid || time_after(now, ci->foreign_open_checked + HZ)) {
        ci->foreign_open_cached = cetrafs_inode_has_foreign_opener(inode);
        ci->foreign_open_checked = now;
        ci->foreign_open_valid = true;
    }
    return ci->foreign_open_cached;
}

/*
 * Test-only. Each disables one half of what makes suspension safe, so the
 * tests asserting that safety can be shown to actually discriminate --
 * flip the knob and the test must fail.
 */
static bool cetrafs_lock_suspend_skip_publish;
module_param_named(lock_suspend_skip_publish, cetrafs_lock_suspend_skip_publish, bool, 0644);
MODULE_PARM_DESC(lock_suspend_skip_publish,
                 "TEST ONLY: suspend without publishing presence (reproduces the invisible-writer bug: "
                 "a peer's unlink or scrub frees blocks under a live writer)");

static bool cetrafs_lock_suspend_trust_cache;
module_param_named(lock_suspend_trust_cache, cetrafs_lock_suspend_trust_cache, bool, 0644);
MODULE_PARM_DESC(lock_suspend_trust_cache,
                 "TEST ONLY: keep trusting cached metadata while suspended (reproduces the frozen "
                 "extent-tree bug)");

bool cetrafs_lock_held_for_write_locally(struct inode *inode)
{
    /* The premise every caller builds on is "no peer can be modifying this
     * file, so a cached extent-tree/record read is authoritative and the
     * lookup-time refresh can be skipped."
     *
     * Default lock ON: that premise is exactly "we hold the file's
     * cross-node exclusive lock" -- lock_writer_count > 0.
     *
     * nofilelock: there is no exclusive lock, so the premise instead is "we
     * are the SOLE node with this file open". While that holds, no peer can
     * touch it and the cache is correct AND fast (the steady-state VM case).
     * The instant a peer also opens it -- a live-migration handoff, where a
     * stale cached extent map would send the guest's I/O to the wrong blocks
     * and corrupt the image -- we must read metadata fresh. That peer's
     * presence is published in read_open_nodes (lock_open below publishes
     * writers too under nofilelock), checked here at most once/sec. This is
     * what lets nofilelock be both correct across a handoff and fast the
     * 99.9% of the time there is only one node. It does NOT serialise two
     * nodes writing at once -- that remains the upper layer's job. */
    /* ...unless this node has SUSPENDED that lock on request while
     * keeping the file open (cetrafs_lock_suspend()). lock_writer_count
     * is still positive -- the VM has its fd -- but the lock is gone from
     * the record and a peer may be writing. Inferring ownership from the
     * writer count is exactly what stops being true there, so fall
     * through to the nofilelock logic, which asks the device. */
    if (cetrafs_sb_file_lock_enabled(inode->i_sb) &&
        (cetrafs_lock_suspend_trust_cache || !READ_ONCE(CETRAFS_I(inode)->lock_suspended)))
        return atomic_read(&CETRAFS_I(inode)->lock_writer_count) > 0;

    if (cetrafs_inode_foreign_opener_cached(inode))
        return false;
    /* Checked AFTER the gate, which is what sets it. */
    return !READ_ONCE(CETRAFS_I(inode)->tree_cache_cold);
}

/*
 * May this node skip revalidating the cached IDENTITY of 'inode' -- its
 * generation, and so its type and ops?
 *
 * NOT the same question as cetrafs_lock_held_for_write_locally(), which
 * asks whether cached CONTENT is trustworthy and runs per block in
 * cetrafs_get_block() and cetrafs_read_tree_bh(). Conflating them costs
 * both ways:
 *
 *  - Under nofilelock the content predicate is "no peer has it open",
 *    which a file open on NO node satisfies trivially. Used for
 *    identity it trusts a closed file's cached inode forever and skips
 *    the generation check that detects inode-number reuse -- a peer
 *    deletes a 3 GiB file, reuses inode 3 for a directory, and two
 *    nodes keep reporting a 3 GiB regular file.
 *
 *  - Requiring a local open in the SHARED predicate fixes that but puts
 *    a device round trip back on the per-block path for any file with
 *    no local open, which is exactly what those two paths avoid.
 *
 * So identity is revalidated only at LOOKUP, which is cold, and there
 * we insist this node holds the file open. The hot paths keep the
 * looser question.
 */
bool cetrafs_lock_identity_cache_trusted(struct inode *inode)
{
    /* Suspended: same correction as the content predicate above. */
    if (cetrafs_sb_file_lock_enabled(inode->i_sb) &&
        (cetrafs_lock_suspend_trust_cache || !READ_ONCE(CETRAFS_I(inode)->lock_suspended)))
        return atomic_read(&CETRAFS_I(inode)->lock_writer_count) > 0;
    if (atomic_read(&CETRAFS_I(inode)->lock_local_open_count) <= 0)
        return false;
    return !cetrafs_inode_foreign_opener_cached(inode);
}

/*
 * Is 'ino' currently exclusively locked (for write) by a *live* node other
 * than 'my_node_id'? Unlike cetrafs_lock_open() above, this never claims or
 * mutates anything -- it's a plain read-only check for a caller about to do
 * something that would destroy 'ino's data (free its blocks/bitmap bit) and
 * needs to know first whether a different, still-alive node might be
 * actively writing to it through an open fd of its own.
 *
 * added for dir.c's cetrafs_unlink()/cetrafs_rename(), which
 * used to free a target inode's blocks purely based on nlink reaching 0,
 * with no regard for whether another node still had it open for write --
 * letting Node A keep writing into blocks Node B had just freed (and which
 * could be reallocated to something else entirely), a real cross-node
 * corruption path independent of the claim-race bug fixed above. A lock
 * held by a *stale* node is deliberately not blocking here, matching
 * cetrafs_lock_open()'s own reclaim posture: nothing is actually using the
 * file in that case, so there's nothing left to protect.
 */
/* Clear the on-disk lock we hold -- shared by the ordinary last-writer
 * close and defrag_end below. One atomic compare-and-swap: it only
 * clears a record that still shows OUR exclusive claim, so a lock that
 * was meanwhile reclaimed from us (stale-peer steal) is left alone
 * instead of being blindly stomped. Caller holds ci->lock_mutex. */
static int cetrafs_lock_clear_on_disk(struct inode *inode, bool stamp_stat)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_lock_cas_ctx ctx = {.claim = false};

    (void) stamp_stat; /* v0x0005: stats publish via the file-sector CAS, not this swap */
    cetrafs_inode_t raw;
    int ret;

    ret = cetrafs_sb_get_node_id(sb, &ctx.my_node_id);
    if (!ret)
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (!ret) {
        ctx.generation = cetrafs_le64(raw.generation);
        ret = cetrafs_lock_cas(inode, &ctx, &raw);
        if (!ret && stamp_stat)
            cetrafs_inode_stat_baseline_from_incore(inode);
    }
    if (ret < 0)
        pr_err("lock clear: ino=%llu failed: %d\n", (unsigned long long) inode->i_ino, ret);
    return ret < 0 ? ret : 0;
}

/*
 * ---- default-mount lock suspension (flock(LOCK_UN) / flock(LOCK_EX)) ----
 *
 * Everything is locked by default; a file is unlocked only on request and
 * only for as long as the request lasts. That is strictly safer than
 * nofilelock, which removes the lock from every file on every node
 * permanently in order to permit an operation that is per-file and lasts
 * seconds.
 *
 * The lock surrendered here is the SAME on-disk lock a write-open claims
 * -- same record fields, same CAS -- so there is no new primitive and no
 * format change: CETRAFS_LOCK_NONE is already "unlocked".
 *
 * THE INVARIANT: while suspended, this inode must be indistinguishable
 * from a nofilelock inode, on the device and in core. On the device that
 * means our bit in read_open_nodes, which a default-mount writer does not
 * otherwise set (cetrafs_lock_open() skips the publish for exactly that
 * case, because the lock normally marks us). Without it the file reads as
 * lock_mode=NONE, read_open_nodes=0 -- byte-identical to a file nobody
 * has open -- to unlink, rename, link, truncate, setxattr, evict and the
 * scrub's orphan reclaim, every one of which then feels free to destroy
 * it while our writer is mid-I/O. In core it means both cache predicates
 * take the nofilelock branch, or we map the guest's I/O through an extent
 * tree the peer has since rewritten.
 */

/*
 * Publish / withdraw this node in read_open_nodes for the suspension
 * path, through the same read_opener_count protocol cetrafs_lock_open()
 * and _release() use for readers (and for nofilelock writers). Going via
 * the counter rather than straight to the CAS is load-bearing: a local
 * reader of the same file may hold the bit too, and whoever takes the
 * count to zero is the only one that may clear it.
 *
 * Caller holds lock_mutex.
 */
static int cetrafs_lock_presence_get(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u32 my_node_id;
    int ret;

    if (atomic_inc_return(&ci->read_opener_count) != 1)
        return 0; /* already published by a local opener */

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (!ret)
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (!ret) {
        struct cetrafs_lock_cas_ctx rctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .reader_op = CETRAFS_READER_SET,
        };

        ret = cetrafs_lock_cas(inode, &rctx, &raw);
        if (ret > 0)
            ret = 0; /* bit already set -- nothing to do, not a failure */
    }
    if (ret < 0)
        atomic_dec(&ci->read_opener_count);
    return ret;
}

static void cetrafs_lock_presence_put(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u32 my_node_id;

    if (atomic_dec_return(&ci->read_opener_count) != 0)
        return; /* a local opener still needs the bit */

    if (cetrafs_sb_get_node_id(sb, &my_node_id) != 0 || cetrafs_read_raw_inode(sb, inode->i_ino, &raw) != 0)
        return; /* bit left set: the safe direction, peers merely stay cautious */

    {
        struct cetrafs_lock_cas_ctx rctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .reader_op = CETRAFS_READER_CLEAR,
        };
        int ret = cetrafs_lock_cas(inode, &rctx, &raw);

        if (ret < 0)
            pr_warn_ratelimited("ino=%llu could not withdraw presence after resume: %d\n",
                                (unsigned long long) inode->i_ino, ret);
    }
}

/*
 * flock(fd, LOCK_UN) on a default mount: give this inode's automatic lock
 * back while keeping it open.
 *
 * Per INODE and node, not per fd: what is surrendered is the node's
 * automatic lock, which is itself per-inode. (The nofilelock explicit
 * lock stays fd-scoped -- a different object with a different lifetime.)
 *
 * Idempotent, and a no-op success when this node holds no automatic lock
 * on the file, both per flock(2): unlocking what you do not hold succeeds.
 */
static int cetrafs_lock_suspend(struct inode *inode, struct file *file)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    int ret;

    if (sb_rdonly(sb))
        return -EROFS;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    mutex_lock(&ci->lock_mutex);

    if (ci->lock_suspended) {
        ret = 0;
        goto out;
    }
    if (atomic_read(&ci->lock_writer_count) == 0) {
        ret = 0; /* no automatic lock here to give back */
        goto out;
    }
    if (READ_ONCE(ci->defrag_pinned)) {
        /* The incremental mover's whole safety argument is that this
         * lock stays ours for the pass. Refuse rather than pull it. */
        ret = -EBUSY;
        goto out;
    }

    /*
     * The handoff durability boundary, and it must complete BEFORE the
     * lock goes: the peer that opens the instant after must not find a
     * short file, an extent tree naming unflushed blocks, or allocation
     * bits that have not reached the platter (rule 8 -- a reference may
     * not become durable before what it refers to; the lock-clear is a
     * CAS and reaches the device immediately). Same flushes the
     * last-writer close performs.
     *
     * Under lock_mutex, exactly as cetrafs_lock_release() does it. That
     * is not incidental: this node may have OTHER local writers on the
     * same file, and flushing outside the mutex would let one of them
     * dirty a page between the flush and the lock-clear below -- handing
     * the peer a file whose newest bytes are still in our page cache.
     * The close path has no such window only because it runs when the
     * last writer is already gone. (Writeback re-entering
     * cetrafs_get_block() is safe under this mutex: that path takes
     * resv_lock, never this one -- see the resv_lock comment above.)
     */
    ret = cetrafs_file_make_durable(file);
    if (ret)
        goto out;
    ret = cetrafs_flush_dirty_free_counts(sb);
    if (ret)
        goto out;

    /*
     * Presence FIRST, lock second. Between the two we hold both signals,
     * which is merely over-protective; the other order leaves a window in
     * which this file looks unused to every peer and its blocks are free
     * for the taking.
     */
    if (!cetrafs_lock_suspend_skip_publish) {
        ret = cetrafs_lock_presence_get(inode);
        if (ret)
            goto out;
    }

    ret = cetrafs_lock_clear_on_disk(inode, /*stamp_stat=*/false);
    if (ret) {
        /* Still locked, so nothing was handed over: undo the publish and
         * report, rather than leaving the record saying EXCLUSIVE while
         * we believe we surrendered it. */
        if (!cetrafs_lock_suspend_skip_publish)
            cetrafs_lock_presence_put(inode);
        goto out;
    }

    ci->lock_suspended = true;

    /*
     * The freshness verdict is cached for up to a second
     * (cetrafs_inode_foreign_opener_cached). Without this we would keep
     * trusting the cache for that long after giving the lock away.
     */
    ci->foreign_open_cached = true;
    ci->foreign_open_valid = false;
    ci->file_seq_cached = U64_MAX;

    atomic64_inc(&cetrafs_lock_suspends);
    ret = 0;
out:
    mutex_unlock(&ci->lock_mutex);
    return ret;
}

/*
 * flock(fd, LOCK_EX) on a default mount: take the automatic lock back.
 *
 * NEVER steals -- not even from a holder whose node has gone stale. That
 * reclaim fences the peer and replays its journal, which belongs in
 * cetrafs_lock_open() where it is already implemented and tested; a
 * caller that needs it can close and reopen the file. Here a foreign
 * lock simply means "you cannot have it back right now".
 *
 * Returns -ETXTBSY when a peer holds it, which cetrafs_flock() maps to
 * -EWOULDBLOCK (or retries, for a blocking LOCK_EX).
 */
static int cetrafs_lock_resume(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u32 my_node_id;
    int ret;

    if (sb_rdonly(sb))
        return -EROFS;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    mutex_lock(&ci->lock_mutex);

    if (!ci->lock_suspended) {
        /*
         * Nothing to take back. On a default mount the lock is automatic,
         * so "do we hold it" is "do we have a local writer" -- answer
         * yes rather than -EOPNOTSUPP, so a caller that does not know
         * which mount mode it is on can simply ask and get the truth.
         */
        ret = atomic_read(&ci->lock_writer_count) > 0 ? 0 : -EOPNOTSUPP;
        goto out;
    }

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        goto out;

    /* Forced-fresh: the entire point of the window is that a peer may
     * have taken the lock, and a cached record cannot show that. */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        goto out;

    if (cetrafs_le32(raw.lock_mode) != CETRAFS_LOCK_NONE) {
        ret = -ETXTBSY;
        goto out;
    }

    {
        struct cetrafs_lock_cas_ctx ctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .claim = true,
        };

        ret = cetrafs_lock_cas(inode, &ctx, &raw);
        if (ret < 0)
            goto out; /* -ETXTBSY: lost the race to a peer */
        ret = 0;
    }

    /* Lock first, presence second -- the mirror of suspend, and for the
     * same reason: never a moment with neither signal on the device. */
    if (!cetrafs_lock_suspend_skip_publish)
        cetrafs_lock_presence_put(inode);
    ci->lock_suspended = false;

    /*
     * A peer may have rewritten this file while we were out, and once the
     * lock is ours again both cache predicates go back to saying "trust
     * the cache" -- so the reconcile has to happen HERE, not lazily. Same
     * work the open path does for an arriving handoff: re-read the record
     * fresh, drop the cached extent tree built from the old one, and drop
     * clean data pages that may now name the wrong physical blocks.
     *
     * 'raw' is reused rather than declaring a second cetrafs_inode_t --
     * see the open path's note about CONFIG_FRAME_WARN=1024.
     */
    if (!cetrafs_lock_suspend_trust_cache) {
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        if (cetrafs_read_raw_inode(sb, inode->i_ino, &raw) == 0) {
            cetrafs_tree_invalidate_cached(inode, &raw);

            /* Whose publish is this record carrying? Ask file_seq, which
             * names the node that stamped it -- NOT mtime.
             *
             * mtime has one-second granularity, and a handoff completes
             * well inside one second on real hardware: the peer's write
             * then carries the SAME mtime as our pre-window state, a
             * strictly-newer test is false, and we resume holding a
             * stale i_size -- the peer's data beyond it reads as a hole.
             * That is not hypothetical. It passed on slow hardware and
             * failed on a three-node run, which is the only reason it
             * was caught before release.
             *
             * If we ourselves wrote during the window the last stamp is
             * ours, so this correctly keeps our newer state; and
             * cetrafs_apply_raw_to_vfs_inode() refuses a dirty inode
             * anyway, so unflushed local work is never clobbered. */
            if (CETRAFS_FILE_SEQ_NODE(cetrafs_le64(raw.file_seq)) != (u32) (my_node_id & 0xFFFFu))
                (void) cetrafs_apply_raw_to_vfs_inode(inode, &raw);
        }
        ci->file_seq_cached = U64_MAX;
        ci->foreign_open_cached = true;
        ci->foreign_open_valid = false;
        if (inode->i_mapping)
            invalidate_mapping_pages(inode->i_mapping, 0, -1);
    }

    atomic64_inc(&cetrafs_lock_resumes);
out:
    mutex_unlock(&ci->lock_mutex);
    return ret;
}

/*
 * The non-blocking claim behind flock(fd, LOCK_EX) (cetrafs_flock below).
 * Claims the whole-file exclusive lock for this node: the on-disk lock it
 * takes is the exact same one a write-open claims under the default mount,
 * so once held, every other node's open() is refused (-ETXTBSY) by
 * cetrafs_lock_open()'s enforcement -- which honors a present lock in BOTH
 * mount modes. Fd-scoped (Option A): recorded against 'file', released by
 * flock(LOCK_UN) or by that fd's close.
 *
 * Only meaningful under nofilelock. Under the default mount the lock is
 * already automatic on every write-open, so an explicit claim is redundant
 * and would merely collide with our own auto-held lock -- return -EOPNOTSUPP
 * and let the caller rely on the automatic behavior instead.
 *
 * -EBUSY (another local fd holds it, or a peer has it open) and -ETXTBSY
 * (a peer holds the lock) are the contended results the flock wrapper maps
 * to -EWOULDBLOCK / retries on; everything else is terminal.
 */
static int cetrafs_lock_explicit_acquire(struct inode *inode, struct file *file)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u32 my_node_id;
    bool present = false;
    int ret;

    if (cetrafs_sb_file_lock_enabled(sb))
        return -EOPNOTSUPP; /* default mount: the lock is already automatic */
    if (sb_rdonly(sb))
        return -EROFS;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced: no new claims */

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    mutex_lock(&ci->lock_mutex);

    if (ci->explicit_lock_file == file) {
        ret = 0; /* idempotent: this fd already holds it */
        goto out;
    }
    if (ci->explicit_lock_file) {
        ret = -EBUSY; /* another local fd holds it; one holder, one releaser */
        goto out;
    }

    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        goto out;

    {
        /* One CAS claims EXCLUSIVE for us, and only if the record is still
         * unlocked (allow_steal false) -- a peer already holding the lock
         * makes this -ETXTBSY. */
        struct cetrafs_lock_cas_ctx ctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .claim = true,
        };

        ret = cetrafs_lock_cas(inode, &ctx, &raw);
        if (ret)
            goto out;
    }

    /* We now hold the on-disk lock, so no NEW peer can open the file
     * (enforcement rejects them). But a peer that opened it just before our
     * claim is still in, and the lock's whole promise is "no one else is
     * using it" -- so detect a pre-existing peer opener and back out rather
     * than assert a false exclusivity. Checking AFTER the claim (not before)
     * means the set of possible openers is frozen: only a peer already
     * present can be found, never a new one racing in. */
    if (cetrafs_lock_foreign_reader_exists(sb, inode->i_ino, my_node_id, &present) == 0 && present) {
        struct cetrafs_lock_cas_ctx rel = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .claim = false,
        };

        cetrafs_lock_cas(inode, &rel, NULL); /* give the lock back */
        ret = -EBUSY;
        goto out;
    }

    ci->explicit_lock_file = file;
    ret = 0;

out:
    mutex_unlock(&ci->lock_mutex);
    return ret;
}

/*
 * The release behind flock(fd, LOCK_UN) and the fd's close. Clears the
 * on-disk EXCLUSIVE claim (only if it is still ours -- a CAS), leaving the
 * fd open. The migration orchestrator flock(LOCK_UN)s to open the handoff
 * window, then flock(LOCK_EX) again on the same fd to close it.
 */
static int cetrafs_lock_explicit_release(struct inode *inode, struct file *file)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    int ret;

    mutex_lock(&ci->lock_mutex);
    if (ci->explicit_lock_file != file) {
        ret = -EINVAL; /* this fd does not hold the explicit lock */
    } else {
        (void) cetrafs_lock_clear_on_disk(inode, /*stamp_stat=*/false);
        ci->explicit_lock_file = NULL;
        ret = 0;
    }
    mutex_unlock(&ci->lock_mutex);
    return ret;
}

/*
 * ->flock: the standard flock(2) interface onto the userspace-driven
 * whole-file lock. flock(LOCK_EX) is a whole-file advisory exclusive lock
 * whose lifetime is the open file description (released when the fd and all
 * its dups close) -- the exact shape of this lock, so we map straight onto
 * it rather than inventing an ioctl. The other shared-disk/cluster
 * filesystems (NFS, GFS2, OCFS2) hook .flock for cross-node flock the same
 * way. Userspace uses flock(2), or the flock(1) command, and holds the
 * window open or closed by holding/releasing the lock on the fd.
 *
 * Exclusive-only (VMFS-style), matching the on-disk lock: LOCK_SH is
 * refused. The on-disk claim is non-blocking (a CAS), so LOCK_NB is one
 * shot and a blocking LOCK_EX becomes an interruptible poll -- what the
 * cluster filesystems do under their glock layer. We do NOT register a
 * local flock via locks_lock_file_wait(): local exclusion among this
 * node's own fds is the explicit_lock_file single-holder check in
 * cetrafs_lock_explicit_acquire(), and the fd's close is already a
 * durability+release boundary in cetrafs_lock_release().
 */
int cetrafs_flock(struct file *file, int cmd, struct file_lock *fl)
{
    struct inode *inode = file_inode(file);
    bool blocking = (cmd == F_SETLKW);
    bool lock_on = cetrafs_sb_file_lock_enabled(inode->i_sb);
    int ret;

    if (!(fl->c.flc_flags & FL_FLOCK))
        return -ENOLCK; /* only real flock(2), not emulated posix/OFD */

    if (lock_is_unlock(fl)) {
        /* Default mount: give the automatic lock back for this inode,
         * keeping the file open -- the handoff window. Elsewhere: drop
         * the fd's explicit lock. Unlocking what we do not hold is a
         * no-op success in both, per flock(2). */
        if (lock_on)
            return cetrafs_lock_suspend(inode, file);
        cetrafs_lock_explicit_release(inode, file);
        return 0;
    }
    if (!lock_is_write(fl))
        return -EOPNOTSUPP; /* exclusive-only: no shared (LOCK_SH) lock */

    for (;;) {
        /* Default mount: take a suspended lock back (and answer "yes, it
         * is yours" when it never left). Elsewhere: the explicit claim. */
        ret = lock_on ? cetrafs_lock_resume(inode) : cetrafs_lock_explicit_acquire(inode, file);
        if (ret != -EBUSY && ret != -ETXTBSY)
            return ret; /* 0, or terminal (-EOPNOTSUPP default mount, -EROFS, -EIO) */
        if (!blocking)
            return -EWOULDBLOCK; /* LOCK_NB and contended */
        /* Blocking LOCK_EX: wait for the holder (local or a peer) to
         * release. Interruptible so a signal (or kill) does not wedge. */
        if (msleep_interruptible(CETRAFS_FLOCK_POLL_MS))
            return -EINTR;
    }
}

/*
 * Pin this node's on-disk exclusive lock for the incremental defrag
 * mover (defrag.c). Two cases:
 *  - local writers exist: the lock is already ours (lock.c's own
 *    invariant) -- just pin, so the last-writer close defers its
 *    release to cetrafs_lock_defrag_end();
 *  - no local writers: claim it, exactly like a write-open would (PR
 *    mutex + verify-readback; only if fully unlocked -- a stale foreign
 *    lock is deliberately left for a real open's reclaim path, an
 *    optimization pass has no business exercising it). Local READ
 *    openers don't block this: the mover is concurrency-safe (the page
 *    cache is logical), and cross-node readers were never allowed on a
 *    locked file anyway.
 * A write-open that arrives while pinned proceeds normally (owner is
 * this node); its close then simply hands release duty back here.
 */
int cetrafs_lock_defrag_begin(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u32 my_node_id;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    /* The defragmenter's safety RESTS on pinning the file's exclusive lock
     * so no peer can write it mid-relocation. With the lock off (nofilelock)
     * there is nothing to pin and no mutual exclusion, so relocating would
     * race a peer's write -- decline. cetrafs_sb_defrag_enabled() stays the
     * operator switch; this is the hard safety floor under it. */
    if (!cetrafs_sb_file_lock_enabled(sb))
        return -EOPNOTSUPP;

    /* Suspended: the lock this pass would pin is not ours right now, and
     * "local writers exist, so it is already ours" -- the premise the pin
     * below is built on -- is false. A peer may be writing the very
     * blocks the mover would relocate. */
    if (READ_ONCE(CETRAFS_I(inode)->lock_suspended))
        return -EBUSY;

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    mutex_lock(&ci->lock_mutex);

    if (ci->defrag_pinned) {
        ret = -EBUSY; /* another pass is already pinned on this inode */
        goto out;
    }

    if (atomic_read(&ci->lock_writer_count) > 0) {
        ci->defrag_pinned = true; /* lock already ours via local writers */
        ret = 0;
        goto out;
    }

    /* Idle file: claim the lock the same way a write-open does -- one
     * atomic compare-and-swap that only lands on a still-unlocked record
     *. A real open winning the race just makes this fail
     * -ETXTBSY, which is reported as -EBUSY: "not idle, skip". */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        goto out;

    if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
        ret = -ESTALE; /* number reused for a different file meanwhile */
        goto out;
    }
    if (raw.lock_mode != CETRAFS_LOCK_NONE || raw.nlink == 0) {
        ret = -EBUSY;
        goto out;
    }

    {
        struct cetrafs_lock_cas_ctx ctx = {
            .my_node_id = my_node_id,
            .generation = cetrafs_le64(raw.generation),
            .claim = true,
        };

        ret = cetrafs_lock_cas(inode, &ctx, &raw);
        if (ret) {
            ret = (ret == -ETXTBSY) ? -EBUSY : ret;
            goto out;
        }
    }

    ci->defrag_pinned = true;
    ret = 0;

out:
    mutex_unlock(&ci->lock_mutex);
    return ret;
}

void cetrafs_lock_defrag_end(struct inode *inode)
{
    struct cetrafs_inode_info *ci = CETRAFS_I(inode);

    mutex_lock(&ci->lock_mutex);
    ci->defrag_pinned = false;
    /* If writers appeared during the move, release duty is theirs again
     * (their last close now takes the normal path). If none remain --
     * either there never were any, or they closed while we were pinned
     * -- the on-disk lock is ours to put back. */
    if (atomic_read(&ci->lock_writer_count) == 0)
        cetrafs_lock_clear_on_disk(inode, /*stamp_stat=*/false);
    mutex_unlock(&ci->lock_mutex);
}

/* defrag.c's dedup latch: one queued background request per inode. */
bool cetrafs_lock_defrag_try_queue(struct inode *inode)
{
    return atomic_cmpxchg(&CETRAFS_I(inode)->defrag_queued, 0, 1) == 0;
}

void cetrafs_lock_defrag_unqueue(struct inode *inode)
{
    atomic_set(&CETRAFS_I(inode)->defrag_queued, 0);
}

/*
 * Does a LIVE node other than us currently hold 'ino' open for read?
 *
 *
 * The read-side counterpart to cetrafs_lock_foreign_claim_exists()
 * above, and consulted by the same callers for the same reason: before
 * destroying a file's data blocks, find out whether anyone is still
 * looking at them. A reader holds no lock -- it only published a bit in
 * read_open_nodes -- so this is the only trace it leaves.
 *
 * A bit belonging to a STALE node is ignored and opportunistically
 * cleared: that node is gone, its fd went with it, and leaving the bit
 * set would block this file from ever being unlinked again. Same
 * reclaim posture as every other stale claim here. Our own bit is
 * ignored too -- a local reader is already handled correctly, since
 * this node's own frees are deferred to evict_inode().
 */
/* Defined below, next to the public wrapper it came from. */
static int cetrafs_foreign_claim_from_raw(struct super_block *sb,
                                          const cetrafs_inode_t *rawp,
                                          u32 my_node_id,
                                          bool *out_exists,
                                          bool *out_repaired);

/* The decision half of cetrafs_lock_foreign_reader_exists(), from a
 * record the caller has already read fresh. */
static int cetrafs_foreign_reader_from_raw(struct super_block *sb,
                                           u64 ino,
                                           const cetrafs_inode_t *rawp,
                                           u32 my_node_id,
                                           bool *out_exists)
{
    const cetrafs_inode_t raw = *rawp;
    u64 others;
    int ret;

    *out_exists = false;
    (void) ret;

    others = cetrafs_le64(raw.read_open_nodes) & ~(1ULL << (my_node_id % CETRAFS_MAX_READER_NODES));
    while (others) {
        u32 n = (u32) __ffs64(others);
        bool stale = false;

        others &= ~(1ULL << n);

        if (cetrafs_node_is_stale(sb, n, &stale) == 0 && stale) {
            struct cetrafs_lock_cas_ctx rctx = {
                .my_node_id = n, /* clear THAT node's bit, not ours */
                .generation = cetrafs_le64(raw.generation),
                .reader_op = CETRAFS_READER_CLEAR,
            };
            cetrafs_node_fence_peer(sb, n, "a read-open reference");
            if (cetrafs_cas_record(sb, cetrafs_inode_lba(sb, ino), cetrafs_lock_cas_mutate, &rctx) < 0)
                pr_warn_ratelimited("ino=%llu could not clear stale node %u's reader bit\n", (unsigned long long) ino,
                                    n);
            continue;
        }

        *out_exists = true; /* a live peer is reading it */
        return 0;
    }

    return 0;
}

int cetrafs_lock_foreign_reader_exists(struct super_block *sb, u64 ino, u32 my_node_id, bool *out_exists)
{
    cetrafs_inode_t raw;
    int ret;

    *out_exists = false;
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_read_raw_inode(sb, ino, &raw);
    if (ret)
        return ret;
    return cetrafs_foreign_reader_from_raw(sb, ino, &raw, my_node_id, out_exists);
}

/*
 * Both questions from ONE forced-fresh read.
 *
 * "Is a live peer writing this file?" and "is a live peer reading it?"
 * are asked together at every point that is about to destroy a file --
 * unlink, rename's replace path, and eviction -- and each used to
 * invalidate and re-read the same record for itself. Measured on one
 * unlink that is four forced-fresh reads of one record: two here and
 * two again in evict_inode, out of 33 reads for the whole operation,
 * each a round trip of tens of milliseconds on a real LUN.
 *
 * The ordering is not arbitrary. The claim check runs first because the
 * reader check can CAS the record (clearing a dead node's reader bit),
 * and because the claim check's own stale-holder branch REPLAYS that
 * node's journal -- which can rewrite any block, this record included.
 * So on that branch, and only on it, the record is re-read before the
 * reader question is asked of it.
 */
int cetrafs_lock_foreign_user_exists(struct super_block *sb,
                                     u64 ino,
                                     u32 my_node_id,
                                     bool *out_writer,
                                     bool *out_reader)
{
    cetrafs_inode_t raw;
    bool repaired = false;
    int ret;

    *out_writer = false;
    *out_reader = false;

    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_read_raw_inode(sb, ino, &raw);
    if (ret)
        return ret;

    ret = cetrafs_foreign_claim_from_raw(sb, &raw, my_node_id, out_writer, &repaired);
    if (ret || *out_writer)
        return ret;

    if (repaired) {
        cetrafs_invalidate_raw_inode(sb, ino);
        ret = cetrafs_read_raw_inode(sb, ino, &raw);
        if (ret)
            return ret;
    }

    return cetrafs_foreign_reader_from_raw(sb, ino, &raw, my_node_id, out_reader);
}

/* The decision half of cetrafs_lock_foreign_claim_exists(), working
 * from a record the caller has already read fresh. *out_repaired says
 * whether this took the stale-holder branch, which replays that node's
 * journal and can therefore have rewritten ANY block -- including this
 * record -- so a caller that goes on to inspect the same record must
 * re-read it first. */
static int cetrafs_foreign_claim_from_raw(struct super_block *sb,
                                          const cetrafs_inode_t *rawp,
                                          u32 my_node_id,
                                          bool *out_exists,
                                          bool *out_repaired)
{
    const cetrafs_inode_t raw = *rawp;
    int ret;

    *out_exists = false;
    if (out_repaired)
        *out_repaired = false;

    if (cetrafs_le32(raw.lock_mode) == CETRAFS_LOCK_EXCLUSIVE && cetrafs_le32(raw.lock_owner_node) != my_node_id) {
        bool stale = false;

        ret = cetrafs_node_is_stale(sb, cetrafs_le32(raw.lock_owner_node), &stale);
        if (ret)
            return ret;

        /* Treating a stale holder's claim as "no live claim" lets the
         * caller (dir.c's unlink/rename-replace) go on to free this
         * file's blocks -- so first replay the dead holder's journal
         *, repairing anything it was mid-writing before
         * those blocks are freed/reused. Callers run inside dir.c's
         * ns-locked workers, so the cluster mutex is already held. */
        if (stale) {
            cetrafs_node_fence_peer(sb, cetrafs_le32(raw.lock_owner_node), "a file lock");
            ret = cetrafs_journal_replay_node(sb, cetrafs_le32(raw.lock_owner_node), /*wait_for_claim=*/false);
            if (ret)
                return ret;
            if (out_repaired)
                *out_repaired = true;
        }

        *out_exists = !stale;
    }

    return 0;
}

int cetrafs_lock_foreign_claim_exists(struct super_block *sb, u64 ino, u32 my_node_id, bool *out_exists)
{
    cetrafs_inode_t raw;
    int ret;

    *out_exists = false;
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_read_raw_inode(sb, ino, &raw);
    if (ret)
        return ret;
    return cetrafs_foreign_claim_from_raw(sb, &raw, my_node_id, out_exists, NULL);
}
