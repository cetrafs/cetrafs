#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# enospc_fill.py -- drive ONE allocating path into ENOSPC on a cetrafs
# mount and report what it did. Used by tests/kernel/enospc_deliberate.sh.
#
#   enospc_fill.py <mnt> <mode> [--canary-check]
#
# Modes (each fills the volume through that path until it refuses):
#   write      buffered write(2) of new files
#   odirect    O_DIRECT write(2) of new files
#   fallocate  fallocate(2) of new files, KEEP_SIZE off
#   dir        create(2) of many names in one directory
#   xattr      setxattr(2) of growing values on one file
#   extent     a file written sparsely, one block per extent, on top of a
#              full volume -- every new extent needs the tree to grow
#
# Prints "ENOSPC=<errno seen> ..." on the first line and "OK"/"BAD <why>"
# on the last. The caller decides from that line; this script never
# exits 0 on a failure it saw.
import ctypes
import errno
import hashlib
import mmap
import os
import sys

BLK = 4096
CHUNK = 1 << 20
FALLOC_FL_KEEP_SIZE = 0x01
libc = ctypes.CDLL("libc.so.6", use_errno=True)


def pattern(tag, idx, n):
    """n bytes that identify (tag, idx): another file's data never matches."""
    seed = hashlib.sha256(("%s/%d" % (tag, idx)).encode()).digest()
    return (seed * (n // len(seed) + 1))[:n]


def fail(msg):
    print("BAD " + msg)
    sys.stdout.flush()
    sys.exit(0)


def check_file(path, tag, idx, nbytes):
    """Every block is the one this file was written with, or zeros (a
    write the device refused after write(2) returned). Anything else is
    another file's data or garbage. idx is the file's own index: its
    content is pattern(tag, idx, CHUNK)."""
    want = pattern(tag, idx, CHUNK)
    with open(path, "rb") as f:
        data = f.read(nbytes)
    for b in range(0, len(data), BLK):
        blk = data[b:b + BLK]
        if blk == b"\0" * len(blk):
            continue
        if blk != want[b:b + len(blk)]:
            return "block %d of %s is neither its own data nor zero" % (b // BLK, path)
    return None


def fill_files(mnt, mode, tag):
    """write / odirect / fallocate: new files of CHUNK bytes until ENOSPC."""
    got = 0
    seen = 0
    files = []
    buf = None
    if mode == "odirect":
        buf = mmap.mmap(-1, CHUNK)
    n = 0
    while n < 4096:
        path = os.path.join(mnt, "%s_%04d" % (tag, n))
        flags = os.O_WRONLY | os.O_CREAT
        if mode == "odirect":
            flags |= os.O_DIRECT
        try:
            fd = os.open(path, flags, 0o644)
        except OSError as e:
            if e.errno == errno.ENOSPC:
                seen = errno.ENOSPC
                break
            fail("create %s: %s" % (path, errno.errorcode.get(e.errno, e.errno)))
        files.append(path)
        try:
            if mode == "fallocate":
                rc = libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(CHUNK))
                if rc:
                    e = ctypes.get_errno()
                    if e == errno.ENOSPC:
                        seen = errno.ENOSPC
                        os.close(fd)
                        break
                    fail("fallocate %s: %s" % (path, errno.errorcode.get(e, e)))
                # Written afterwards, so the content check has data to look at.
                os.pwrite(fd, pattern(tag, n, CHUNK), 0)
            elif mode == "odirect":
                buf[:] = pattern(tag, n, CHUNK)
                os.write(fd, buf)
            else:
                os.write(fd, pattern(tag, n, CHUNK))
            # fsync is where a buffered allocation is refused.
            os.fsync(fd)
            os.close(fd)
            got += 1
        except OSError as e:
            try:
                os.close(fd)
            except OSError:
                pass
            if e.errno == errno.ENOSPC:
                seen = errno.ENOSPC
                break
            fail("%s %s: %s" % (mode, path, errno.errorcode.get(e.errno, e.errno)))
        n += 1
    return seen, got, files


def main():
    mnt, mode = sys.argv[1], sys.argv[2]
    tag = "f" + mode
    if mode in ("write", "odirect", "fallocate"):
        seen, got, files = fill_files(mnt, mode, tag)
        if not seen:
            fail("the volume never refused a %s: %d files written" % (mode, got))
        # The file the refused operation was creating is not in the list
        # if it failed at create; anything listed must hold only its own
        # data (or zeros).
        for n, path in enumerate(files):
            if os.path.getsize(path) == 0:
                continue
            why = check_file(path, tag, n, os.path.getsize(path))
            if why:
                fail(why)
        print("ENOSPC=%d files=%d mode=%s" % (seen, got, mode))
        print("OK")
    elif mode == "dir":
        d = os.path.join(mnt, "fdir")
        os.mkdir(d)
        got = 0
        seen = 0
        for n in range(20000):
            try:
                fd = os.open(os.path.join(d, "n%06d" % n), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            except OSError as e:
                if e.errno == errno.ENOSPC:
                    seen = errno.ENOSPC
                    break
                fail("create n%06d: %s" % (n, errno.errorcode.get(e.errno, e.errno)))
            os.write(fd, b"x")
            os.close(fd)
            got += 1
        if not seen:
            fail("the directory never refused a create: %d names" % got)
        names = sorted(os.listdir(d))
        if len(names) != got:
            fail("directory lists %d names after ENOSPC, %d were created" % (len(names), got))
        for nm in names:
            with open(os.path.join(d, nm), "rb") as f:
                if f.read() != b"x":
                    fail("entry %s lost its content" % nm)
        print("ENOSPC=%d files=%d mode=dir" % (seen, got))
        print("OK")
    elif mode == "xattr":
        p = os.path.join(mnt, "fxattr")
        open(p, "w").close()
        got = 0
        seen = 0
        val = b"v" * 200
        for n in range(4000):
            try:
                os.setxattr(p, "user.k%05d" % n, val)
            except OSError as e:
                if e.errno == errno.ENOSPC:
                    seen = errno.ENOSPC
                    break
                fail("setxattr k%05d: %s" % (n, errno.errorcode.get(e.errno, e.errno)))
            got += 1
        if not seen:
            fail("the file never refused an xattr: %d set" % got)
        for n in range(got):
            v = os.getxattr(p, "user.k%05d" % n)
            if v != val:
                fail("xattr k%05d lost its value after ENOSPC" % n)
        print("ENOSPC=%d xattrs=%d mode=xattr" % (seen, got))
        print("OK")
    elif mode == "extent":
        # Blocks at every other offset: each write is its own extent, so
        # the extent array spills into a leaf block, which needs space.
        # Fill the volume, then free one whole filler: a little room, so the
        # sparse file gets past the four inline extents (that is what needs
        # a leaf block) and then runs out.
        pre_seen, pre_got, pre_files = fill_files(mnt, "write", "pre")
        if not pre_seen or len(pre_files) < 2:
            fail("could not fill the volume before the sparse writes: %d files" % pre_got)
        os.unlink(pre_files[-2])
        p = os.path.join(mnt, "fsparse")
        fd = os.open(p, os.O_WRONLY | os.O_CREAT, 0o644)
        got = 0
        seen = 0
        for n in range(200000):
            try:
                os.pwrite(fd, pattern("sparse", n, BLK), n * 2 * BLK)
            except OSError as e:
                if e.errno == errno.ENOSPC:
                    seen = errno.ENOSPC
                    break
                fail("pwrite block %d: %s" % (n, errno.errorcode.get(e.errno, e.errno)))
            got += 1
        # Buffered: the allocation for the blocks already written is
        # refused here, at writeback, if the volume is full.
        try:
            os.fsync(fd)
        except OSError as e:
            if e.errno != errno.ENOSPC:
                fail("fsync: %s" % errno.errorcode.get(e.errno, e.errno))
            seen = errno.ENOSPC
        os.close(fd)
        if not seen:
            fail("the sparse file never refused a block: %d written" % got)
        with open(p, "rb") as f:
            for n in range(got):
                f.seek(n * 2 * BLK)
                blk = f.read(BLK)
                if blk != pattern("sparse", n, BLK) and blk != b"\0" * BLK:
                    fail("sparse block %d is neither its own data nor zero after ENOSPC" % n)
        print("ENOSPC=%d blocks=%d mode=extent" % (seen, got))
        print("OK")
    else:
        fail("unknown mode " + mode)


if __name__ == "__main__":
    main()
