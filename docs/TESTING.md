# cetrafs — Deployment Test Plan (layer decomposition)

Goal: gain confidence cetrafs does not lose data, and when a fault appears,
isolate which LAYER caused it. Mature layers are the oracle: if a layer
corrupts in isolation, the bug is NOT cetrafs.

## Stack (bottom → top)

| L | Layer | Trust |
|---|---|---|
| L0 | SAN array + FC fabric + blade | mature |
| L1 | VMware ESXi + shared-LUN presentation to the Proxmox VMs (RDM / multi-writer) | mature code, **config is the risk** |
| L2 | cetrafs, single node | **under test** |
| L3 | cetrafs, 3-node cluster | **under test** |
| L4 | Proxmox/qemu, VM image on cetrafs | mature |
| L5 | guest OS + app | — |

Rule: prove layer N clean before testing N+1. Never debug an L_n symptom
while L_{n-1} is unproven. Keep independent backups until L5 soaks clean.

**This document is about a DEPLOYMENT.** For the automated suites that
gate every change -- `make check`, the randomized content oracle, the
fuzzers, the crash rig and the two-node `ctest` scenarios -- see
`docs/TEST-SUITES.md`. L2 and L3 below assume those are already green:
a layer that fails its own automated gate is not ready to be deployed
and bisected by hand.

---

## L0 — raw LUN (no cetrafs)

Present the LUN to ONE blade/ESXi as a plain VMFS/RDM; test the block device
directly.

- Integrity+load: `fio --name=v --filename=<dev> --rw=randrw --bs=4k --iodepth=32 --size=20G --verify=crc32c --verify_fatal=1 --runtime=2h --time_based`
- Power-loss durability: run `diskchecker.pl` client writing with fsync; cut
  SAN power (IPMI); reboot; `diskchecker.pl ... verify`. **0 committed-but-wrong.**

PASS gate: zero verify errors, zero fsync loss. If this fails, stop — the SAN
cache is not durable (needs battery-backed/flush-honoring); nothing above can be sound.

---

## L1 — VMware shared presentation (the decisive isolation)

LUN shared to all 3 Proxmox VMs (physical-mode RDM, multi-writer, or
passthrough HBA). On EACH Proxmox VM, against the device cetrafs will use:

1. **ATS/CAW passthrough** (cetrafs's cross-node primitive):
   `modprobe cetrafs caw_probe=/dev/sdX; dmesg | tail; rmmod cetrafs`
   Require `max_caw_blocks >= 1`. **If 0 → ESXi is not passing SCSI ATS; cetrafs
   cannot do cross-node atomicity. STOP, fix the presentation.**
2. **Cross-VM coherency** (ESXi must not cache the vdisk per-VM):
   - VM-A: `dd if=/dev/urandom of=/dev/sdX bs=512 count=1 seek=1000000 oflag=direct`
   - VM-B: `blockdev --flushbufs /dev/sdX; dd if=/dev/sdX bs=512 count=1 skip=1000000 | md5sum`
   - Must equal VM-A's pattern. **Mismatch → per-VM caching; cetrafs unsafe here.**
3. No ESXi write-cache that swallows flushes (confirm write-through / honored FUA).

PASS gate: ATS present on all 3, reads coherent across VMs. These two are the
only L1 properties cetrafs depends on; verify empirically, do not assume.

---

## L2 — cetrafs single node

ONE Proxmox VM only. `mkfs.cetra`, mount, then:

- `fio ... --verify=crc32c --fsync=16 --runtime=6h` directly on a cetrafs file.
- `fsstress` on a guest fs image hosted on cetrafs.
- Power-loss: `diskchecker.pl` on a cetrafs file; `echo b > /proc/sysrq-trigger`
  on the Proxmox VM; remount; `fsck.cetra -r`; verify. **0 fsync loss.** fsck may
  report *unacknowledged* residue (orphan / referenced-but-free) — `-r` fixes it;
  that is the per-fsync (not per-syscall) model, not corruption.
- The content oracle against the real device:
  `CT_IMG_DIR=... tests/kernel/churn_oracle.sh` with several seeds and
  `CHURN_ROUNDS` raised. It is the only check here that compares the
  bytes read back against what was WRITTEN, per block, warm and cold
  and after a remount.
- After every run: `fsck.cetra <dev>` clean.

PASS gate: zero fio verify errors; zero fsync loss; fsck clean (post-crash: clean after `-r`);
content oracle clean across seeds.
Isolates cetrafs correctness with NO cross-node effects.

---

## L3 — cetrafs cluster (3 nodes)

Mount on all 3. Run the two-node suite (`ctest/`, if reachable) + concurrent
load:

- `fio --verify=crc32c` in parallel on all 3 nodes, distinct files.
- Hard-kill one node (IPMI power off) mid-write; survivors must stay clean;
  `/proc/.../cluster` shows the dead row reclaimed; `fsck.cetra -r` clean.
- Fill to ~100%, keep writing: clean `ENOSPC`, no corruption.

Watch on every node during/after: `dmesg | grep -i cetrafs` (any `EUCLEAN` /
`leaking` / `WARNING` / `BUG` is a finding) and `/proc/fs/cetrafs/<dev>/info`:
`cas_miscompares` (must rise under contention — 0 means nodes never meet),
`scrub_reclaimed`, `free_data_blocks` (no drift).

PASS gate: zero verify errors across nodes; fsck clean; no leak growth; no split-brain.

---

## L4 — Proxmox/qemu on cetrafs

VM disk images on cetrafs, `cache=none`, `nofilelock` mount.

- Guest `fio --verify=crc32c --fsync=16` inside the VM.
- Live-migrate the VM **while guest fio runs** → migration completes, 0 verify errors.
- Snapshot → migrate → delete snapshot, under load → VM boots, data intact, fsck clean.
- Back-and-forth migrate ×50 under load.

PASS gate: guest verify clean through every migration/snapshot.

---

## L5 — full stack / HA

All of the above concurrently + multi-week soak + Proxmox HA fencing enabled
(STONITH — required; cetrafs liveness is a timeout, self-fences a reclaimed
node but relies on HA to kill a partitioned-but-alive node).

- Kill a node running VMs → HA restarts them on survivors → images intact, boot, data verify.
- Network-partition a node → it must be fenced by HA (not keep writing).

---

## Fault isolation (symptom → bisect)

| Symptom | Reproduce at | If clean there | If dirty there |
|---|---|---|---|
| Guest fs corruption | L2 (single-node fio-verify) | → L3/L4/L1 (cross-node or qemu or ESXi coherency) | cetrafs single-node, or L0/L1 |
| Data lost after power cut | L0 raw, then L2 | L0 clean + L2 lost → cetrafs fsync/flush | L0 lost → SAN cache not durable |
| Corrupt only after migration/concurrent | L1 §2 coherency + §1 ATS | ATS+coherency OK → cetrafs L3 | ESXi caching/ATS → below cetrafs |
| Two nodes both writing / split-brain | L1 ATS (`caw_probe`), HA fencing | ATS OK + no fence → HA misconfig | `caw_probe=0` → ESXi not passing ATS |
| Leaked space (fsck "leaked") | L3 | — | cetrafs; check `scrub_reclaimed` rising, else report |
| Guest reads data it never wrote | L2 (content oracle) | → L3/L4 | cetrafs; **fsck will NOT catch this** -- see below |
| Slow metadata | expected | — | per-op cost is device round trips, not a bug |

---

## fsck clean is not the same as data correct

Worth stating on its own, because it cost a week to learn: a filesystem
can be perfectly CONSISTENT and still hand back the wrong bytes. On
2026-10-28 a punch that split a preallocated extent dropped the
"uninitialized" flag, so blocks that had never been written began
serving a deleted file's contents. Throughout, `fsck.cetra` reported
OK: one owner per block, every count matching the bitmaps, no overlap,
no leak. There was nothing inconsistent to find.

So at every layer, `fsck` clean is necessary and not sufficient. The
checks that can catch this class are the ones that know what the bytes
were SUPPOSED to be -- `fio --verify`, and the content oracle at L2 --
and at least one of them has to run before a layer is called clean.

---

## Confidence bar

cetrafs is from-scratch: heavily reviewed + tested (~1757 single-node asserts
across 164 suites, ~67 multi-node ctest scenarios on two rigs, fuzzing, a
crash rig, and a randomized content oracle whose seeded replays caught
microsecond-window corruption races at one-in-millions per-operation odds
-- see docs/TEST-SUITES.md) but NOT production-aged like VMFS/ext4.
Ship to real data only after: L1 gates pass, L2 power-loss clean ×dozens,
L3–L4 load soak ≥ weeks with zero verify errors and no unexpected fsck finding,
HA fencing configured. Keep independent backups (to OTHER storage) throughout.
