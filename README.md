# cetrafs

A clustered, **shared-disk** filesystem for Linux — a modern, open
alternative to VMFS. Several nodes mount one shared block device (an iSCSI
or Fibre Channel LUN) at the same time, each running a different subset of
the workload, with VM disk images (raw/vmdk) living directly on the one
volume — the way VMFS backs vSphere.

It is an out-of-tree kernel module (`kmod/`) plus the userspace tools
`mkfs.cetra`, `fsck.cetra` and `defrag.cetra` (`userspace/`). Nodes
coordinate through the storage itself — one atomic SCSI COMPARE AND WRITE
per contested claim, the same idea as VMFS's ATS — not over a network.

> **Status: young, pre-1.0.** Heavily reviewed, fuzzed and crash-tested,
> but not production-aged the way VMFS or ext4 are. Built and tested on
> Linux `7.0.14` and `7.1.8+deb13` (Debian, arm64), on
> little-endian hosts (arm64, amd64). Keep independent backups.

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
- **End-to-end integrity** — CRC32C on every on-disk structure,
  kernel-verified on read with transient-tear retry; per-inode generations
  detect cross-node inode-number reuse.
- **A real POSIX namespace** — directories, hardlinks, symlinks and
  `user.*`/`trusted.*`/`security.*` extended attributes, with LSM labelling
  so SELinux-enforcing hosts work. (No POSIX ACLs, no special files.)
- **Large, sparse files** — a depth-2 extent tree, up to 16 TiB per file;
  `SEEK_HOLE`/`SEEK_DATA` and `FIEMAP`, so thin images stay thin.
- **Live migration** — the `nofilelock` mount option lets an image be open
  on two nodes during a Proxmox/qemu online-migration handoff, coherently.
- **Online maintenance** — in-place defragmentation, a background scrubber
  that reclaims leaked blocks, and an `fsck.cetra` that repairs the
  mechanically-derivable faults and refuses the ambiguous ones.

## Requirements

- A Linux kernel with matching headers to build the module. Supported:
  `7.0.14` and `7.1.8+deb13` (Debian; the Proxmox VE `7.0.14-*-pve`
  build is the same family); older
  kernels are not supported, and the code is new enough that other kernels
  are untested.
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
  `hb_interval_secs`). See the operations guide at cetrafs.com.
- The on-disk format is little-endian but portable across host byte order; tested on little-endian hosts (arm64, amd64).

## Build and test

```
make            # kernel module + userspace tools
make mod        # kernel module only (kmod/cetrafs.ko)
make userspace  # mkfs.cetra, fsck.cetra, defrag.cetra
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

## Install with DKMS

For a persistent install that survives kernel upgrades, use DKMS — it
rebuilds `cetrafs.ko` automatically whenever a new kernel is installed, so
the "out-of-tree means rebuild per kernel" chore goes away. The DKMS source
tree needs `kmod/`, `include/` and `dkms.conf` (the module builds in `kmod/`
and includes the shared format header from `../include`):

```
sudo cp -r . /usr/src/cetrafs-0.6      # kmod/ + include/ + dkms.conf
sudo dkms add     -m cetrafs -v 0.6
sudo dkms build   -m cetrafs -v 0.6
sudo dkms install -m cetrafs -v 0.6
```

Make a distributable source tarball with `dkms mktarball -m cetrafs -v 0.6
--source-only` (install it elsewhere with `dkms ldtarball` + `dkms
install`). Keep the `0.6` in step with the release.

## Debian packages

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
(`mkfs.cetra`, `fsck.cetra`, `defrag.cetra` in `/usr/sbin`). Install the
pair and nothing else is needed: the module declares the `fs-cetrafs`
alias, so the first `mount -t cetrafs` loads it.

Two things the target does for you. It refuses to build when the version
in `debian/changelog` disagrees with `dkms.conf`'s `PACKAGE_VERSION` or
with `dh_dkms -V` in `debian/rules` — those name the
`/usr/src/cetrafs-<version>` directory the postinst registers, so a drift
between them yields a package whose module silently never builds. And it
checks the build dependencies up front rather than failing midway.

Two more packages are for Proxmox VE: **`pve-storage-cetrafs`** (the
storage plugin, see below) and the optional **`pve-storage-cetrafs-ui`**
(its web UI). `make deb PVE=0` leaves both out.

Note that `debian/rules` skips `make check` at package-build time (it
needs root, loads the module and takes minutes), so **a built package is
not a tested one** — run `make check` yourself.

## Quickstart

```
mkfs.cetra <dev>                       # create a volume
mount -t cetrafs <dev> <mnt>           # mount read-write
mount -t cetrafs -o ro <dev> <mnt>     # mount as a read-only observer
```

For VM images on a Proxmox cluster — shared storage, `cache=none`, and live
migration with `-o nofilelock` — follow the runbook in
the operations guide at cetrafs.com.

## Proxmox VE storage plugin

`pve/` holds a Proxmox VE storage plugin, storage type `cetrafs`: a
cetrafs volume on a shared LUN, mounted at the same path on every node and
used like a directory storage (VM images, container volumes, ISOs,
templates, backups, snippets). PVE treats it as shared storage, so live
migration and HA work without copying disks.

On every node, install `cetrafs-dkms`, `cetrafs-tools` and
`pve-storage-cetrafs`; for the web UI also `pve-storage-cetrafs-ui`, which
adds **cetrafs** to *Datacenter -> Storage -> Add*. Create the volume once,
on one node, then add the storage:

```
mkfs.cetra /dev/disk/by-id/<lun>
pvesm add cetrafs san1 --cetrafs-device /dev/disk/by-id/<lun> --content images
```

Each node mounts it on first use, at `/mnt/pve/<storage id>` unless
`--path` says otherwise. The device path must name the same LUN on every
node -- a `/dev/disk/by-id/` link or a multipath alias, never `/dev/sdX`.

The storage mounts with `nofilelock` by default (`--cetrafs-nofilelock 0`
turns it off), because a live migration has the image open on both nodes
during the handoff. Every node must use the same mode: the kernel refuses
a mount that disagrees with the nodes already mounted, so a change only
takes effect once the storage was unmounted everywhere.

Without packages, `make pve-install` and `make pve-install-ui` (as root)
install the same files from the checkout; the UI is then kept in place
across `pve-manager` upgrades by an apt hook instead of a dpkg trigger.

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

## Documentation

- `docs/ARCHITECTURE.md` — the on-disk format reference and a status map
- `docs/LOCKING.md` — the coordination mechanisms and their rules
- `docs/PERFORMANCE.md` — the per-block cost invariants and what guards each
- `docs/TESTING.md`, `docs/LOGGING.md` — test strategy and logging

Deployment requirements, the operator runbook and the feature matrix live
at **cetrafs.com**.

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
