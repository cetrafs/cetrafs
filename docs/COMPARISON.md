# cetrafs compared

What separates the shared-disk filesystems is how nodes agree on who owns
what. That choice decides what else a cluster has to run, and what breaks
when the network does. This page compares cetrafs on those axes with the
filesystems it is usually weighed against. Facts about the others are
limited to their documented architecture; for their own limits and
tuning, read their documentation.

---

## Coordination

| | cetrafs | VMFS | OCFS2 | GFS2 |
|---|---|---|---|---|
| How nodes agree | atomic SCSI COMPARE AND WRITE on a 512-byte on-disk record, per claim | on-disk locks with ATS (the same SCSI primitive), SCSI reservations on arrays without it | a distributed lock manager over the network (o2dlm, or the kernel DLM with a cluster stack), plus a disk heartbeat | the kernel DLM over the network, driven by corosync/pacemaker |
| Network between nodes required for the filesystem | **no** -- the LUN is the only shared medium | no | yes | yes |
| Cluster stack required to mount | **no** (a fencing manager is still recommended for multi-node production) | ESXi/vCenter | o2cb or pacemaker | corosync + pacemaker + fencing |
| What a network partition does to the filesystem | nothing -- no lock traffic crosses it; a node that loses the **LUN** stops itself before peers reclaim its resources | nothing -- no lock traffic crosses it | lock traffic stops; nodes are fenced | lock traffic stops; nodes are fenced |
| Liveness | heartbeat in the on-disk node registry, with a fencing lease the victim checks before every renewal | on-disk heartbeat | disk and network heartbeat | cluster membership |

The point of the left column: everything cetrafs needs to stay correct is
on the device it is already writing to. There is no lock traffic to lose,
no quorum to compute, and no second network whose failure looks like a
dead node.

---

## Scope and platform

| | cetrafs | VMFS | OCFS2 | GFS2 |
|---|---|---|---|---|
| Built for | VM disk images on a shared LUN, VMFS-style | VM disk images under ESXi | general-purpose cluster filesystem | general-purpose cluster filesystem |
| Platform | Linux 7.0 / 7.1 (out-of-tree module, DKMS); Proxmox VE in practice | ESXi only | Linux, in-tree | Linux, in-tree |
| Source | GPL-2.0 module; AGPL-3.0 or commercial tools | proprietary | GPL | GPL |
| Per-file exclusive open across the cluster | **yes, by default** -- a file open for write on one node cannot be opened elsewhere; `nofilelock` lifts it for live migration | yes | no (POSIX semantics) | no (POSIX semantics) |
| Allocation without cross-node locking | **yes** -- each node allocates only from Zone Groups it owns | on-disk resource clusters, locked on the disk | per-node slots with a local allocator | shared resource groups, each DLM-locked |
| A file open on two nodes for migration | `nofilelock`, coherent through change stamps | yes | yes | yes |

cetrafs deliberately does not offer arbitrary concurrent POSIX writers on
one file. Its rule is one writer and nobody else, or many readers and no
writer -- the access pattern a hypervisor cluster actually has -- and that
narrower contract is what lets the steady-state I/O path run with no
cross-node traffic at all.

---

## cetrafs's own limits

| | |
|---|---|
| Nodes per volume | 64 |
| File size | 1 EiB (48-bit logical blocks) |
| Extents per file | 65.5 million (depth-3 tree) |
| Directory size | ~3.9 million entries |
| Volume | one block device, grown online in place |
| Block size | 4 KiB |
| Integrity | CRC32C on every structure, per 512-byte sector in the allocation bitmaps; per-inode generations against number reuse |
| Crash recovery | per-node redo journal, replayed at mount and by a peer when a node dies |
| Online maintenance | live grow, defragmentation, background leak scrub, UNMAP/`fstrim` to a thin LUN |

What it does not do, by design or not yet: POSIX ACLs, special files,
snapshots, volumes spanning several LUNs, `XCOPY`/`WRITE SAME` offload,
POSIX byte-range locks across nodes. The full list, with reasons, is
`docs/internal/LIMITATIONS.md`.

---

## Requirements, honestly

- **COMPARE AND WRITE on the LUN** for more than one node. Most enterprise
  arrays and LIO provide it; `modprobe cetrafs caw_probe=<dev>` tells you
  without mounting anything. A device without it mounts on one node only,
  and the mount enforces that.
- **Fencing** for production multi-node use. cetrafs fences itself when a
  peer reclaims it, but it cannot power off a host that is partitioned and
  still has queued I/O on the array -- that is the cluster manager's job,
  as it is vSphere HA's next to VMFS.
- **Path-failure timers below the stale window.** `README.md` gives the
  inequality; a multipath configuration that queues I/O for longer than
  the cluster waits for a silent node defeats any shared-disk design.
