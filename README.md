# cetrafs

A clustered, **shared-disk** filesystem for Linux — a modern, open
alternative to VMFS. Several nodes mount one shared block device (an iSCSI
or Fibre Channel LUN) at the same time, each running a different subset of
the workload, with VM disk images (raw/vmdk) living directly on the one
volume — the way VMFS backs vSphere.

It is an out-of-tree kernel module (`kmod/`) plus the userspace tools
`mkfs.cetra`, `fsck.cetra`, `growfs.cetra` and `defrag.cetra`
(`userspace/`). Nodes coordinate through the storage itself — one atomic SCSI COMPARE AND WRITE
per contested claim, the same idea as VMFS's ATS — not over a network.

> **Found it useful?** A **star** on
> [GitHub](https://github.com/cetrafs/cetrafs) helps the project reach
> the people it is built for — and tells me it is working as expected,
> which is hard to learn any other way.

**[cetrafs.com](https://cetrafs.com/)** &nbsp;·&nbsp;
[Documentation](https://cetrafs.com/docs/) &nbsp;·&nbsp;
[Quick install](https://cetrafs.com/docs/how-tos/install-packages/) &nbsp;·&nbsp;
[Project status](https://cetrafs.com/docs/intro/status/)

## What you get

- **Shared-disk clustering** — many nodes, one LUN. Each node owns its own
  Zone Groups for allocation, so two nodes never draw from the same
  free-space pool at once.
- **Atomic CAW coordination** — every contested claim (the namespace lock,
  the whole-file open lock, node registration, Zone Group ownership, a
  bitmap bit) is one compare-and-swap on a single 512-byte record. A
  device without atomic CAW is restricted to a single mounter.
- **Crash consistency** — a per-node write-ahead redo journal, replayed at
  mount and whenever a dead peer is reclaimed.
- **End-to-end integrity** — CRC32C on every on-disk structure, and on
  every 512-byte sector of the allocation bitmaps; kernel-verified on read
  with transient-tear retry; per-inode generations detect cross-node
  inode-number reuse. Damage found at runtime refuses writes to what it
  touches and leaves a lasting "needs fsck" mark in the superblock.
- **A real POSIX namespace** — directories, hardlinks, symlinks and
  `user.*`/`trusted.*`/`security.*` extended attributes, with LSM labelling
  so SELinux-enforcing hosts work. (No POSIX ACLs, no special files.)
- **Large, sparse files** — a depth-3 extent tree, up to 1 EiB (2^48 blocks) per file;
  `SEEK_HOLE`/`SEEK_DATA` and `FIEMAP`, so thin images stay thin.
- **Live migration** — the `nofilelock` mount option lets an image be open
  on two nodes during a Proxmox/qemu online-migration handoff, coherently.
- **Honest locks** — `flock(2)` is a real cross-node lock. `fcntl`/OFD
  byte-range locks are not cluster-wide: refused with `ENOLCK` on a default
  mount, granted node-local under `nofilelock` or `-o localposixlocks` (for
  a stock qemu's image locking; Proxmox's qemu needs neither).
- **Online maintenance** — grow a mounted volume in place (`growfs.cetra`;
  every node catches up live), in-place defragmentation, UNMAP to a thin
  LUN (`fstrim`, and an emptied Block Group handed back), a background
  scrubber that reclaims leaked blocks, and an `fsck.cetra` that repairs
  the mechanically-derivable faults and refuses the ambiguous ones.

## Status

**Ready for production use on its target workload** — VM disk images on a
shared, CAW-capable LUN. The on-disk format, the cluster protocol and the
recovery paths are complete, and the open-defect list is empty.

That claim rests on the test effort, which is larger than the
filesystem: 837 regression suites and ~6,600 assertions per gate, a
negative control in five suites of six proving each fails without the
fix it guards, 68 two-node scenarios on real Fibre Channel and iSCSI
storage,
crash replay at arbitrary cuts, hostile-image fuzzing of both `fsck` and
the mount path, a KASAN build, and 59 catalogued bug classes each audited
across the whole tree. **[How cetrafs is tested](docs/QUALITY.md)** is the
one-page summary.

Built and tested on Linux `7.0.14` and `7.1.8+deb13` (Debian, Proxmox VE),
on arm64 and amd64. As with any storage system, run it with backups to
other storage and with host fencing in a multi-node cluster.

Before a first deployment, read
[Project status](https://cetrafs.com/docs/intro/status/) and validate the
storage path with [the deployment test plan](docs/TESTING.md): it checks
the two properties of your SAN that cetrafs depends on (atomic CAW, and
coherent reads across hosts) before anything is put on it.

## Feedback

cetrafs is early, and the fastest way to improve it is to hear from
people running it on real hardware. A cluster that is not mine finds
things no amount of review does — that has been true of every serious
bug so far.

- **Something broken, or behaving strangely?** Please
  [open an issue](https://github.com/cetrafs/cetrafs/issues). Kernel,
  array, node count and what you expected are usually enough to make a
  report actionable.
- **Used it, or just have an opinion on the design?** Start a thread in
  [GitHub Discussions](https://github.com/cetrafs/cetrafs/discussions) —
  that is where feedback belongs, where others can see it and add to it.
  It is genuinely wanted, including the unflattering kind.
- **Found it useful?** A **star** on
  [GitHub](https://github.com/cetrafs/cetrafs) helps the project reach
  the people it is built for — and tells me it is working as expected,
  which is hard to learn any other way.

## Documentation

- **Project site** — <https://cetrafs.com/>
- **Documentation** — <https://cetrafs.com/docs/>: deployment
  requirements, the operator runbook and the feature matrix.

In this repo:

- `docs/QUALITY.md` — **how cetrafs is tested**, in one page
- `docs/COMPARISON.md` — cetrafs next to VMFS, OCFS2 and GFS2
- `docs/ARCHITECTURE.md` — the on-disk format reference and a status map
- `docs/LOCKING.md` — the coordination mechanisms and their rules
- `docs/PERFORMANCE.md` — the per-block cost invariants and what guards each
- `docs/TEST-SUITES.md` — what the automated test effort covers and the
  faults each tier exists to catch
- `docs/TESTING.md`, `docs/LOGGING.md` — deployment test plan and logging
- `docs/DISCARD-DESIGN.md` — returning freed space to a thin LUN
  (UNMAP/discard): the design, and the two hazards it is built around

## Requirements

- A Linux kernel with matching headers to build the module. Supported:
  `7.0.14` and `7.1.8+deb13` (Debian; the Proxmox VE `7.0.14-*-pve`
  build is the same family); older
  kernels are not supported, and the code is new enough that other kernels
  are untested.
- **A 4 KiB kernel page size**, which is every x86-64 kernel and nearly
  every arm64 one. The filesystem block is fixed at 4 KiB, so on a 4K
  page the block index and the page-cache index are the same number;
  arm64 built with 16K or 64K pages (`CONFIG_ARM64_16K_PAGES`) makes
  them differ by 4x or 16x. Such a kernel builds the module but is
  refused at mount: the larger-page cases are known to be unhandled in
  places and have never been run.
- **For clustering:** a shared block device whose LUN supports atomic
  COMPARE AND WRITE (SCSI ATS). Probe a candidate without mounting it:
  `modprobe cetrafs caw_probe=<dev>` and check `dmesg` for
  `max_caw_blocks >= 1`. Without CAW, a volume is single-node only (the
  mount gate enforces it).
- **For production multi-node:** an external cluster manager providing host
  fencing (STONITH). cetrafs's liveness is a heartbeat timeout and it
  self-fences a reclaimed node, but it does not kill a partitioned host —
  the same split of responsibility as VMFS (storage lease) and vSphere HA
  (host isolation).
- **With multipath:** check that path failure surfaces as an I/O error
  *before* peers declare the node dead. When every path drops,
  dm-multipath **queues** I/O for `no_path_retry x polling_interval`
  seconds rather than failing it — the stock HPE 3PAR entry is 90 s — and
  the node cannot heartbeat either, because its heartbeat is queued
  behind the same dead paths. If that exceeds the stale window, peers
  reclaim its Zone Groups while its writes are still pending, and those
  writes land afterwards. cetrafs defaults to a **120 s** stale window,
  which clears a stock 90 s path retry; raise it if yours is longer:

  ```sh
  echo "options cetrafs stale_secs=120" > /etc/modprobe.d/cetrafs.conf
  ```

  That sets the boot-time default on every mount. To change it on a live
  mount without a reload, write `stale_secs=<n>` to
  `/proc/fs/cetrafs/<dev>/controls` (bounded 15-240 s, and at least 3x
  `hb_interval_secs`).

  The same window bounds how long a node rides out its OWN stall: it
  stops itself (every I/O EIO until remount) once its last heartbeat
  renewal is the stale window less one heartbeat old -- 105 s with the
  defaults -- because peers may reclaim from it after the window. When
  every node of the cluster loses the LUN at once, each of them stops
  at that point. A stall you want the cluster to survive must therefore
  be shorter than `stale_secs - hb_interval_secs`.

  The bound is on the whole time a write can be held, not on the
  queueing alone: a path holds it first for the SCSI command timeout plus
  its transport's own wait -- an iSCSI session's `replacement_timeout`
  (120 s by default, the whole stale window), which starts only once the
  session has noticed the loss (`noop_out_interval + noop_out_timeout`),
  or an FC port's `fast_io_fail_tmo` (`dev_loss_tmo` when that is off) --
  and only then does multipath queue it. The rule is therefore

      SCSI timeout + transport wait + no_path_retry x polling_interval
          < stale_secs - hb_interval_secs

  where an iSCSI transport wait is `noop_out_interval + noop_out_timeout
  + replacement_timeout`.

  for multipath and single-path initiators alike (no multipath: the last
  term is zero). An iSCSI `replacement_timeout` of -1 (no limit) breaks it
  by definition. At the other end, `no_path_retry fail` (no queueing at
  all) turns every moment with no path -- a switch reboot, a
  controller failover -- into an I/O error on a metadata write, which
  stops the mount until it is remounted (`docs/internal/ERRORS.md`).
  Use a bounded count that fits the rule above instead. Nothing checks this at mount time: setting the timers is
  the operator's job, as is hardware fencing where a cluster has it.

  A `controls` change lasts until the volume is unmounted; the next mount
  takes the module option again. The module option is read when a volume
  is mounted, so changing it (in modprobe.d or
  `/sys/module/cetrafs/parameters/`) does not affect volumes already
  mounted. It accepts a wider range than `controls`, for the test suites:
  keep production values inside the same bounds. `hb_interval_secs` works
  the same way (5-30 s through `controls`). See the operations guide at
  <https://cetrafs.com/docs/>.
- The on-disk format is little-endian but portable across host byte order; tested on little-endian hosts (arm64, amd64).

## Build and test

```
make            # kernel module + userspace tools
make mod        # kernel module only (kmod/cetrafs.ko)
make userspace  # mkfs.cetra, fsck.cetra, defrag.cetra, growfs.cetra
make check      # the test suite: loop-backed images, never a real device (needs root)
make soak       # mixed-workload soak with a full fsck after each round
```

Load the module with `insmod kmod/cetrafs.ko` (it uses the kernel's
`crc32c`, built into most kernels). Once it is *installed* rather than
loaded by hand -- via DKMS, or `install` + `depmod` -- no explicit load is
needed at all: the module declares the `fs-cetrafs` alias, so the first
`mount -t cetrafs` pulls it in like any in-tree filesystem. `tests/device/`, `tests/crash/` and
`ctest/` are the opt-in, destructive or real-hardware suites — they name
the device explicitly and never default to one. `ctest/` is the two-node
suite and the only thing that exercises cross-node paths for real.

## Installation
### Install with DKMS

For a persistent install that survives kernel upgrades, use DKMS — it
rebuilds `cetrafs.ko` automatically whenever a new kernel is installed, so
the "out-of-tree means rebuild per kernel" chore goes away. The DKMS source
tree needs `kmod/`, `include/` and `dkms.conf` (the module builds in `kmod/`
and includes the shared format header from `../include`):

```
sudo cp -r . /usr/src/cetrafs-0.9.5      # kmod/ + include/ + dkms.conf
sudo dkms add     -m cetrafs -v 0.9.5
sudo dkms build   -m cetrafs -v 0.9.5
sudo dkms install -m cetrafs -v 0.9.5
```

#### Kernel upgrades

DKMS builds cetrafs only for kernels 7.0 to 7.2: the oldest it builds
against and the newest its sources were adapted to (`BUILD_EXCLUSIVE_KERNEL_MIN`
/ `_MAX` in `dkms.conf`). It skips any other kernel rather than building
against an API nobody checked, and a node that boots that kernel has no
cetrafs. So keep the running kernel pinned (on Proxmox,
`proxmox-boot-tool kernel pin <version>`) and move the pin only after
`dkms status` lists cetrafs as installed for the new kernel.

Make a distributable source tarball with `dkms mktarball -m cetrafs -v 0.9.5
--source-only` (install it elsewhere with `dkms ldtarball` + `dkms
install`). Keep the version in step with `debian/changelog`.

### Debian packages

The repo carries its own `debian/`, so the packaged path is one target:

```
sudo apt install debhelper dh-dkms    # build dependencies, once
make deb                              # packages land in dist/
make deb-clean                        # removes dist/ and the staging dirs
```

`dpkg-buildpackage` has no output-directory option and always writes
beside the source tree, so `make deb` moves what it produced into
`dist/` (gitignored) rather than leaving it next to your checkout.

It produces **`cetrafs-dkms`** (the module source plus DKMS wiring, so
`cetrafs.ko` is rebuilt on every kernel upgrade) and **`cetrafs-tools`**
(`mkfs.cetra`, `fsck.cetra`, `growfs.cetra`, `defrag.cetra` in
`/usr/sbin`). Install the
pair and nothing else is needed: the module declares the `fs-cetrafs`
alias, so the first `mount -t cetrafs` loads it.

Two things the target does for you. It refuses to build when the version
in `debian/changelog` disagrees with `dkms.conf`'s `PACKAGE_VERSION` or
with `dh_dkms -V` in `debian/rules` — those name the
`/usr/src/cetrafs-<version>` directory the postinst registers, so a drift
between them yields a package whose module silently never builds. And it
checks the build dependencies up front rather than failing midway.

Note that `debian/rules` skips `make check` at package-build time (it
needs root, loads the module and takes minutes), so **a built package is
not a tested one** — run `make check` yourself.

### Debian Repository

The Debian repository way allows users to quickly install and update `cetrafs` in a native way for Debian, Ubuntu and Proxmox based systems.

```bash
curl https://git.gyptazy.com/api/packages/gyptazy/debian/repository.key -o /etc/apt/keyrings/gyptazy.asc
echo "deb [signed-by=/etc/apt/keyrings/gyptazy.asc] https://packages.gyptazy.com/api/packages/gyptazy/debian trixie main" | sudo tee -a /etc/apt/sources.list.d/gyptazy.list
apt-get update

apt-get -y install cetrafs-dkms cetrafs-tools
# Optionally for the Proxmox integration in addition
apt-get -y install  pve-storage-cetrafs pve-storage-cetrafs-ui
```

> [!NOTE]
> The repository is maintained & operated by <a href="https://gyptazy.com">gyptazy</a> as a third-party repository.


## Quickstart

```
mkfs.cetra <dev>                       # create a volume
mount -t cetrafs <dev> <mnt>           # mount read-write
mount -t cetrafs -o ro <dev> <mnt>     # mount as a read-only observer
```

For VM images on a Proxmox cluster — shared storage, `cache=none`, and live
migration with `-o nofilelock` — follow the runbook in
the operations guide at <https://cetrafs.com/docs/>.

## On-disk layout

```
+---------------------------+
| Superblock                |  block 0; every other region's offset lives here
+---------------------------+
| Zone Group table          |  one block per ZG; a ZG is owned by one node,
|                           |  which allocates only from its own ZGs
+---------------------------+
| Block Group table         |  one block per BG
+---------------------------+
| Global inode bitmap       |
+---------------------------+
| Global inode table        |  one inode record per block
+---------------------------+
| Node registry             |  one row per node, keyed by stable UUID
+---------------------------+
| Per-node journals         |  physical/redo, single-writer by design
+---------------------------+
| Per-ZG pending-free queues|  cross-node frees handed to the owning node
+---------------------------+
| Block Group data regions  |  header + bitmap + data, per BG
+---------------------------+
```

Nothing is positionally hardcoded — every offset is stored in the
superblock. `include/cetrafs.h` is the single source of truth for the
format, shared verbatim by the module and the tools.

## Cross-node coordination

Atomic SCSI COMPARE AND WRITE, and nothing else. Every claim — the
per-inode namespace lock, the whole-file open lock, a registry row, Zone
Group ownership, an inode bitmap bit, the pending-free queue — is one
compare-and-swap on one 512-byte record. A device with no CAW can only be
mounted by a single node, which the mount gate enforces. Node liveness is a
heartbeat with a staleness timeout; a reclaimed node self-fences (every
write fails `-EIO`) until it remounts.

## License

The kernel module (`kmod/`) is **GPL-2.0-or-later**: it links against the
Linux kernel, so it is not dual-licensed and no proprietary option for it
exists.

The userspace tools (`userspace/`) are **AGPL-3.0-or-later, or a
commercial license** from the copyright holder for those whom the AGPL's
source-availability obligation does not suit.

`include/cetrafs.h`, the on-disk-format header, is compiled verbatim into
both halves and is offered under any of the three, so each side can take
it under terms it can use. The format itself is documented in
`docs/ARCHITECTURE.md` and is implementable by anyone.

Every file carries an `SPDX-License-Identifier:` line, which is
authoritative for that file. See `LICENSE` and `LICENSES/`.
