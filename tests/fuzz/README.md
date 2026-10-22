# tests/fuzz — hostile-image fuzzing

Mounting a filesystem image is parsing attacker-controlled input, in the
kernel. This directory fuzzes that boundary from both sides. It is
OPT-IN and deliberately not part of `make check`: the mount half can
Oops or wedge the host (that is its purpose), and the campaigns are
open-ended rather than pass/fail regression assertions.

## Pieces

- `mkgolden.sh <img>` — builds the golden image: mkfs'd AND populated
  through a real mount (directories, a depth-1 extent-leaf file,
  symlink, hardlink, xattrs, a punched hole), then verified fsck-clean.
  A mkfs-only golden would leave most of both parsers untouched. Its
  fsck-clean gate is itself a check — it is what caught fsck not
  walking `xattr_block` (a live xattr block reported as a leak, and
  `-r` ready to free it).
- `fuzz.py` — the engine. Reproducible from a seed; mutations are
  bit flips, random bytes, zero/0xFF runs, and aligned u64s biased
  toward huge values, placed 25% in the superblock / 45% in the first
  8 MiB (global metadata) / 30% anywhere. **A mutation inside block 0
  is followed by `sb_restamp`**, so the superblock's checksum is VALID
  and the mutation reaches the geometry/validation code instead of
  dying at the CRC — which is what a hostile image author trivially
  does. Every finding saves the exact image plus seed/mutation/log
  under the findings dir. Mutations are applied to the backing file and
  reverted after each iteration; the loop device is flushed before
  every run so the target never reads its own stale cache.
- `fuzz_fsck.sh [iters] [seed]` — userspace, SAFE, run it in the
  thousands. Builds fsck with ASAN+UBSAN (`detect_leaks=0`: a CLI
  exiting without freeing is convention, not a finding) and an rss cap
  with `allocator_may_return_null=1`, so a garbage count that sizes an
  allocation tests the OOM handling instead of aborting. A finding is a
  signal death, a sanitizer report, an unknown exit code, or a hang.
- `fuzz_mount.sh [iters] [seed]` — the KERNEL side. Root only, run it
  on a disposable machine. Mount, exercise (readdir, read, create,
  statfs, listxattr — each bounded by a timeout), unmount; a finding is
  a dmesg splat or any hang, and the run stops at the first one since
  the kernel's state is then suspect. The summary prints how many
  iterations actually MOUNTED: a refused mount proves only refusal, so
  "0 findings" with 0 mounts would be a run that tested nothing — the
  counter is what makes the green honest.

### Stage 2 (field-aware)

Stage 1 mutates blindly and only `sb_restamp` makes a checksum valid, so a
mutation of any structure deeper than the superblock dies at ITS checksum
before its parser runs. Stage 2 targets one checksummed structure at a time
and restamps it, so a hostile-but-checksum-valid record reaches the parser
behind it.

- `fuzz_restamp.c` -- the field-aware restamper (the counterpart of
  `sb_restamp` for every other structure). `fuzz_restamp <img> info` prints
  the geometry the engine needs; `fuzz_restamp <img> stamp <type> <off>`
  recomputes the checksum(s) for a `sb|zg|bg|bgh|inode|node|tail` structure
  at a byte offset. Reuses `include/cetrafs.h` + `userspace/crc32c.h`.
- `fuzz.py` modes `fsck-fields` / `mount-fields` -- enumerate every
  checksummed structure in the golden (layout from the superblock; tail
  blocks found by scanning their magic over the file's DATA extents only,
  via SEEK_DATA, so a sparse half-GiB image costs ~tens of MiB not 554),
  then per iteration mutate one structure's field, restamp it, run fsck /
  mount. Honesty counters: `exercised` (restamp worked, so the mutant
  reached the parser) must be > 0, and for fsck `noticed` (a mutation
  changed what fsck reports) must be > 0 or coverage is suspect.
- `fuzz_fsck_fields.sh` / `fuzz_mount_fields.sh` -- the stage-2 runners.

`mount-fields` goes beyond mounting the mutant: it re-copies a pristine
golden each iteration (mount and the exercise both WRITE, so the base
would otherwise drift) and drives the kernel's write paths against the
mutant -- pwrite/grow (allocate + extent insert/merge/spill), truncate,
interior punch, mkdir/create, rename, setxattr, unlink. It also plants a
replayable journal entry each iteration (`fuzz_restamp plant-journal`:
node 0 flag DIRTY + a valid no-op slot, so every mount replays) and makes
the slot a target, so a mutated `target_lba`/payload reaches `journal.c`'s
redo at mount.

**Structure-aware (the next stage):** `fuzz_restamp craft-tree <inode_off>
<variant>` writes an inode a VALID extent header but adversarial,
internally-consistent CONTENTS -- overlaps, 2^31 lengths, metadata/
out-of-range targets, zero lengths, duplicate logical blocks, and
(depth 1) a crafted leaf block with a valid tail. Both modes craft a tree
for ~half of inode targets and otherwise apply 1..4 coordinated byte
mutations (multi-field), so coupled hostile trees -- which a single flip
cannot build -- reach `get_block`/`tree_append`/truncate/punch/fiemap and
fsck's extent walk. Both modes re-copy a pristine golden each iteration
(the crafter and the write exercise both write the image).

Two engine robustness fixes stage-2 forced: `run()` caps each child's
output via `RLIMIT_FSIZE` (a fuzzed structure made fsck emit ~1.4 GiB,
OOMing the fuzzer -- now a bounded SIGXFSZ finding); and every runner
rebuilds the golden when `include/cetrafs.h` or `mkfs.c` is newer than it
(a cached golden from a prior layout silently fuzzes stale offsets --
measured: a v2->v3 field shift left `node_table_start` reading garbage).

## Findings to date (first campaigns)

- fsck never counted `xattr_block` as referenced (phantom leak on every
  volume with xattrs; `-r` would free a live xattr block). Found by the
  golden builder's own fsck gate. Fixed; controls in
  `blk_tail_checksum.sh` / `xattr_semantics.sh`.
- UBSAN signed-overflow in `devutil.h`'s pre-validation live-peer
  reader: `node_table_start * 4096` as signed with a hostile
  checksum-valid superblock, reachable from both fsck's and mkfs's
  "is somebody mounted?" gates, which by design trust nothing but the
  magic. Fixed (unsigned math, bounded; `node_table_count` bounded
  before it sizes an allocation).
- Baseline (stage 1) after fixes: fsck 10000 iterations over two seeds,
  mount 2300 iterations (~2270 mounted) -- no findings.

Stage 2 found three classes behind the checksums:

- An interior `fallocate(PUNCH_HOLE)` leaked its punched blocks (bitmap
  set, no extent) -- the free pass refused its own split for lack of array
  slack. A KERNEL bug, surfaced by the golden builder's fsck-clean gate.
  Fixed in `kmod/file.c`; control in `tests/kernel/punch_hole.sh`.
- Signed-overflow (UB) at every `(off_t) block * CETRAFS_BLOCK_SIZE` where
  `block` came from an inode (extent leaf/index LBA, xattr block): a huge
  value overflows `long` (and would seek wild in a release build). Fixed in
  `fsck.c` with `fsck_lba_in_range()` before each such pread.
- Runaway output / near-hang: `fsck_mark_run()` iterated per block over an
  extent `ee_len` (up to 2^31), one line per block -- GiB of output on a
  single crafted extent. Fixed by validating each run as a range once.
  (A fourth "finding" -- fsck hanging on a node row mutated to look live --
  was a false positive, fsck's deliberate 20s live-peer watch; the runner
  now sets `CETRAFS_PEER_PROBE_SECS=1`.)
- A KERNEL crash-and-wedge, found by the write exercise on its first
  3000-iter run: a checksum-valid inode with a corrupt extent header
  (`eh_entries` past capacity) made `cetrafs_leaf_array_insert()` read
  `arr[n-1]` with `n=eh_entries` before its `n>=max` guard -- OOB on the
  4-entry inline array -> Oops in `write_begin -> get_block -> tree_append`,
  and the Oops leaked `write_begin`'s folio lock so the next umount's
  evict hung in an unkillable D-state (reboot to clear). The read path
  validated the header; the write path did not. Fixed (`6c92798`): bound
  `n>max` in `leaf_array_insert` (an error return lets `block_write_begin`
  unlock the folio -- fixes crash AND hang) + reject `eh_entries>4` in
  `get_block`.
- A node-row multi-field mutation found an unbounded wait: the mount gate
  and staleness floor multiplied a peer's on-disk `hb_interval_secs` by 4
  unclamped, so a crafted huge value made mount `ssleep` for ~weeks (and
  the u32 `*4` could overflow). The operator path bounds it [5,30]; the
  on-disk read did not. Fixed (`ea8c772`) by clamping the peer value to
  `CETRAFS_HB_INTERVAL_MAX_SECS` before the `*4` in both places.
- Baseline (stage 2) after fixes: fsck-fields 6000 iterations over two
  seeds and mount-fields (read + write + journal replay) over several
  seeds -- 0 findings, incl. the former crash seed 40404 now 3000 clean
  and journal-replay 2000 clean.

## Known limits / next stage

The crafter builds depth-0, depth-1 AND depth-2 trees (variants 0-5
depth-0, 6-7 depth-1, 8-11 a crafted interior IBLK whose index entries
point at real hostile leaves, at the superblock, or past the device --
the only variants that reach the interior level `tree_flatten` walks), and
the mount-fields write exercise now writes to EVERY named regular file so
whichever inode was crafted gets its get_block/truncate/punch path driven,
not just read. Baseline on that: fsck-fields 3000 iters and mount-fields
400 iters, 0 findings. Coverage guidance (AFL/libFuzzer for fsck, KCOV for
the kernel) would be a bigger multiplier but needs tooling not present here
(no afl, no clang, no CONFIG_KCOV/KASAN). Neither mode is in `make check`
(open-ended, and the mount side can wedge the host); the bugs found are
guarded deterministically by the controls named above, not by the fuzzer.
