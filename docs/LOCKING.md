# cetrafs — Locking & Cross-Node Write Safety

This document describes how cetrafs prevents two cluster nodes mounting the
same shared block device from corrupting each other's data, and exactly
where that protection does and does not reach. See `docs/ARCHITECTURE.md`
for on-disk format details and `kmod/`'s per-file header comments for the
full history of how each piece was found/fixed; this document is the
cross-cutting summary of the *safety model*, not a changelog.

cetrafs is built for the VMFS use case: several
independent nodes with their own kernel, their own page/buffer cache, and no
shared memory, mounting one shared LUN at once. There is no cluster-wide
lock manager, no quorum service, and no network heartbeat between nodes —
every coordination primitive here is either an on-disk record both nodes
can read, or an atomic compare-and-swap that the shared storage itself
arbitrates.

## Three independent problems, three mechanisms

| # | Problem | Mechanism | Lives in |
|---|---|---|---|
| 1 | Which node may allocate a *new* block, and from where | Zone Group ownership | `zonegroup.c` |
| 2 | Which node may write to a *specific file's* already-allocated data | Whole-file exclusive open lock | `lock.c` |
| 3 | Two nodes mutating the *same directory's* dirents, or destroying a file another node still has open | Per-inode namespace lock + lock-aware unlink/rename | `nslock.c`, `dir.c` |

All three are built from the same two primitives, described next.

## Shared primitive 1: the Node Registry and staleness

Every node that mounts the volume claims one row of a global on-disk
**Node Registry** (`cetrafs_node_entry_t`, `node.c`), keyed by a UUID stable
across reboots. A node periodically (`CETRAFS_HEARTBEAT_INTERVAL_SECS` =
15s, `heartbeat.c`) bumps its own row's `hb_seq`/`last_seen`. Any other node
can ask `cetrafs_node_is_stale()` whether a given row is *not* `REGISTERED`,
or hasn't been renewed in `CETRAFS_NODE_STALE_SECS` (4× the interval — a few
missed ticks, not one, so ordinary jitter or a slow disk is never mistaken
for a dead node). Staleness is what turns "node X crashed holding
something" from a permanent stuck state into something another node can
safely reclaim.

**This is a timeout heuristic, not consensus or fencing — see "Known
limitations" below.** It's the single biggest caveat on everything else in
this document.

## Shared primitive 2: atomic COMPARE AND WRITE

`caw.c` issues SCSI **COMPARE AND WRITE** (opcode `0x89`): one fused
command carrying a compare image and a write image, which the array
applies atomically or rejects with MISCOMPARE. That is the same family
of primitive as VMFS's ATS. `cetrafs_cas_region()` wraps it as a
compare-and-swap over one CAS region — `cetrafs_cas_region_size()`, the
device's logical block, 512 bytes on the deployment LUN. Every on-disk
record this filesystem claims is laid out to fit inside one such region,
which is why records are stored one per block.

The mutate callback is handed the current image and returns the image it
wants written; a MISCOMPARE means a peer changed it first, and the
caller re-reads and retries. **A MISCOMPARE is never retried against a
stale image** — that would turn a compare-and-swap into a blind
overwrite. A *seeded* CAS (`cetrafs_cas_record_seeded()`) passes an
image the caller already read, so the common claim costs one round trip
rather than two.

Not every device supports CAW (a loop device, this project's own test
harness, does not). There, `cetrafs_cas_region()` falls back to a plain
forced-fresh read / mutate / write under a **node-local** mutex — which
is correct only because `fs.c`'s mount-time gate refuses to mount such a
volume at all when any *live* peer already has it mounted, making a
no-CAW device **single-mounter by construction**. The node-local mutex
is still required: one node is not one thread, and two local threads
racing that fallback lost updates until it was added.

Two consequences worth stating plainly, because both were learned the
hard way:

- **"Does this device have a cluster mutex?" is not the same question as
  "can this volume have more than one node?"** Using the first as a
  proxy for the second is how a foreign-ZG free came to corrupt the
  owner's bitmap. Ask the mount gate's question.
- **A device whose CAW capability cannot be determined is refused**, not
  assumed to lack it. Assuming the weaker model would put this node on
  the serialised fallback while a peer whose probe succeeded uses real
  atomicity, with both writing the same records under incompatible
  exclusion.

Every real on-disk claim still follows a **write-then-verify-readback**
discipline on top of the CAS: claim, then read back and confirm it
stuck. With CAW that is belt-and-suspenders; on the fallback it is a
second check beneath the mutex. A readback mismatch is treated as a
**lost race**, never silently accepted.

## Mechanism 1: Zone Group ownership (new-block allocation)

The disk is split into Zone Groups, each owning a contiguous span of Block
Groups (the actual data regions). `cetrafs_zg_try_claim_one()`
(`zonegroup.c`) claims an unowned (or stale-owned) ZG for the local node
using the compare-and-swap + write-then-verify-readback pattern above. At any
moment, **at most one node owns a given ZG**.

`cetrafs_alloc_pick_bg()` — the only place a new data block is ever chosen
from — only ever scans BGs inside ZGs the *local* node owns. This is what
actually makes "a node only allocates from its own zones" true: two nodes
can never draw a newly-allocated block from the same free-space pool at the
same time, because they're drawing from disjoint partitions of the disk by
construction, not by racing for the same bit in the same bitmap.

A node claims only the minimum it needs: one ZG at mount if it owns none yet
(`cetrafs_zg_claim_unowned()`, also re-run on every heartbeat tick so a ZG
abandoned by a now-stale peer eventually gets picked up without a remount),
and exactly one *more* only once `cetrafs_alloc_pick_bg()` actually finds
every BG in every ZG it already owns full. **This is deliberately not
"claim every unowned ZG at mount".** Claiming everything available
would leave the first node to mount a fresh multi-ZG volume owning the
entire disk and permanently starve every later node. With N zone
groups, at most N nodes can hold write access at once, however many
mount — and that only holds because each node takes the minimum it
needs, never more. `/proc/fs/cetrafs/<dev>/info` shows who owns what.

**What this does *not* do:** gate who may *write to an already-allocated
block*. ZG ownership is purely an allocation-time partition. Reading or
overwriting an existing block's bytes is never checked against ZG
ownership anywhere in this codebase — that's mechanisms 2 and 3's job.

## Mechanism 2: the whole-file exclusive open lock

`cetrafs_inode_t` carries `lock_owner_node`/`lock_mode` (a Node Registry
row index + `CETRAFS_LOCK_NONE`/`_EXCLUSIVE`). Wired into
`cetrafs_file_ops`'s `.open`/`.release` (`lock.c`) for **regular files
only** — directories are never lockable this way, see Mechanism 3.

- An unlocked file's write-open (`FMODE_WRITE`) claims it for the opening
  node.
- Any open — read or write — from a *different* node while
  `CETRAFS_LOCK_EXCLUSIVE` is held rejects with `-ETXTBSY`, unless the
  holder's Node Registry row has gone stale, in which case the open
  proceeds (and a write-open reclaims the lock).
- This node's own *local* open-for-write refcount (`lock_writer_count`, a
  private per-inode `atomic_t`) is what the lock actually releases against
  — the on-disk claim drops only when the *last* local write-opener
  closes, not the first, so one node having the same file open twice
  (two processes, or one process twice) can't let a peer race in between
  those two closes.

This is **whole-file, VMFS-style exclusivity** — not POSIX byte-range
`fcntl` locking. It's sized for "exactly one cluster node has this VM disk
open for writing," not for many processes sharing fine-grained ranges of
one file across hosts.

**The claim itself is race-safe cross-node:** the
read-decide-write that claims or reclaims the lock is bracketed in the same
compare-and-swap + write-then-verify-readback pattern as every other claim in this
codebase. Without it, two nodes opening the same unlocked (or the same
stale-held) file for write close enough together could both read
`CETRAFS_LOCK_NONE`, both decide to claim it, and both write their own
ownership — and whichever write landed last would silently win while
both nodes' `open()` had already returned success. A lost race now
returns `-ETXTBSY`.

### Single-node data publication: `fd_pub_mutex`

The namespace lock (Mechanism 3, below) governs cross-node access to extent trees and metadata. Within one node, `cetrafs_inode_fd_pub_mutex` serialises every publisher of a file's record — the things that mutate its inode image and write it back to disk:

- `cetrafs_write_vfs_inode()` (the file's own write path)
- `cetrafs_punch_hole()` (hole-punch ioctl)
- `cetrafs_defrag_step()` (the background defragmenter moving extents)
- `cetrafs_refresh_vfs_inode_if_newer()` (a reader refreshing cached inode fields)

Holding this mutex across a publish does three jobs:

1. **Size/timestamp are sourced from the live inode.** A background mover (defrag or punch) that runs while a local writer has the file open will read a stale extent map and re-read the live file's size/atime/mtime under the mutex at publish time, not use what it read at operation start. This prevents the symptom where a defrag step's first read sees extent 0 and a 100-block size, a concurrent local write grows the file to 200 blocks with a new extent, and the defrag's final publish overwrites the size back to 100 with both extents — a size-extent mismatch that fsck calls consistent but the data is wrong.

2. **Read refreshes and publish CAS are atomic.** A read that happens while the file's own publish is in flight can observe the pre-publish image. Without the mutex, a reader could refresh while a publisher's CAS is running, pick up a stale value, mark it as fresh, and persist that staleness despite the publish succeeding. The mutex ensures the refresh either happens entirely before the publish (and is corrected by its merge write-back) or entirely after (and sees the published state).

3. **The refresh guard prevents self-reverting reads.** A read that completes after this node's own file-sector publish CAS started but before it finished sees the pre-publish record, and if that read's timestamp is stamped it reverts in-core state the publish just made newer. A guard in `cetrafs_refresh_vfs_inode_if_newer()` checks whether the record's last file-sector stamp is this node's own: if so, the read is declined (in-core is already at least this new), and a peer's stamp still applies (necessary for cross-node coherency).

## Mechanism 3: the per-inode namespace lock + lock-aware destructive ops

Two problems sit below the two mechanisms above.

**(a) Directory dirent races.** Every namespace-mutating operation
(`create`/`mkdir`/`unlink`/`rmdir`/`rename`/`link`/`symlink`, all in
`dir.c`) reads a directory's dirent block(s), decides what to change, and
writes the result back. Two nodes mutating the *same* directory
concurrently (e.g. creating two different files in it) had no mutex
standing between them at all — not even the narrow kind every claim
elsewhere in this codebase has. Fixed by splitting each of those entry
points into a `*_locked()` worker (unchanged internals) plus a thin
wrapper that brackets the whole call in a cross-node lock.

That wrapper is `nslock.c`, a **per-inode** lock living in the inode
record itself (`ns_lock_owner`/`ns_lock_acquired`), which fits inside
the record's 512-byte CAS sector. Acquire and release are one
compare-and-swap each, so unrelated directories never serialise against
each other.

**The scope is the set of records the operation mutates, not just the
parent directory** — `cetrafs_nslock_acquire_set()` takes up to four
inodes: parent only for create/mkdir/symlink (the child is freshly
allocated and its bitmap bit was CAS-claimed, so no peer can see it
yet), parent plus victim for unlink/rmdir/link, and both parents, the
moved inode and any replaced target for rename. Parent-only would have
*introduced* a race the device-wide mutex did not have: two nodes
unlinking two hardlinks of one file through different parents would both
read-modify-write that file's `nlink`. Deadlock freedom comes from
always acquiring in ascending inode-number order, with duplicates
deduped.

Because this is a *held* lock rather than a brief one, a holder that
dies leaves it set. A waiter that finds the holder's Node Registry row
stale replays that node's journal first — repairing whatever it was
mid-writing — and only then CASes the lock away, exactly as the Zone
Group steal and file-lock reclaim paths do. "Already ours" is accepted
too, so a node that crashed holding its own directory is not wedged out
of it forever.

**(b) Destroying a file another node has open.** `unlink` and
`rename`'s replace-target path used to free a target's blocks purely based
on `nlink` reaching 0, with **no regard for Mechanism 2's lock at all** —
Node A could hold a file open for write while Node B unlinked it out from
under A, freeing blocks A was still actively writing into, which could then
be reallocated to something else entirely. Fixed by a new
`cetrafs_lock_foreign_claim_exists()` (`lock.c`) that `unlink`/`rename`
call before touching anything, refusing with `-ETXTBSY` if a *live* other
node holds the target's exclusive lock. This check only fires when the
operation would actually free data (`nlink` about to hit 0, or any
directory replace, since directories can't be hardlinked) — removing one
of several surviving hardlinked names never touches the underlying data
and is never blocked. A lock held by a now-*stale* node doesn't block
either, mirroring `cetrafs_lock_open()`'s own reclaim posture.

Renaming/linking a file *without* replacing anything (the common case) was
never affected by (b) — moving or adding a name to a dirent doesn't free
any data, regardless of who has it open.

## Journal scoping: a related but distinct safety rule

The per-**node** journal (`journal.c`) deserves a mention here because it's
the same hazard shape as the mechanisms above, in a different place.
Replaying (and *consuming* — zeroing) a node's journal area means writing
the post-images it holds into BG-data regions. Doing that for an area a
different, still-live node is actively writing would be exactly the kind of
cross-node write collision this whole document is about — which is why
replay runs only at ownership boundaries: a node's own area at mount, and a
*stale* peer's area at the moment its ZG or lock is reclaimed (tied to the
claim protocol, `cetrafs_zg_try_claim_one()`), plus a heartbeat sweep for a
crashed node nothing else had reason to touch. The area itself is also
CAS-claimed (`replay_owner`) so only one node ever replays a given dead
peer's journal.

## Known limitations (deliberately not fixed, flagged instead)

**Staleness is a timeout, not consensus or fencing.** A node that's merely
slow — a GC/scheduling pause, a saturated disk, a network blip on an iSCSI
path — looks identical to a dead one to `cetrafs_node_is_stale()`. A peer
can reclaim its ZG or file lock while it's still alive and still believes
it owns them: a genuine split-brain window. The compare-and-swap protects the
*moment* of reclaiming (same brief mutex as any other claim), but does
nothing to stop the original owner's *ongoing* writes to blocks/files it
still thinks are its own — it was never a held range lock. Real safety
against this needs actual node fencing (STONITH, or a continuously-held PR
reservation rather than a brief one). Out of scope today, and not currently
a planned phase.

Two concrete shapes of that window, named so nobody rediscovers them
(audit):

- **Self-fencing does not stop background writeback.** The `-EIO` fence
  blocks the filesystem's entry points; dirty buffers already in the page
  cache are flushed by the block layer underneath it, so a wrongly-reclaimed
  node's cached writes — its data-bitmap bit flips above all — can land
  arbitrarily late, over bits the new owner has since set. (The free-COUNT
  version of this was fixed in format v0x0004 by never leaving the BG
  descriptor dirty in the cache — an epoch-guarded CAS instead; the bitmaps
  are multi-block and per-bit hot, so the same cure does not apply to them.)
- **A stolen namespace lock drops the operation's staged record update.**
  The release CAS detects the steal, warns loudly, and discards rather than
  clobbers the thief's repair — correct, but the syscall it bracketed has
  already returned success, so that operation's record-side effects (an
  nlink change, a dirent_seq bump) are lost on disk. Inherent to a lease
  that can be wrongly revoked; the thief's journal replay restores the
  blocks it covers, and fsck reconciles the rest.

**This is the same posture VMFS takes, and the division of responsibility
is deliberate.** VMFS's on-disk locking is also an advisory heartbeat lease
made atomic by ATS (Atomic Test and Set — literally SCSI COMPARE AND WRITE,
the primitive in `caw.c`); it does not hard-fence a wrongly-declared-dead
host at the storage layer either. What keeps a vSphere cluster safe is not
VMFS — it is the layer *above* it (vSphere HA): a second heartbeat channel
(datastore heartbeating) to tell a crash from a network partition, and the
*host isolation response*, where an isolated host voluntarily powers off its
own VMs before its locks are reclaimed. cetrafs already has the storage-layer
analogue of the self-fencing half: `cetrafs_node_self_fence_check()` makes a
node that finds its lease revoked refuse all further writes with `-EIO`.

**So higher-level fencing belongs to the cluster/application manager, not to
the filesystem.** cetrafs provides the primitives — the atomic lease, the
stale-reclaim, and self-fencing on lease revocation — exactly as VMFS does.
Deciding that a slow-but-alive node must be forcibly stopped (STONITH, power
fencing, fabric fencing, or an isolation response that halts the workload) is
a policy decision that needs to see the whole cluster and the application, and
is the job of whatever orchestrates the nodes (the VM manager / HA layer),
not of a kernel filesystem driver. The filesystem's contribution is to make
every reclaim *atomic* and to *self-fence* the moment it notices it was
reclaimed; it cannot, and should not, be the thing that reaches out and kills
a peer.

**The timeout is bounded so it cannot be set into that danger zone.** Because
the lease is advisory, the one knob that matters is how long "silent" means
"dead", and setting it too low turns ordinary jitter into a false reclaim.
The per-mount `controls` file therefore clamps `hb_interval_secs` to
`[CETRAFS_HB_INTERVAL_MIN_SECS, CETRAFS_HB_INTERVAL_MAX_SECS]` (5–30s),
`stale_secs` to `[CETRAFS_STALE_MIN_SECS, CETRAFS_STALE_MAX_SECS]` (15–240s),
and requires `stale_secs >= CETRAFS_STALE_MIN_BEATS x hb_interval_secs` (≥3
beats, so one missed tick is never fatal). The ceiling matters as much as the
floor: a window of many minutes would leave a genuinely crashed node's claims
locked up far longer than a VM datastore can tolerate. The `hb_interval_secs`/
`stale_secs` *module params* are deliberately unbounded — they are test knobs
the loop suites use to compress timing, not an operator interface. An observer
additionally floors its window at four of a peer's *own advertised* beat, so a
differently-tuned peer is never misjudged (see `cetrafs_node_is_stale()`).

**Cross-node buffer-cache staleness (`kmod/ioutil.c`).**
Every node's buffer cache for on-disk blocks is purely local, and the Linux
buffer cache assumes exclusive single-kernel ownership of the device: once a
node reads a block, `sb_bread()` keeps handing back that same cached copy
forever, with no way to notice a *different* node's kernel overwriting the
same LBA later. This wasn't just a stale-read annoyance — it silently
defeated the write-then-verify-readback check all three mechanisms above
depend on, since the "verify" read was just as happy to return this node's
own locally-cached copy of what it just wrote, regardless of what a peer
had actually since written. Confirmed on real two-node hardware: a node's
view of a peer's Node Registry heartbeat row never advanced, and two nodes
simultaneously won the same file's exclusive-lock claim (Mechanism 2) even
though the surrounding exclusion itself was genuinely active — the bug was in
the reads around the mutex, not the mutex. Fixed with two new primitives
(`cetrafs_bread_uncached()`, `cetrafs_invalidate_block()`): Node Registry
rows, ZG ownership reads, directory dirents, and xattr blocks now always
bypass the cache (small and rare enough that always-fresh is cheap); an
inode's record and a ZG's BG/bitmap blocks stay on the normal fast cached
path but get explicitly invalidated exactly when ownership changes hands —
a ZG's BGs when that ZG is freshly claimed/reclaimed, an inode's block right
before `lock.c` decides whether to grant a cross-node claim.

**Residual limitation.** The fix above covers every *ownership/claim*
decision, but a read-only open of a file is still explicitly allowed even
while another node holds the exclusive write lock (Mechanism 2), and that
reader's cache of the file's *content* (not its lock state) is never forced
fresh on every access — only the claim fields are. A node that read-opened a
file earlier and is still holding stale cached pages won't see a
concurrent write from the current lock holder without re-opening. This is
the same "no close-to-open consistency" tradeoff most network filesystems
make for concurrent readers, not a correctness hole in any of the three
mechanisms above.

**Within a node, nothing beyond ordinary VFS/page-cache behavior
serializes concurrent *local* writers to the same file.** The whole-file
lock's job is cross-node exclusivity; two local processes on the lock
holder's own node writing overlapping byte ranges of the same open file get
whatever semantics the Linux VFS/page cache naturally provides, same as any
other local filesystem — this was never meant to add POSIX byte-range
semantics on top.

**True cross-node races aren't exercisable on this project's own loop
harness.** The loop-device integration suite (`make check`) has no atomic
COMPARE AND WRITE to exercise (a loop device reports no CAW length), so
`cetrafs_cas_region()` takes its serialized no-CAW fallback there and the
fixes that depend on real cross-node atomicity are only partially covered.
Real multi-node coverage is `ctest/` against a shared LUN between two
genuinely separate kernels — it exercises the CAW path for real (its `caw`
scenario asserts the swap was genuinely contended, via the
`cas_miscompares` counter) and the namespace, lock, fence-reclaim, dirent
and journal paths under two-node contention. That suite passes end to end
on real two-node hardware.
