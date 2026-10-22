#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""cetrafs metadata fuzzer.

Two modes over one mutation engine:

  fsck   -- run fsck.cetra (ideally an ASAN/UBSAN build) against mutated
            images. Safe, userspace-only, meant for thousands of
            iterations. A finding is a signal death, an ASAN report, an
            unknown exit code, or a hang.
  mount  -- loop-mount mutated images and exercise them. Kernel-side, so
            a finding can wedge or crash the HOST: bounded iterations,
            stops at the first dmesg BUG/Oops. A finding is an Oops, a
            hung mount/umount, or a mount that succeeds and then dies
            exercising basic ops.

Mutations are reproducible: every finding prints the seed and the exact
mutation, and the mutated image is saved under findings/.

Mutating inside block 0 is followed by sb_restamp, so the superblock's
checksum is VALID and the mutation reaches the geometry/validation code
instead of dying at the CRC -- which is exactly what a hostile image
author would do. Deeper structures keep their own checksums as-is: raw
mutations there test the checksum layers themselves plus everything
unchecksummed (bitmaps, journal slot payloads vs their headers).
"""
import os
import random
import signal
import struct
import subprocess
import sys
import time

BLOCK = 4096


# A fuzzed (checksum-valid) structure can make a tool emit enormous output
# -- measured: fsck.cetra printing ~1.4 GiB on one crafted inode, which
# capture_output=True buffered until the fuzzer OOM'd. Cap the child's total
# write via RLIMIT_FSIZE (so it is killed with SIGXFSZ -- itself a finding,
# "runaway output") and keep only the first OUT_CAP bytes. 16 MiB is orders
# of magnitude past any sane fsck/ls output, so hitting it IS a defect.
OUT_CAP = 16 << 20


def _cap_fsize():
    import resource
    resource.setrlimit(resource.RLIMIT_FSIZE, (OUT_CAP, OUT_CAP))


def run(cmd, timeout, env=None):
    import tempfile
    try:
        with tempfile.TemporaryFile() as tf:
            p = subprocess.run(cmd, stdout=tf, stderr=subprocess.STDOUT, timeout=timeout,
                               env=env, preexec_fn=_cap_fsize)
            tf.seek(0)
            return p.returncode, tf.read(OUT_CAP)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", b""
    except FileNotFoundError:
        return 127, b""  # tool not installed: never a finding


class Mutator:
    """One mutation = (region bias, kind). Applied in place, revertible."""

    def __init__(self, rng, img_size):
        self.rng = rng
        self.img_size = img_size

    def pick_offset(self):
        r = self.rng.random()
        if r < 0.25:
            return self.rng.randrange(0, BLOCK)  # superblock itself
        if r < 0.70:
            return self.rng.randrange(0, min(8 << 20, self.img_size))  # global metadata region
        return self.rng.randrange(0, self.img_size)  # anywhere

    def make(self):
        off = self.pick_offset()
        kind = self.rng.choice(["bitflip", "bytes", "zeros", "ones", "u64"])
        if kind == "bitflip":
            return off, kind, 1, self.rng.randrange(8)
        if kind == "bytes":
            n = self.rng.randrange(1, 9)
            return off, kind, n, bytes(self.rng.randrange(256) for _ in range(n))
        if kind in ("zeros", "ones"):
            n = self.rng.randrange(16, 513)
            return off, kind, n, None
        # u64: aligned, biased toward "huge" and "block-0-ish" values --
        # the two families that break offset math
        off &= ~7
        v = self.rng.choice(
            [0, 1, self.rng.randrange(1 << 32), self.rng.randrange(1 << 63), (1 << 64) - 1,
             self.img_size // BLOCK + self.rng.randrange(1 << 20)])
        return off, kind, 8, struct.pack("<Q", v)

    def apply(self, fd, m):
        off, kind, n, arg = m
        n = min(n, self.img_size - off)
        os.lseek(fd, off, 0)
        orig = os.read(fd, n)
        if kind == "bitflip":
            data = bytes([orig[0] ^ (1 << arg)])
        elif kind == "zeros":
            data = b"\x00" * n
        elif kind == "ones":
            data = b"\xff" * n
        else:
            data = arg[:n]
        os.pwrite(fd, data, off)
        return off, orig

    @staticmethod
    def revert(fd, off, orig):
        os.pwrite(fd, orig, off)


def dmesg_since(marker):
    rc, out = run(["dmesg"], 20)
    txt = out.decode(errors="replace")
    idx = txt.rfind(marker)
    return txt[idx:] if idx >= 0 else txt


KERNEL_BAD = ("BUG:", "Oops", "WARNING:", "Call trace", "Call Trace", "RIP:", "kernel NULL",
              "KASAN", "UBSAN", "general protection")


def save_finding(findings_dir, i, seed, m, why, extra, work_img):
    os.makedirs(findings_dir, exist_ok=True)
    tag = f"iter{i}"
    subprocess.run(["sync"], capture_output=True)
    subprocess.run(["cp", "--sparse=always", work_img, os.path.join(findings_dir, tag + ".img")], check=True)
    with open(os.path.join(findings_dir, tag + ".txt"), "w") as f:
        f.write(f"seed={seed} iter={i}\nmutation={m!r}\nwhy={why}\n\n{extra}\n")
    print(f"  FINDING [{why}] saved as {findings_dir}/{tag}.img (+.txt)", flush=True)



# ---------------------------------------------------------------------------
# Stage 2: field-aware mutation. Stage 1 mutates blindly and only sb_restamp
# makes the SUPERBLOCK's checksum valid, so a mutation of any deeper
# structure dies at ITS checksum before its parser runs. Stage 2 targets one
# checksummed structure at a time (ZG/BG/inode/Node-Registry record, or a
# dirent/leaf/xattr block tail), mutates a field, and restamps THAT
# structure (fuzz_restamp) so a hostile-but-checksum-valid record reaches the
# parser behind it.
# ---------------------------------------------------------------------------

TAIL_MAGICS = {0x44424c4b, 0x4c424c4b, 0x58424c4b, 0x49424c4b}  # DBLK LBLK XBLK IBLK
INODE_CSUM_LEN = 204   # sizeof(cetrafs_inode_t); mutate only the record, not the pad


def parse_info(restamp, image):
    rc, out = run([restamp, image, "info"], 20)
    if rc != 0:
        sys.exit(f"fuzz_restamp info failed ({rc})")
    g = {}
    for line in out.decode().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            g[k.strip()] = int(v)
    return g


def field_targets(restamp, golden, mode):
    """Enumerate (type, byte_offset, mut_lo, mut_hi) for every checksummed
    structure in the golden image. Layout comes from the superblock; tail
    blocks are found by scanning for their trailing magic."""
    g = parse_info(restamp, golden)
    B = BLOCK
    t = [("sb", 0, 0, 424)]
    for i in range(g["zone_group_count"]):
        t.append(("zg", (g["zg_table_start"] + i) * B, 0, B))      # hot+cold both restamped
    for i in range(g["block_group_count"]):
        t.append(("bg", (g["bg_table_start"] + i) * B, 0, B))
    size = os.path.getsize(golden)
    fd = os.open(golden, os.O_RDONLY)
    try:
        # allocated inodes: one record per block, ino field (first 8 bytes) nonzero
        for ino in range(1, g["inodes_count"] + 1):
            off = (g["inode_table_start"] + (ino - 1)) * B
            if off + 8 <= size and int.from_bytes(os.pread(fd, 8, off), "little"):
                t.append(("inode", off, 0, INODE_CSUM_LEN))
        # every Node Registry row (a FREE/zero row mutated to REGISTERED + restamped
        # exercises the row parser too)
        nts, ntc, nes = g["node_table_start"], g["node_table_count"], g["node_entry_size"]
        for i in range(ntc):
            off = nts * B + i * nes
            if off + nes <= size:
                t.append(("node", off, 0, nes))
        # tail-checksummed blocks (dirent/leaf/interior/xattr), found by magic.
        # The golden is a sparse half-GiB; walk only its DATA extents (via
        # SEEK_DATA/SEEK_HOLE) so this touches the ~tens of MB that are real,
        # not every page of the 560 MiB -- scanning the whole file through a
        # full-size mmap faulted it all in (measured: 554 MiB RSS -> OOM).
        start = g["bg_regions_start"] * B
        pos = start
        while pos < size:
            try:
                ds = os.lseek(fd, pos, os.SEEK_DATA)
            except OSError:
                break  # no more data to the end
            try:
                de = os.lseek(fd, ds, os.SEEK_HOLE)
            except OSError:
                de = size
            off = (ds // B) * B
            if off < start:
                off = start
            while off + B <= de:
                if int.from_bytes(os.pread(fd, 4, off + B - 8), "little") in TAIL_MAGICS:
                    t.append(("tail", off, 0, B - 8))
                off += B
            pos = de
    finally:
        os.close(fd)
    # Journal replay only runs at MOUNT, and only when a node's flag block is
    # DIRTY -- which the clean golden never is. For mount-fields the loop plants
    # a replayable entry into node 0's slot 0 each iteration; target the whole
    # slot (header + payload) so a mutation of target_lba or the payload reaches
    # journal.c's redo. header_off is deterministic from the geometry.
    if mode == "mount-fields" and g.get("node_journal_start") and \
       g.get("node_journal_blocks", 0) >= 1 + 2:
        hdr_off = (g["node_journal_start"] + 1) * B
        t.append(("journal", hdr_off, 0, 2 * B))
    return t


def field_mutate(fd, rng, lo, hi):
    """Mutate 1..32 bytes somewhere in [lo, hi). Returns (off, orig) to revert."""
    off = rng.randrange(lo, hi)
    kind = rng.choice(["bitflip", "bytes", "zeros", "ones", "u64"])
    if kind == "bitflip":
        n = 1
    elif kind == "u64":
        n = 8
    elif kind == "bytes":
        n = rng.randrange(1, 9)
    else:
        n = rng.randrange(4, 33)
    n = min(n, hi - off)
    os.lseek(fd, off, 0)
    orig = os.read(fd, n)
    if kind == "bitflip":
        data = bytes([orig[0] ^ (1 << rng.randrange(8))])
    elif kind == "zeros":
        data = b"\x00" * n
    elif kind == "ones":
        data = b"\xff" * n
    elif kind == "u64":
        v = rng.choice([0, 1, rng.randrange(1 << 32), rng.randrange(1 << 63), (1 << 64) - 1])
        data = struct.pack("<Q", v)[:n]
    else:
        data = bytes(rng.randrange(256) for _ in range(n))
    os.pwrite(fd, data, off)
    return off, orig


# Write/namespace exercise for mount-fields: drives the kernel's allocate,
# extent insert/merge/spill, truncate, interior-punch, dirent add/remove,
# rename, xattr and free paths AGAINST the mutated (checksum-valid)
# structures -- the read-only ls/cat/listxattr never touch any of them.
# Every op is best-effort (errors are fine, a hang or Oops is the finding).
MOUNT_EXERCISE = r"""
import os, sys, ctypes
m = sys.argv[1]
libc = ctypes.CDLL("libc.so.6", use_errno=True)
def t(fn):
    try:
        fn()
    except Exception:
        pass
def rw(p):
    fd = os.open(m + p, os.O_RDWR)
    try:
        os.pwrite(fd, b"Z" * 8192, 0)                 # overwrite early blocks
        os.pwrite(fd, b"Y" * 4096, 40 * 4096)         # grow -> allocate + extent insert/merge/spill
        os.ftruncate(fd, 200 * 4096)                  # grow past end
        os.ftruncate(fd, 3 * 4096)                    # shrink -> leaf trim / depth revert
        libc.fallocate(fd, 0x03, ctypes.c_long(4096), ctypes.c_long(4096))  # interior punch -> split
        os.fsync(fd)
    finally:
        os.close(fd)
for p in ("/f0", "/deep", "/holey", "/d1/file1", "/hard"):
    t(lambda p=p: rw(p))
# Also drive the write path against EVERY named regular file, so whichever
# inode the structure-aware crafter mutated (a random one, not necessarily in
# the fixed list above) gets its get_block/truncate/punch exercised against
# the hostile tree, not just read by ls/stat.
def walk_rw(d):
    try:
        for e in os.scandir(m + d):
            if e.is_file(follow_symlinks=False):
                t(lambda p=d + "/" + e.name: rw(p))
    except Exception:
        pass
walk_rw("")
walk_rw("/d1")
t(lambda: os.mkdir(m + "/d1/nd"))
for i in range(8):
    t(lambda i=i: os.close(os.open(m + "/d1/n%d" % i, os.O_CREAT | os.O_WRONLY, 0o644)))
t(lambda: os.rename(m + "/f0", m + "/f0r"))
t(lambda: os.setxattr(m + "/deep", "user.fz", b"x" * 64))
t(lambda: os.unlink(m + "/hard"))
t(lambda: [None for _ in os.scandir(m + "/d1")])
"""


def run_stage2(args, rng, fd, loop, env, t0, targets):
    work = args.golden + ".work"
    kinds = {}
    for typ, *_ in targets:
        kinds[typ] = kinds.get(typ, 0) + 1
    print(f"  targets: {kinds}", flush=True)
    findings = 0
    exercised = 0   # restamp succeeded, so the mutant reached the parser with a valid checksum
    rejected = 0    # fsck/mount still reported a checksum/CRC problem (restamp gap -- should be ~0)
    noticed = 0     # fsck/mount noticed a NON-checksum problem (mutation reached deeper logic)
    mounted = 0
    for i in range(args.iters):
        # Start every iteration from a PRISTINE golden. Both modes write
        # the work image now -- mount replays + the write exercise, and the
        # structure-aware crafter + multi-field mutator here -- so a fresh
        # base each iteration is simpler and sounder than reverting. cp
        # rewrites work in place (same inode), so the open fd stays valid.
        subprocess.run(["cp", "--sparse=always", args.golden, work], check=True)
        if args.mode == "mount-fields":
            # node 0's journal replayable, so EVERY mount exercises replay
            run([args.restamp, work, "plant-journal"], 10)
        typ, base, lo, hi = rng.choice(targets)
        if typ == "inode" and rng.random() < 0.5:
            # structure-aware: a valid-header, hostile-content extent tree
            # (overlaps/huge-len/metadata-or-oob targets/zero-len/dup, and
            # depth-1 with a crafted leaf, depth-2 with a crafted interior
            # IBLK) -- the coupled case a byte flip cannot build. craft-tree
            # restamps the inode itself. 12 variants: 0-5 depth-0, 6-7 depth-1,
            # 8-11 depth-2 (the interior level only the deep tree reaches).
            run([args.restamp, work, "craft-tree", str(base), str(rng.randrange(12))], 10)
            exercised += 1
        else:
            # multi-field: 1..4 coordinated byte mutations, then one restamp
            for _ in range(rng.randint(1, 4)):
                field_mutate(fd, rng, base + lo, base + hi)
            os.fsync(fd)
            rrc, _ = run([args.restamp, work, "stamp", typ, str(base)], 10)
            if rrc == 0:
                exercised += 1
        why = None
        extra = ""
        if args.mode == "fsck-fields":
            run(["blockdev", "--flushbufs", loop], 10)
            rc, out = run([args.fsck, loop], 15, env=env)
            txt = out.decode(errors="replace")
            if rc == "TIMEOUT":
                why = "hang"
            elif isinstance(rc, int) and rc < 0:
                why, extra = f"signal {signal.Signals(-rc).name}", txt[-4000:]
            elif b"AddressSanitizer" in out or b"UndefinedBehaviorSanitizer" in out or b"runtime error:" in out:
                why, extra = "sanitizer", txt[-4000:]
            elif rc not in (0, 1, 2, 3):
                why, extra = f"exit {rc}", txt[-2000:]
            else:
                low = txt.lower()
                if "crc" in low or "checksum" in low:
                    rejected += 1
                elif rc == 1:
                    noticed += 1
        else:  # mount-fields
            marker = f"fuzz-fields-iter-{i}-{args.seed}"
            with open("/dev/kmsg", "w") as k:
                k.write(marker + "\n")
            run(["blockdev", "--flushbufs", loop], 10)
            rc, _ = run(["mount", "-t", "cetrafs", loop, args.mnt], 150)  # gate may wait up to the clamped live-peer window (~120s)
            if rc == "TIMEOUT":
                why = "mount hang"
            elif rc == 0:
                mounted += 1
                for label, cmd in (("ls", ["ls", "-laR", args.mnt]),
                                   ("write-exercise", ["python3", "-c", MOUNT_EXERCISE, args.mnt])):
                    rc2, _ = run(cmd, 30)
                    if rc2 == "TIMEOUT":
                        why = f"op hang: {label}"
                        break
                rc3, _ = run(["umount", args.mnt], 30)
                if why is None and rc3 == "TIMEOUT":
                    why = "umount hang"
            d = dmesg_since(marker)
            if why is None and any(b in d for b in KERNEL_BAD):
                why = "kernel splat"
            if why:
                extra = d[-6000:]

        if why:
            findings += 1
            save_finding(args.findings, i, args.seed, (typ, base), why, extra, work)
            if args.mode == "mount-fields":
                print("stopping: kernel state is suspect after a finding", flush=True)
                break

        if (i + 1) % 200 == 0:
            tail = f", mounted={mounted}" if args.mode == "mount-fields" else f", noticed={noticed}, rejected={rejected}"
            print(f"  {i + 1}/{args.iters} ({(i + 1) / (time.time() - t0):.0f}/s), "
                  f"findings={findings}, exercised={exercised}{tail}", flush=True)

    n_done = args.iters if not (args.mode == "mount-fields" and findings) else i + 1
    print(f"done: {n_done} iterations, {findings} finding(s), {time.time() - t0:.0f}s", flush=True)
    # P2: a run proves nothing unless the restamped mutants actually reached the
    # parsers. exercised==0 means every restamp failed (fuzz_restamp broken);
    # for fsck, noticed==0 over a long run means the mutations never reached
    # deeper logic (restamp is hiding every change, or targets are wrong).
    if exercised == 0:
        print("WARNING: no mutant was successfully restamped -- nothing was exercised", flush=True)
    elif args.mode == "fsck-fields" and noticed == 0 and rejected == 0:
        print("WARNING: no mutation changed what fsck reports -- coverage is suspect", flush=True)
    elif args.mode == "mount-fields" and mounted == 0:
        print("WARNING: no mutated image ever mounted -- the exercise path never ran", flush=True)
    sys.exit(1 if findings else 0)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["fsck", "mount", "fsck-fields", "mount-fields"])
    ap.add_argument("golden")
    ap.add_argument("--iters", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=int(time.time()))
    ap.add_argument("--fsck", default=None, help="fsck binary (fsck mode)")
    ap.add_argument("--restamp", required=True, help="sb_restamp binary")
    ap.add_argument("--findings", default="findings")
    ap.add_argument("--mnt", default=None, help="mountpoint (mount mode)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    size = os.path.getsize(args.golden)
    work = args.golden + ".work"
    # cp --sparse, not shutil.copy: the image is a sparse half-GiB and
    # shutil densifies it -- measured as /tmp filling and the run dying.
    subprocess.run(["cp", "--sparse=always", args.golden, work], check=True)
    fd = os.open(work, os.O_RDWR)
    mut = Mutator(rng, size)
    findings = 0
    print(f"fuzz {args.mode}: {args.iters} iterations, seed={args.seed}, image={size >> 20} MiB", flush=True)

    # Both modes need a loop device: mkfs/fsck and the kernel all require
    # a block device, and the fuzzer mutates the backing FILE -- so the
    # loop's page cache must be flushed before every run or the target
    # reads its own stale cache instead of the mutation.
    rc, out = run(["losetup", "--find", "--show", work], 20)
    if rc != 0:
        sys.exit(f"losetup failed: {out}")
    loop = out.decode().strip()
    if args.mode in ("mount", "mount-fields"):
        os.makedirs(args.mnt, exist_ok=True)

    env = dict(os.environ)
    env["ASAN_OPTIONS"] = "hard_rss_limit_mb=1024:allocator_may_return_null=1:abort_on_error=1:detect_leaks=0"
    env["UBSAN_OPTIONS"] = "halt_on_error=1:abort_on_error=1"
    # fsck watches a live-looking node row for CETRAFS_PEER_PROBE_SECS before
    # it will run; fuzzing node rows legitimately produces live-looking ones,
    # and the default 20s watch exceeds the per-run timeout -> false "hang".
    # 1s lets the watch resolve (no peer actually heartbeats) without masking
    # a genuine spin, which the timeout still catches.
    env["CETRAFS_PEER_PROBE_SECS"] = "1"

    t0 = time.time()
    try:
        if args.mode.endswith("-fields"):
            targets = field_targets(args.restamp, args.golden, args.mode)
            run_stage2(args, rng, fd, loop, env, t0, targets)
        else:
            run_loop(args, rng, mut, fd, loop, env, t0)
    finally:
        # ALWAYS detach: a loop left attached to the deleted work image
        # pins its pages in tmpfs invisibly (measured: /tmp "full" with
        # 868K of files) and blocks the next run.
        if args.mode in ("mount", "mount-fields"):
            run(["umount", args.mnt], 20)
        run(["losetup", "-d", loop], 20)
        os.close(fd)
        try:
            os.unlink(work)
        except FileNotFoundError:
            pass


def run_loop(args, rng, mut, fd, loop, env, t0):
    # 'work' is the backing FILE: mutations, sb_restamp and finding
    # copies go there. 'loop' is the block device fsck and mount read,
    # flushed before every run so it sees the file's current bytes.
    work = args.golden + ".work"
    findings = 0
    mounted = 0  # "0 errors" is only evidence if the exercised path RAN
    for i in range(args.iters):
        m = mut.make()
        off, orig = mut.apply(fd, m)
        os.fsync(fd)
        if off < BLOCK:  # mutated the superblock: make its checksum valid
            run([args.restamp, work], 10)

        why = None
        extra = ""
        if args.mode == "fsck":
            run(["blockdev", "--flushbufs", loop], 10)
            rc, out = run([args.fsck, loop], 15, env=env)
            if rc == "TIMEOUT":
                why, extra = "hang", ""
            elif isinstance(rc, int) and rc < 0:
                why, extra = f"signal {signal.Signals(-rc).name}", out.decode(errors="replace")[-4000:]
            elif b"AddressSanitizer" in out or b"UndefinedBehaviorSanitizer" in out or b"runtime error:" in out:
                why, extra = "sanitizer", out.decode(errors="replace")[-4000:]
            elif rc not in (0, 1, 2, 3):
                why, extra = f"exit {rc}", out.decode(errors="replace")[-2000:]
        else:
            marker = f"fuzz-mount-iter-{i}-{args.seed}"
            with open("/dev/kmsg", "w") as k:
                k.write(marker + "\n")
            run(["blockdev", "--flushbufs", loop], 10)
            rc, out = run(["mount", "-t", "cetrafs", loop, args.mnt], 30)
            if rc == "TIMEOUT":
                why = "mount hang"
            elif rc == 0:
                mounted += 1
                # exercise: every op bounded, failures are fine, hangs are not
                for cmd in (["ls", "-laR", args.mnt], ["cat"] + [args.mnt + "/f0"],
                            ["touch", args.mnt + "/fz"], ["stat", "-f", args.mnt],
                            ["python3", "-c", "import os,sys; os.listxattr(sys.argv[1])", args.mnt + "/f0"]):
                    rc2, _ = run(cmd, 20)
                    if rc2 == "TIMEOUT":
                        why = f"op hang: {cmd[0]}"
                        break
                rc3, _ = run(["umount", args.mnt], 30)
                if why is None and rc3 == "TIMEOUT":
                    why = "umount hang"
            d = dmesg_since(marker)
            if why is None and any(b in d for b in KERNEL_BAD):
                why = "kernel splat"
            if why:
                extra = d[-6000:]

        if why:
            findings += 1
            save_finding(args.findings, i, args.seed, m, why, extra, work)
            if args.mode == "mount":
                print("stopping: kernel state is suspect after a finding", flush=True)
                break

        Mutator.revert(fd, off, orig)
        os.fsync(fd)
        if off < BLOCK:
            run([args.restamp, work], 10)  # restore a valid checksum over the reverted bytes
        if (i + 1) % 200 == 0:
            extra = f", mounted={mounted}" if args.mode == "mount" else ""
            print(f"  {i + 1}/{args.iters} ({(i + 1) / (time.time() - t0):.0f}/s), findings={findings}{extra}",
                  flush=True)

    n_done = args.iters if not (args.mode == "mount" and findings) else i + 1
    if args.mode == "mount":
        print(f"done: {n_done} iterations ({mounted} mounted, {n_done - mounted} refused), "
              f"{findings} finding(s), {time.time() - t0:.0f}s", flush=True)
        if mounted == 0:
            print("WARNING: no mutated image ever mounted -- the exercise path never ran, "
                  "so this run proves refusal only", flush=True)
    else:
        print(f"done: {n_done} iterations, {findings} finding(s), {time.time() - t0:.0f}s", flush=True)
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
