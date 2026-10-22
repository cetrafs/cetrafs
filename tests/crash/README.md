# tests/crash — crash-consistency rig

Cut power at a durability boundary; prove cetrafs still mounts, fscks
clean, and kept everything it acknowledged. This is the one correctness
property nothing else in the tree exercises: `make check` only ever does
clean mounts, the fuzzer mutates static images, and ctest has no power
loss. The journal, publish-before-free, block-valid-before-reachable and
fsync durability are all reasoned and reviewed but, until this, never
faced a real crash — only `journal_poke` simulating one hand-built state.

It is **opt-in** (not in `make check`): loop-backed, slower, and it needs
`dm-log-writes` and `dm-flakey`. Run it as root:

```
bash tests/crash/crash_consistency.sh
```

## Two ways this rig lied, both fixed

Worth reading before trusting a green run here, because for months it
was green while the filesystem could lose an allocation:

1. **Every checkpoint ran `sync` before its mark.** So the only instants
   this rig ever cut power at were ones where the whole filesystem had
   just been written back -- the single moment a real power loss is
   least likely to pick. Anything that was merely *dirty* at the cut was
   untestable by construction.

2. **`dmsetup suspend` flushes.** Without `--noflush --nolockfs` it
   `sync_blockdev()`s the mapped device on the way down, so the "power
   cut" politely asked the filesystem to flush first. Phase 3 did this,
   which is why its drop_writes crash only ever proved that writes AFTER
   the cut vanish -- never that state dirty AT the cut recovers.

Phase 6 exists because of this. It closes a file (a durability boundary:
the record is stamped and reaches the device) and cuts without flushing,
leaving the data-bitmap bits behind its extents still dirty. Recovering
from that used to give blocks referenced by an inode but reading FREE --
the allocator hands them out again and two files share them. It
reproduces in one shot, and it stayed invisible to this rig until both
of the above were fixed. The same bug was first caught by ctest's
replay-race on real three-node hardware.

The general rule: a crash test that flushes before crashing is testing
a clean unmount with extra steps.

## How it works

The xfstests `dm-log-writes` method. Stack:

```
loop(data) -> dm-log-writes (records every bio, in order, with FLUSH/FUA) -> cetrafs
```

mkfs and a workload run THROUGH that stack, so every write cetrafs issues
— with its barriers — lands in a separate **log device**. Then
`replay-log` replays the log onto a scratch device up to a chosen point;
the scratch is then byte-for-byte what the platter would hold had power
been cut right there. Mount cetrafs on it (it replays its own journal),
fsck, and verify.

- `replay-log.c` — a minimal replayer. The dm-log-writes on-disk format
  is not shipped in the kernel headers here, so it was reconstructed and
  verified empirically; the format is documented in the file's header.
  It can count FLUSH/FUA barriers, list marks, replay up to the Nth
  barrier (`--limit-fua`) or up to a named mark (`--end-mark`), and model a
  volatile-cache power cut that reorders the in-flight window
  (`--reorder-after-fua`, Phase 5).
- `crash_consistency.sh` — the five-phase suite.

### Phase 1 — recoverability

Replay to **every FLUSH/FUA barrier** after mkfs, mount (which triggers
journal replay), unmount, fsck. Must be ERR-free at every point. Many
barriers land mid-operation, so this is the real test of journal replay —
far more than `journal_poke`'s single scenario.

### Phase 2 — durability

Replay to each **named checkpoint** (a completed `fsync`, delimited by a
dm-log-writes `mark`) and verify every byte acknowledged up to it is
present and correct. This only works because each checkpoint's `fsync`
issues a block FLUSH, which orders the mark after the data in the log —
see the finding below.

### Phase 3 — dm-flakey power loss

The cheap complement: let the workload reach disk, then flip the device
to `drop_writes` (every further write silently vanishes — power loss),
unmount, remount, fsck. The pre-crash `fsync`'d data must be intact and
fsck clean; the writes dropped after the cut may vanish but must not
corrupt.

### Phase 4 — the journal emits its ordering flushes

Phases 1-3 replay writes IN LOG ORDER, so they prove ordered-power-cut
recovery but cannot catch a volatile cache REORDERING the journal entry
after the in-place write. The defence is the two `blkdev_issue_flush()`
barriers in `cetrafs_journal_write_block()`. dm-log-writes records those,
so a single journaled create must advance the barrier count by >= 2 — and
does not without the flushes (measured: delta 2 with, 0 without). The
discriminating proof the fix is emitted; Phase 5 proves the recovery it buys.

### Phase 5 — reorder-replay: a torn journaled block recovers

What Phases 1-3 cannot reach, now exercised. `replay-log --reorder-after-fua N`
models a volatile cache at a power cut: everything through barrier N is durable,
then in the next window the **journal-area writes are dropped** (the commit lost
in the cache) and the last **journaled target block** — a dirent / extent-leaf /
xattr block, found by its tail magic — is **torn** to half its sectors. A torn
target with no journal is unrecoverable, *unless* the journal commit sits in an
earlier, already-durable window — which is exactly what the flush between commit
and target guarantees. So mount's replay restores the torn block with the flush,
and cannot without it.

Three things were load-bearing to make this discriminate cleanly, each learned
by it failing first:

- **Drop only the journal area, not the whole metadata region.** Dropping all
  metadata also dropped inode records and desynced the allocator (a block
  referenced by a kept record with its bitmap bit torn) — corruption on *both*
  builds, discriminating nothing. The allocator must stay consistent; only the
  journal goes missing.
- **Tear only a tail-magic block.** The data region also holds BG bitmaps and
  headers; tearing one of those is allocator corruption unrelated to the journal.
  Only DBLK/LBLK/XBLK/IBLK blocks are torn.
- **Use a no-GROWTH workload** (allocate one xattr block, then rewrite it 30×
  with an fsync each). A growth workload leaves pre-existing referenced-but-free
  and orphan-inode states at mid-operation crash points — cetrafs's journal is
  per-block redo, not per-transaction, so an *unacknowledged* create interrupted
  by a crash can leak an orphan that fsck repairs but mount does not — and those
  swamp the torn-target signal. Rewriting one already-allocated block journals
  with no allocation, so ordered replay stays clean and the tear is the only
  variable.

Verified to discriminate: on the fixed build every torn block recovers (30/30
over 91 windows, no corruption); reverting the two journal flushes turns every
torn window into `xattr block failed its tail checksum` (30/30).

## Finding from building the rig

**File `fsync()` did not flush the block device's volatile write cache.**
`cetrafs_fsync()` wrote the data, extent-tree blocks and inode record and
waited for them to COMPLETE, but never issued `blkdev_issue_flush` — so on
hardware with a volatile cache, `fsync` returned success while the data
could still be lost on power failure (a POSIX durability violation).
`cetrafs_dir_fsync()` already flushed; the file path did not, which is
also what left Phase 2's marks unordered (the data was logged after the
mark). Fixed in `kmod/file.c` to flush like the dir path. On a
battery-backed LUN (the primary target) the flush is a block-layer no-op;
on anything with a volatile cache it is the difference between durable and
not. **The deployment LUN measured as write-back**
(`/sys/block/sda/queue/write_cache` = `write back`) -- a volatile cache,
so this is load-bearing on the real hardware, not theoretical.

**The journal needed the same flushes.** Its payload-vs-header ordering was
already safe (a torn/lost payload is caught by its checksum at replay), but
the journal commit must be durable before the in-place target write, and
the target before the entry is consumed -- both relied on `wait_on_buffer`
completion, which is not durability on a volatile cache. Two
`blkdev_issue_flush()` added; Phase 4 proves they are emitted. Side effect:
the extra barriers took Phase 1 from 7 crash points to 283.

## Limits / next

Barriers are the fsync/flush points, so Phase 1's granularity is however
often the workload flushes (a richer workload = more crash points).
Replaying to every Nth *entry* (not just barriers) would be finer but is
not what durability hinges on. The journal's ordering flushes are in place (see the finding above), proven
EMITTED by Phase 4 and proven to WORK by Phase 5's reorder-replay. Two honest
gaps remain, the first now partly closed. (1) Phase 5 itself still tears exactly
one block per window, to half its sectors, and drops the whole journal area --
but **phase 5b** sweeps the tear shape on a window known to tear:
every sector boundary 1..7 of 8, plus three blocks torn at once. The edges are
the point. K=7 lands every sector but the last, so all-new data sits under an
OLD tail; K=1 lands one new sector in an otherwise old block. Both must read as
torn, because replay decides whether to redo a target on exactly that
tail checksum -- a tear that happened to leave a self-consistent block would be
refused as "a peer rewrote this" and never repaired. All 8 shapes recover, and
the sweep is verified to discriminate: stubbing the tail check to always say
"intact" fails phase 5 (60 blocks) and phase 5b (8 of 8) together. What is still
unmodelled is arbitrary SUBSETS of a window -- the tears are always a prefix of
each block's sectors, and always the window's last N blocks. (2) The growth-workload crash
states Phase 5 deliberately avoids — an unacknowledged create interrupted
mid-flight leaking an orphan inode, or a referenced-but-free block — are a real
property of cetrafs's per-block (not per-transaction) journal worth its own
investigation: they are fsck-repairable and never lose acknowledged data, but
they are not fsck-clean, so an fs aiming for clean-at-every-crash-point would
treat them as findings.
