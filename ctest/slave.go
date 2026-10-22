// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// maxInlineReadBytes: "read" only echoes file content back over the wire
// (base64) up to this size, purely as a debugging convenience -- the
// checksum is what scenarios actually compare, so there's no reason to
// ship large files through the control-plane protocol.
const maxInlineReadBytes = 64 * 1024

// Slave holds this process's local mount state and open-file-handle
// table. One Slave serves every connection the master opens to it --
// handles are global to the process, not per-connection, since nothing
// here needs per-connection scoping.
type Slave struct {
	// Configuration, fixed at startup and never settable over the wire:
	// this slave mounts THIS device at THIS path, or it does nothing.
	device     string
	mountPoint string
	mkfsPath   string

	mu      sync.Mutex
	mounted bool // whether this process believes the mount is up

	handleSeq atomic.Uint64
	handles   sync.Map // uint64 -> *os.File
}

func runSlave(addr, device, mountPoint, mkfsPath string) error {
	if device == "" {
		return fmt.Errorf("slave: -device is required (the shared block device, e.g. /dev/sda)")
	}
	if mountPoint == "" {
		return fmt.Errorf("slave: -mountpoint must not be empty")
	}
	// Create it up front so a misconfigured path fails here, loudly, at
	// startup -- not silently mid-scenario as a write to the host fs.
	if err := os.MkdirAll(mountPoint, 0755); err != nil {
		return fmt.Errorf("slave: mkdir mountpoint %s: %w", mountPoint, err)
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	log.Printf("ctest slave listening on %s (device=%s mountpoint=%s)", ln.Addr(), device, mountPoint)

	s := &Slave{device: device, mountPoint: mountPoint, mkfsPath: mkfsPath}

	// A slave that dies holding the mount leaves a shared LUN mounted by
	// a node that is no longer participating -- the peer then has to
	// wait out the stale timeout, and whoever is debugging has to work
	// out why a dead node still appears live. Clean up on the way down,
	// on every path that can be caught.
	//
	// Note what is deliberately NOT covered: the exit_uncleanly op,
	// which calls os.Exit and so runs no cleanup at all. Simulating a
	// node that dies WITHOUT unmounting is the entire point of that op
	// (it is how the stale-reclaim paths get exercised), so it must keep
	// bypassing this.
	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		sig := <-sigc
		log.Printf("slave: got %s -- unmounting %s before exiting", sig, s.mountPoint)
		s.cleanupMount()
		os.Exit(1)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			continue
		}
		go s.handleConn(conn)
	}
}

// cleanupMount unmounts if (and only if) our mountpoint really is a
// cetrafs mount right now. Best effort by design: this runs on the way
// out, and nothing useful remains to be done if it fails -- but it is
// logged rather than swallowed, because "the slave said it unmounted"
// is something the next investigation will rely on.
func (s *Slave) cleanupMount() {
	ok, err := isCetrafsMount(s.mountPoint)
	if err != nil || !ok {
		return
	}
	if err := s.doUnmount(UnmountArgs{}); err != nil {
		log.Printf("slave: unmount %s on shutdown failed: %v", s.mountPoint, err)
		return
	}
	log.Printf("slave: unmounted %s", s.mountPoint)
}

func (s *Slave) handleConn(c net.Conn) {
	defer c.Close()
	// An unrecovered panic in this goroutine takes the whole process
	// down, mount and all. Catch it, unmount, then exit nonzero -- the
	// crash is still a crash and still fails the run, it just does not
	// strand the shared device mounted on a node that has gone away.
	defer func() {
		if r := recover(); r != nil {
			log.Printf("slave: PANIC: %v -- unmounting %s before exiting", r, s.mountPoint)
			s.cleanupMount()
			os.Exit(2)
		}
	}()
	fc := newFrameConn(c)
	for {
		req, err := fc.readRequest()
		if err != nil {
			return // peer closed, or EOF
		}
		resp := s.dispatch(req)
		if resp.OK {
			log.Printf("-> id=%d op=%s ok", req.ID, req.Op)
		} else {
			log.Printf("-> id=%d op=%s error=%s", req.ID, req.Op, resp.Error)
		}
		if err := fc.writeResponse(resp); err != nil {
			return
		}
	}
}

func errResp(id uint64, err error) Response {
	return Response{ID: id, OK: false, Error: err.Error()}
}

func okResp(id uint64, result any) Response {
	b, err := json.Marshal(result)
	if err != nil {
		return errResp(id, err)
	}
	return Response{ID: id, OK: true, Result: b}
}

func (s *Slave) dispatch(req Request) Response {
	unmarshalInto := func(v any) error { return json.Unmarshal(req.Args, v) }

	// Log every command this slave receives -- without this, the slave is
	// silent and there's no way to tell from the outside whether it's
	// actually getting hit by the master, stuck, or just quiet because
	// nothing's happening. Args are logged raw (compact JSON) rather than
	// per-op-unmarshaled, so this one line covers every op without needing
	// a case for each.
	log.Printf("<- id=%d op=%s args=%s", req.ID, req.Op, req.Args)

	switch req.Op {
	case "ping":
		return okResp(req.ID, struct{}{})

	case "fsck":
		var a FsckArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doFsck(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "mount":
		var a MountArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		if err := s.doMount(a); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "unmount":
		var a UnmountArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		if err := s.doUnmount(a); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "slave_info":
		return okResp(req.ID, s.slaveInfo())

	case "mkfs":
		var a MkfsArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doMkfs(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "write":
		var a WriteArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doWrite(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "read":
		var a ReadArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doRead(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "write_at":
		var a WriteAtArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doWriteAt(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "read_at":
		var a ReadAtArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doReadAt(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "open_hold":
		var a OpenHoldArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doOpenHold(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "lock_file":
		var a LockFileArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		if err := s.doLockFile(a.Handle, true); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "unlock_file":
		var a UnlockFileArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		if err := s.doLockFile(a.Handle, false); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "close":
		var a CloseArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		if err := s.doClose(a); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "unlink":
		var a UnlinkArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := os.Remove(p); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "rename":
		var a RenameArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		oldp, err := s.resolvePath(a.Old)
		if err != nil {
			return errResp(req.ID, err)
		}
		newp, err := s.resolvePath(a.New)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := os.Rename(oldp, newp); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "mkdir":
		var a MkdirArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if a.Strict {
			if err := os.Mkdir(p, 0755); err != nil {
				return errResp(req.ID, err)
			}
		} else if err := os.MkdirAll(p, 0755); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "rmdir":
		var a RmdirArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := os.Remove(p); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "chmod":
		var a ChmodArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := os.Chmod(p, os.FileMode(a.Mode&0777)); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "truncate":
		var a TruncateArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := os.Truncate(p, a.Size); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "symlink":
		var a SymlinkArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		linkPath, err := s.resolvePath(a.LinkPath)
		if err != nil {
			return errResp(req.ID, err)
		}
		// Target is stored verbatim (symlink semantics -- it's whatever
		// text the caller chose, not necessarily a path that resolves
		// relative to anything on this machine), never joined onto the
		// mountpoint itself.
		if err := os.Symlink(a.Target, linkPath); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "readlink":
		var a ReadlinkArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		target, err := os.Readlink(p)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, ReadlinkResult{Target: target})

	case "link":
		var a LinkArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		oldp, err := s.resolvePath(a.OldPath)
		if err != nil {
			return errResp(req.ID, err)
		}
		newp, err := s.resolvePath(a.NewPath)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := os.Link(oldp, newp); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "xattr_set":
		var a XattrSetArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := syscall.Setxattr(p, a.Name, []byte(a.Value), 0); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "xattr_get":
		var a XattrGetArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doXattrGet(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "xattr_remove":
		var a XattrRemoveArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		if err := syscall.Removexattr(p, a.Name); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "xattr_list":
		var a XattrListArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doXattrList(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "statfs":
		res, err := s.doStatfs()
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "readdir":
		var a ReaddirArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		p, err := s.resolvePath(a.Path)
		if err != nil {
			return errResp(req.ID, err)
		}
		ents, err := os.ReadDir(p)
		if err != nil {
			return errResp(req.ID, err)
		}
		var res ReaddirResult
		for _, e := range ents {
			res.Names = append(res.Names, e.Name())
		}
		return okResp(req.ID, res)

	case "stat":
		var a StatArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doStat(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "proc_snapshot":
		var a ProcSnapshotArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := readProcSnapshot(a.Device)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "device_read":
		var a DeviceReadArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doDeviceRead(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "set_control":
		var a SetControlArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := s.doSetControl(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "mod_param":
		var a ModParamArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := doModParam(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "link_down":
		res, err := s.doDevLink(false)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "link_up":
		res, err := s.doDevLink(true)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "proc_raw":
		var a ProcRawArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := doProcRaw(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "dmesg_tail":
		var a DmesgTailArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		res, err := doDmesgTail(a)
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "dmesg_mark":
		var a DmesgMarkArgs
		if err := unmarshalInto(&a); err != nil {
			return errResp(req.ID, err)
		}
		if err := doDmesgMark(a); err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, struct{}{})

	case "module_info":
		res, err := doModuleInfo()
		if err != nil {
			return errResp(req.ID, err)
		}
		return okResp(req.ID, res)

	case "exit_uncleanly":
		log.Printf("exit_uncleanly requested -- exiting without unmount (kernel-level mount/heartbeat left running)")
		os.Stdout.Sync()
		os.Exit(1)
		return Response{} // unreachable

	default:
		return errResp(req.ID, fmt.Errorf("unknown op %q", req.Op))
	}
}

// Paths from scenarios are always mountpoint-relative (e.g.
// "run-42/file1"), so a scenario never needs to know any node's local
// mountpoint -- that is each slave's own choice, made at startup.
//
// isCetrafsMount asks the KERNEL whether mp is a live cetrafs mount,
// rather than trusting this process's own belief about it.
//
// The belief is not good enough. s.mounted only records that a mount
// command once succeeded (or that one was adopted because `mount` said
// "already mounted"); it survives the filesystem going away underneath
// -- an unmount from another shell, a failed remount in a scenario, a
// mount that silently never happened. In every one of those cases the
// mountpoint is still a perfectly good DIRECTORY on the host root
// filesystem, so every subsequent write succeeds, reads back correctly,
// and passes every assertion the scenario makes. The suite goes green
// having tested nothing, and the evidence is 50 MB of run data sitting
// on the host fs.
//
// This is the same rule tests/mount_test.sh learned the hard way and
// CLAUDE.md states outright: verify you are really on a cetrafs mount
// before doing anything that assumes you are.
func isCetrafsMount(mp string) (bool, error) {
	abs, err := filepath.Abs(mp)
	if err != nil {
		return false, err
	}
	abs = filepath.Clean(abs)

	f, err := os.Open("/proc/self/mounts")
	if err != nil {
		return false, err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		// fields: device mountpoint fstype options dump pass
		fields := strings.Fields(sc.Text())
		if len(fields) < 3 {
			continue
		}
		// Paths in /proc/self/mounts escape spaces and friends as
		// octal; the mountpoints this tool uses have none, but decode
		// anyway rather than silently mismatching if one ever does.
		mnt := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(fields[1])
		if filepath.Clean(mnt) == abs && fields[2] == "cetrafs" {
			return true, nil
		}
	}
	return false, sc.Err()
}

// resolvePath turns a scenario's mountpoint-relative path into an
// absolute one, refusing unless the mountpoint is a live cetrafs mount
// at this very moment (see isCetrafsMount). Every filesystem op goes
// through here, so there is exactly one place this can be got wrong.
func (s *Slave) resolvePath(relPath string) (string, error) {
	s.mu.Lock()
	mp := s.mountPoint
	believed := s.mounted
	s.mu.Unlock()

	ok, err := isCetrafsMount(mp)
	if err != nil {
		return "", fmt.Errorf("checking whether %s is a cetrafs mount: %w", mp, err)
	}
	if !ok {
		if believed {
			// Worth distinguishing: this one means the mount went away
			// underneath a running scenario, which is a finding in
			// itself, not just a misconfigured run.
			return "", fmt.Errorf("%s is NOT a cetrafs mount, though this slave mounted it earlier "+
				"-- it was unmounted underneath us; refusing to write to the host filesystem", mp)
		}
		return "", fmt.Errorf("%s is not a cetrafs mount (send \"mount\" first) "+
			"-- refusing to write to the host filesystem", mp)
	}
	return filepath.Join(mp, relPath), nil
}

func (s *Slave) doMount(a MountArgs) error {
	// Already a live cetrafs mount at our path? Nothing to do -- and
	// adopt it, since the kernel mount can outlive this Go process (a
	// slave restart to pick up a new build leaves the old mount up).
	if ok, err := isCetrafsMount(s.mountPoint); err == nil && ok {
		s.mu.Lock()
		s.mounted = true
		s.mu.Unlock()
		return nil
	}

	if err := os.MkdirAll(s.mountPoint, 0755); err != nil {
		return fmt.Errorf("mkdir mountpoint: %w", err)
	}

	margs := []string{"-t", "cetrafs"}
	if a.NoFileLock {
		margs = append(margs, "-o", "nofilelock")
	}
	margs = append(margs, s.device, s.mountPoint)
	cmd := exec.Command("mount", margs...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("mount %s at %s: %w: %s", s.device, s.mountPoint, err, strings.TrimSpace(stderr.String()))
	}

	// Never take `mount` exiting 0 as proof. Confirm with the kernel,
	// because everything downstream assumes this succeeded and the cost
	// of being wrong is writing a whole run to the host filesystem.
	ok, err := isCetrafsMount(s.mountPoint)
	if err != nil {
		return fmt.Errorf("verifying mount: %w", err)
	}
	if !ok {
		return fmt.Errorf("mount reported success but %s is still not a cetrafs mount", s.mountPoint)
	}

	s.mu.Lock()
	s.mounted = true
	s.mu.Unlock()
	return nil
}

func (s *Slave) doUnmount(a UnmountArgs) error {
	// Not mounted is the desired end state, so reaching it by already
	// being there is success, not an error -- the master unmounts at
	// the end of every scenario and some of those never mounted.
	if ok, err := isCetrafsMount(s.mountPoint); err == nil && !ok {
		s.mu.Lock()
		s.mounted = false
		s.mu.Unlock()
		return nil
	}

	cmd := exec.Command("umount", s.mountPoint)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("umount %s: %w: %s", s.mountPoint, err, strings.TrimSpace(stderr.String()))
	}

	s.mu.Lock()
	s.mounted = false
	s.mu.Unlock()
	return nil
}

// doMkfs runs mkfs.cetra against this slave's own device. A nonzero exit
// is REPORTED, not raised: mkfs refusing to format a mounted device is
// the expected outcome the mkfs-guard scenario is built to require, and
// the master has to be able to tell that apart from mkfs failing to run.
func (s *Slave) doMkfs(a MkfsArgs) (MkfsResult, error) {
	// -mkfs names a mkfs.cetra on this node; without one, fall back to
	// the copy EMBEDDED in this binary. Before that fallback existed,
	// mkfs-guard simply could not run on a fleet where only the build
	// host has the tools -- which is every real fleet -- and it ERRORed
	// on every suite run.
	mkfs := s.mkfsPath
	if mkfs == "" {
		built, err := buildEmbeddedHelper("mkfs")
		if err != nil {
			return MkfsResult{}, fmt.Errorf("no -mkfs given and no usable embedded mkfs: %w", err)
		}
		mkfs = built
	}

	// mkfs.cetra takes the DEVICE first, then flags. Getting this
	// backwards made mkfs fail with "open(-f): No such file or
	// directory" -- which is still a nonzero exit, so the guard
	// scenario's "mkfs refuses a mounted device" assertion passed while
	// mkfs had never even looked at the device. That is why the guard
	// now matches on WHY mkfs refused, not just that it did.
	args := []string{s.device}
	args = append(args, a.Extra...)
	if a.Force {
		args = append(args, "-f")
	}

	cmd := exec.Command(mkfs, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()

	res := MkfsResult{Stdout: stdout.String(), Stderr: stderr.String()}
	if err == nil {
		res.ExitCode = 0
		return res, nil
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		res.ExitCode = ee.ExitCode()
		return res, nil
	}
	// Could not run it at all (missing binary, permissions) -- a real
	// error, distinct from mkfs running and refusing.
	return res, fmt.Errorf("running %s: %w", mkfs, err)
}

// deviceMountPoints returns every path this machine currently has the
// given block device mounted on, matched by device number the way
// mkfs.cetra's own guard does -- NOT by the path string, so /dev/sda
// and a symlink or by-id name for it are the same device here.
//
// This exists because everything else in ctest asks "is MY mountpoint a
// cetrafs mount", which cannot see the same device mounted somewhere
// else. A leftover `make test` mount at /root/cetrafs/test made the
// mkfs-guard scenario report "mkfs failed on an unmounted device" --
// a misdiagnosis of its own environment, since mkfs was right and the
// device genuinely was mounted. A scenario cannot prove anything about
// a device whose state it cannot see.
func deviceMountPoints(dev string) []string {
	var st syscall.Stat_t
	if err := syscall.Stat(dev, &st); err != nil {
		return nil
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFBLK {
		return nil // an image file, not a block device: it cannot appear by name
	}

	f, err := os.Open("/proc/self/mounts")
	if err != nil {
		return nil
	}
	defer f.Close()

	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		var src syscall.Stat_t
		if err := syscall.Stat(fields[0], &src); err != nil {
			continue
		}
		if src.Mode&syscall.S_IFMT != syscall.S_IFBLK || src.Rdev != st.Rdev {
			continue
		}
		mnt := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(fields[1])
		out = append(out, filepath.Clean(mnt))
	}
	return out
}

func (s *Slave) slaveInfo() SlaveInfoResult {
	mounted, _ := isCetrafsMount(s.mountPoint)
	return SlaveInfoResult{
		Device:          s.device,
		MountPoint:      s.mountPoint,
		Mounted:         mounted,
		DeviceMountedAt: deviceMountPoints(s.device),
	}
}

// buildStampedContent repeats stamp to fill exactly size bytes -- a
// verifiable, attributable pattern rather than random bytes, so a
// scenario comparing what landed on disk against what each slave claims
// to have written can tell whose data (if any) got corrupted/interleaved.
func buildStampedContent(stamp string, size int) []byte {
	if stamp == "" {
		stamp = "ctest"
	}
	out := make([]byte, size)
	for i := 0; i < size; i++ {
		out[i] = stamp[i%len(stamp)]
	}
	return out
}

func (s *Slave) doWrite(a WriteArgs) (WriteResult, error) {
	content := buildStampedContent(a.Stamp, a.Size)
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return WriteResult{}, err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return WriteResult{}, fmt.Errorf("mkdir parent: %w", err)
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return WriteResult{}, err
	}
	n, werr := f.Write(content)
	if werr == nil {
		werr = f.Sync()
	}
	cerr := f.Close()
	if werr != nil {
		return WriteResult{}, werr
	}
	if cerr != nil {
		return WriteResult{}, cerr
	}

	sum := sha256.Sum256(content)
	return WriteResult{BytesWritten: n, Checksum: hex.EncodeToString(sum[:])}, nil
}

func (s *Slave) doRead(a ReadArgs) (ReadResult, error) {
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return ReadResult{}, err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return ReadResult{}, err
	}
	sum := sha256.Sum256(content)
	res := ReadResult{Size: int64(len(content)), Checksum: hex.EncodeToString(sum[:])}
	if len(content) <= maxInlineReadBytes {
		res.Content = base64.StdEncoding.EncodeToString(content)
	}
	return res, nil
}

// doWriteAt is the pwrite-style counterpart to doWrite above: writes
// exactly len(content) bytes at a.Offset without truncating or
// otherwise touching the rest of the file, so a multi-GiB sparse file
// (RunSparseBigFile) never has to be materialized in memory just to
// touch a small region at the far end of it.
func (s *Slave) doWriteAt(a WriteAtArgs) (WriteAtResult, error) {
	content := buildStampedContent(a.Stamp, a.Size)
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return WriteAtResult{}, err
	}

	flags := os.O_WRONLY
	if a.Create {
		flags |= os.O_CREATE
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return WriteAtResult{}, fmt.Errorf("mkdir parent: %w", err)
		}
	}

	f, err := os.OpenFile(path, flags, 0644)
	if err != nil {
		return WriteAtResult{}, err
	}
	n, werr := f.WriteAt(content, a.Offset)
	if werr == nil {
		werr = f.Sync()
	}
	cerr := f.Close()
	if werr != nil {
		return WriteAtResult{}, werr
	}
	if cerr != nil {
		return WriteAtResult{}, cerr
	}

	sum := sha256.Sum256(content)
	return WriteAtResult{BytesWritten: n, Checksum: hex.EncodeToString(sum[:])}, nil
}

// doReadAt is the pread-style counterpart to doRead above: reads
// exactly a.Size bytes starting at a.Offset, never the whole file.
func (s *Slave) doReadAt(a ReadAtArgs) (ReadAtResult, error) {
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return ReadAtResult{}, err
	}

	f, err := os.Open(path)
	if err != nil {
		return ReadAtResult{}, err
	}
	defer f.Close()

	buf := make([]byte, a.Size)
	n, err := f.ReadAt(buf, a.Offset)
	if err != nil {
		return ReadAtResult{}, fmt.Errorf("read at offset %d: %w", a.Offset, err)
	}

	sum := sha256.Sum256(buf[:n])
	return ReadAtResult{BytesRead: n, Checksum: hex.EncodeToString(sum[:])}, nil
}

func (s *Slave) doOpenHold(a OpenHoldArgs) (OpenHoldResult, error) {
	var flags int
	switch a.Mode {
	case "rdonly":
		flags = os.O_RDONLY
	case "wronly":
		flags = os.O_WRONLY
	case "rdwr":
		flags = os.O_RDWR
	default:
		return OpenHoldResult{}, fmt.Errorf("bad mode %q (want rdonly|wronly|rdwr)", a.Mode)
	}
	if a.Create {
		flags |= os.O_CREATE
		if a.Excl {
			flags |= os.O_EXCL
		}
	}

	path, err := s.resolvePath(a.Path)
	if err != nil {
		return OpenHoldResult{}, err
	}
	if a.Create {
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return OpenHoldResult{}, fmt.Errorf("mkdir parent: %w", err)
		}
	}

	f, err := os.OpenFile(path, flags, 0644)
	if err != nil {
		return OpenHoldResult{}, err
	}

	handle := s.handleSeq.Add(1)
	s.handles.Store(handle, f)
	return OpenHoldResult{Handle: handle}, nil
}

func (s *Slave) doClose(a CloseArgs) error {
	v, ok := s.handles.LoadAndDelete(a.Handle)
	if !ok {
		return fmt.Errorf("no such handle %d (already closed, or never opened by this process)", a.Handle)
	}
	return v.(*os.File).Close()
}

// doLockFile takes (lock=true) or drops the whole-file exclusive lock on a
// held fd via the standard flock(2) -- cetrafs implements file_operations.flock
// for it. The lock is fd-scoped, so the handle must have been opened via
// open_hold and kept open; this flocks that same fd. LOCK_NB so a contended
// lock returns immediately rather than blocking the RPC.
func (s *Slave) doLockFile(handle uint64, lock bool) error {
	v, ok := s.handles.Load(handle)
	if !ok {
		return fmt.Errorf("no such handle %d (open it with open_hold first)", handle)
	}
	f := v.(*os.File)
	how := syscall.LOCK_UN
	if lock {
		how = syscall.LOCK_EX | syscall.LOCK_NB
	}
	if err := syscall.Flock(int(f.Fd()), how); err != nil {
		return fmt.Errorf("flock(%s): %w", map[bool]string{true: "LOCK_EX", false: "LOCK_UN"}[lock], err)
	}
	return nil
}

func (s *Slave) doStat(a StatArgs) (StatResult, error) {
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return StatResult{}, err
	}
	var info os.FileInfo
	if a.NoFollow {
		info, err = os.Lstat(path)
	} else {
		info, err = os.Stat(path)
	}
	if err != nil {
		return StatResult{}, err
	}
	res := StatResult{Size: info.Size(), Mode: info.Mode().String(), IsDir: info.IsDir()}
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		res.Nlink = uint32(st.Nlink)
		res.ModeBits = uint32(st.Mode & 0777)
		res.Ino = uint64(st.Ino)
	}
	return res, nil
}

// doStatfs runs the real statfs(2) syscall against this slave's current
// mountpoint -- the same call `df` makes, landing straight in
// cetrafs_statfs(). Field widths in syscall.Statfs_t vary by arch
// (int64 vs uint64); the explicit casts below just normalize to uint64
// regardless of which this build's arch uses.
func (s *Slave) doStatfs() (StatfsResult, error) {
	s.mu.Lock()
	mp := s.mountPoint
	s.mu.Unlock()
	if mp == "" {
		return StatfsResult{}, fmt.Errorf("not mounted (this slave process has no active mount -- send \"mount\" first)")
	}

	var st syscall.Statfs_t
	if err := syscall.Statfs(mp, &st); err != nil {
		return StatfsResult{}, err
	}

	return StatfsResult{
		BlockSize:   int64(st.Bsize),
		TotalBlocks: uint64(st.Blocks),
		FreeBlocks:  uint64(st.Bfree),
		AvailBlocks: uint64(st.Bavail),
		TotalFiles:  uint64(st.Files),
		FreeFiles:   uint64(st.Ffree),
	}, nil
}

// doXattrGet: Getxattr wants a destination buffer sized up front, not a
// query-the-size-first dance -- 64KiB comfortably covers anything this
// format's one-xattr-block-per-inode layout (xattr.c) could ever hold
// (~12 entries in a 4096-byte block). ENODATA/ENOATTR means "not set",
// reported as Found:false rather than an error, since "does the other
// node see this xattr at all" is exactly what a cross-node check wants
// to ask without every caller needing to know that errno.
// doXattrList: one 4096-byte buffer is enough for anything this format's
// one-xattr-block-per-inode layout (xattr.c, ~12 entries x 64-byte keys)
// could ever hold -- same reasoning as doXattrGet below. Listxattr
// returns the names NUL-separated and NUL-terminated.
func (s *Slave) doXattrList(a XattrListArgs) (XattrListResult, error) {
	p, err := s.resolvePath(a.Path)
	if err != nil {
		return XattrListResult{}, err
	}
	buf := make([]byte, 4096)
	n, err := syscall.Listxattr(p, buf)
	if err != nil {
		return XattrListResult{}, err
	}
	var names []string
	for _, part := range strings.Split(string(buf[:n]), "\x00") {
		if part != "" {
			names = append(names, part)
		}
	}
	return XattrListResult{Names: names}, nil
}

func (s *Slave) doXattrGet(a XattrGetArgs) (XattrGetResult, error) {
	p, err := s.resolvePath(a.Path)
	if err != nil {
		return XattrGetResult{}, err
	}
	buf := make([]byte, 64*1024)
	n, err := syscall.Getxattr(p, a.Name, buf)
	if err != nil {
		if errors.Is(err, syscall.ENODATA) {
			return XattrGetResult{Found: false}, nil
		}
		return XattrGetResult{}, err
	}
	return XattrGetResult{Found: true, Value: string(buf[:n])}, nil
}

// kernelDevName maps a device path to the name the KERNEL knows it by,
// which is what /proc/fs/cetrafs/<name>/ and /sys/block/<name>/ are keyed
// on. They differ whenever the path is a symlink, and on the deployment
// that matters they always are: a multipath volume is mounted as
// /dev/mapper/<wwid> but the kernel calls it dm-5, so every procfs read
// built from the mapper name failed with "no such file or directory" --
// scenarios erroring out on a perfectly healthy cluster.
//
// EvalSymlinks leaves a plain /dev/sda untouched, so this is a no-op on
// the single-path case.
func kernelDevName(dev string) string {
	if resolved, err := filepath.EvalSymlinks(dev); err == nil {
		return filepath.Base(resolved)
	}
	return filepath.Base(dev)
}

// devPath is the ONE place a device path becomes a kernel path. Every
// /proc/fs/cetrafs/<dev>/... and /sys/block/<dev>/... is built here, so
// the mapper-name-to-dm-N resolution cannot be forgotten at a call site:
//
//	devPath("/proc/fs/cetrafs", dev, "info")        -> /proc/fs/cetrafs/dm-5/info
//	devPath("/sys/block", dev, "device", "state")   -> /sys/block/dm-5/device/state
//
// It is one function rather than a helper per root because the previous
// shape -- a name resolver that each caller joined for itself -- is
// exactly how the fourth call site (procsnap.go) kept the bug alive
// after the other three were fixed.
func devPath(root, dev string, elem ...string) string {
	return filepath.Join(append([]string{root, kernelDevName(dev)}, elem...)...)
}

// sysBlock joins a /sys/block path for an already-resolved kernel NAME
// -- what a slaves/ entry is. It deliberately does NOT resolve: the
// walk below descends through names the kernel already gave us, and
// there is no /dev path to resolve for them. devPath is for the other
// direction (a /dev path that still needs resolving); keeping the two
// apart is what the mapper-name bug was about.
func sysBlock(name string, elem ...string) string {
	return filepath.Join(append([]string{"/sys/block", name}, elem...)...)
}

// doProcRaw reads the three /proc/fs/cetrafs/<device>/ files verbatim --
// no parsing, no interpretation -- so a real multi-node run can be
// troubleshot directly (e.g. confirming clustering_pr_supported, or
// spotting an info/cluster disagreement the parsed ProcSnapshot doesn't
// surface) without needing someone to manually ssh in and cat them.
func doProcRaw(a ProcRawArgs) (ProcRawResult, error) {
	base := devPath("/proc/fs/cetrafs", a.Device)

	read := func(name string) (string, error) {
		b, err := os.ReadFile(filepath.Join(base, name))
		if err != nil {
			return "", err
		}
		return string(b), nil
	}

	info, err := read("info")
	if err != nil {
		return ProcRawResult{}, fmt.Errorf("info: %w", err)
	}
	props, err := read("properties")
	if err != nil {
		return ProcRawResult{}, fmt.Errorf("properties: %w", err)
	}
	cluster, err := read("cluster")
	if err != nil {
		return ProcRawResult{}, fmt.Errorf("cluster: %w", err)
	}

	return ProcRawResult{Info: info, Properties: props, Cluster: cluster}, nil
}

// doDmesgTail returns the last Lines lines of this machine's own dmesg --
// same self-serve troubleshooting motivation as doProcRaw, for seeing a
// real race's actual kernel-side log lines (e.g. "lock: ino=... lost
// race claiming write lock", a PR conflict, or their absence) without
// needing someone to copy-paste dmesg output by hand. Shells out to the
// real `dmesg` binary rather than reading /dev/kmsg directly -- simplest
// correct thing, and this slave already shells out for mount/umount.
func doDmesgTail(a DmesgTailArgs) (DmesgTailResult, error) {
	n := a.Lines
	if n <= 0 {
		n = 100
	}

	out, err := exec.Command("dmesg").Output()
	if err != nil {
		return DmesgTailResult{}, fmt.Errorf("dmesg: %w", err)
	}

	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if a.Since != "" {
		// Only what happened after the marker dmesg_mark planted. A
		// marker that rotated out of the ring means the window is
		// unbounded at the front; returning everything is the honest
		// (and conservative) answer.
		for i := len(lines) - 1; i >= 0; i-- {
			if strings.Contains(lines[i], a.Since) {
				lines = lines[i+1:]
				break
			}
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return DmesgTailResult{Text: strings.Join(lines, "\n")}, nil
}

// doDmesgMark plants a marker in the kernel log for dmesg_tail{Since}.
func doDmesgMark(a DmesgMarkArgs) error {
	if a.Marker == "" {
		return fmt.Errorf("dmesg_mark: empty marker")
	}
	return os.WriteFile("/dev/kmsg", []byte("ctest: mark "+a.Marker+"\n"), 0)
}

// koPathCandidates: common locations for cetrafs.ko relative to wherever
// this slave process happens to be started from -- the slave doesn't
// know the repo layout the way the master's own flags do, so it just
// tries the usual spots a checkout would put kmod/cetrafs.ko.
var koPathCandidates = []string{
	"kmod/cetrafs.ko",
	"../kmod/cetrafs.ko",
	"../../kmod/cetrafs.ko",
	"/root/cetrafs/kmod/cetrafs.ko",
}

// readELFNoteBuildID parses a raw ELF note file (the format Linux
// exposes verbatim at /sys/module/<mod>/notes/<name>, one note per
// file, no section-header wrapping) and returns its descriptor bytes
// as hex -- for .note.gnu.build-id specifically, that's the build-id
// toolchains stamp onto every linked object by default, present
// whether or not this kernel's module build produces a srcversion.
// Layout: namesz/descsz/type (4 bytes each, native-endian) then name
// padded to 4 bytes then desc padded to 4 bytes (ELFCLASS64 note
// alignment is 4, not 8, despite the surrounding file being 64-bit).
func readELFNoteBuildID(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if len(data) < 12 {
		return "", fmt.Errorf("note file too short (%d bytes)", len(data))
	}
	namesz := binary.LittleEndian.Uint32(data[0:4])
	descsz := binary.LittleEndian.Uint32(data[4:8])
	nameOff := 12
	nameAligned := (int(namesz) + 3) &^ 3
	descOff := nameOff + nameAligned
	if len(data) < descOff+int(descsz) {
		return "", fmt.Errorf("note file truncated: want %d bytes, have %d", descOff+int(descsz), len(data))
	}
	return hex.EncodeToString(data[descOff : descOff+int(descsz)]), nil
}

// doModuleInfo answers "which build is actually running here right
// now" -- see ModuleInfoResult's own comment for why this exists.
// /sys/module/cetrafs/srcversion is the authoritative answer for what's
// *loaded*; the .ko file's own hash/mtime is a secondary signal for
// "built but maybe not yet reloaded".
// loadModule tries to get cetrafs loaded when it is not. modprobe
// first -- that is the installed module (DKMS), i.e. what production
// actually runs -- then insmod of a checkout's own build as a fallback
// for a dev box that never installed it. Which one won is reported back;
// the master's build-id comparison still catches nodes that ended up on
// different builds, so loading automatically cannot paper over a
// mismatch, it just saves a manual step on three machines.
func loadModule() (string, error) {
	if out, err := exec.Command("modprobe", "cetrafs").CombinedOutput(); err == nil {
		return "modprobe", nil
	} else {
		modprobeErr := strings.TrimSpace(string(out))
		for _, p := range koPathCandidates {
			if _, serr := os.Stat(p); serr != nil {
				continue
			}
			if out2, ierr := exec.Command("insmod", p).CombinedOutput(); ierr == nil {
				return "insmod " + p, nil
			} else {
				return "", fmt.Errorf("modprobe: %s; insmod %s: %s", modprobeErr, p,
					strings.TrimSpace(string(out2)))
			}
		}
		return "", fmt.Errorf("modprobe: %s (and no cetrafs.ko found in a checkout)", modprobeErr)
	}
}

func doModuleInfo() (ModuleInfoResult, error) {
	var res ModuleInfoResult

	if _, err := os.Stat("/sys/module/cetrafs"); err == nil {
		res.Loaded = true
		res.LoadedBy = "already-loaded"
	} else {
		if how, lerr := loadModule(); lerr != nil {
			res.LoadErr = lerr.Error()
		} else {
			res.LoadedBy = how
			log.Printf("module was not loaded; loaded it via %s", how)
		}
		if _, err := os.Stat("/sys/module/cetrafs"); err == nil {
			res.Loaded = true
		}
	}

	if id, err := readELFNoteBuildID("/sys/module/cetrafs/notes/.note.gnu.build-id"); err == nil {
		res.BuildID = id
	}

	for _, p := range koPathCandidates {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		sum := sha256.Sum256(data)
		res.KoPath = p
		res.KoSHA256 = hex.EncodeToString(sum[:])
		res.KoModTime = info.ModTime().Format("2006-01-02T15:04:05Z07:00")
		break
	}

	return res, nil
}

// deviceReadHelpers maps a structure name to the helper that dumps it
// and the number of arguments that keeps that helper in READ mode.
// Every one of these writes when given more, which is exactly why the
// count is checked rather than trusted.
var deviceReadHelpers = map[string]struct {
	helper string
	// prefix is supplied by the SLAVE, not the master: naming the mode
	// is how these helpers are told to WRITE, so the master never gets
	// to choose one. It names a structure and an id; nothing else.
	prefix  []string
	maxArgs int
}{
	"pending":    {"pending_poke", []string{"dump"}, 1},
	"node":       {"node_poke", nil, 1},
	"zg":         {"zg_poke", nil, 1},
	"inode-lock": {"inode_lock_poke", nil, 1},
	// The record's own fields (size/nlink/dirent_seq/generation). A
	// separate kind because the plain inode-lock dump is compared byte
	// for byte by the kernel suites.
	"inode-rec": {"inode_lock_poke", []string{"--rec"}, 1},
}

// Settings the master may change. Whitelisted by key for the same
// reason device_read is whitelisted by structure: this op exists to
// adjust how a node behaves, not to let the master write anywhere it
// likes under /proc.
var settableControls = map[string]bool{
	"hb_interval_secs": true,
	"stale_secs":       true,
	"defrag":           true,
	"auto_defrag":      true,
}

// Module parameters the master may set: test knobs only, by name, for the
// same reason set_control whitelists by key. See ModParamArgs in
// protocol.go for why each one is here.
var settableModParams = map[string]bool{
	"caw_fail_discover": true,
	"hb_interval_secs":  true,
	"stale_secs":        true,
	// The background scrub's cadence. A scenario that has to watch the
	// scrub make (or decline) a decision cannot wait out the 30-minute
	// default, and these must be set BEFORE the mount: scrub_start()
	// queues the first cycle with the interval as it reads it then, so
	// changing it afterwards leaves that first cycle half an hour away.
	"scrub":               true,
	"scrub_interval_secs": true,
	"scrub_gap_secs":      true,
}

// Run the embedded fsck against this slave's device. Refuses while this
// node has it mounted -- fsck on a live filesystem reports faults that
// are just normal in-flight state, and a scenario that believed them
// would chase ghosts.
func (s *Slave) doFsck(a FsckArgs) (FsckResult, error) {
	s.mu.Lock()
	mp := s.mountPoint
	s.mu.Unlock()
	if live, _ := isCetrafsMount(mp); live {
		return FsckResult{}, fmt.Errorf("this node still has %s mounted; unmount everywhere before fsck", mp)
	}
	bin, err := buildEmbeddedHelper("fsck")
	if err != nil {
		return FsckResult{}, fmt.Errorf("embedded fsck unavailable: %w", err)
	}
	args := []string{}
	if a.Repair {
		args = append(args, "-r")
	}
	args = append(args, s.device)
	cmd := exec.Command(bin, args...)
	out, _ := cmd.CombinedOutput()
	code := cmd.ProcessState.ExitCode()
	return FsckResult{ExitCode: code, Output: string(out), Clean: code == 0}, nil
}

func doModParam(a ModParamArgs) (ModParamResult, error) {
	if !settableModParams[a.Name] {
		return ModParamResult{}, fmt.Errorf("module parameter %q is not settable from here", a.Name)
	}
	path := filepath.Join("/sys/module/cetrafs/parameters", a.Name)
	before, err := os.ReadFile(path)
	if err != nil {
		return ModParamResult{}, fmt.Errorf("reading %s: %w", path, err)
	}
	if err := os.WriteFile(path, []byte(a.Value+"\n"), 0o200); err != nil {
		return ModParamResult{}, fmt.Errorf("setting %s=%s: %w", a.Name, a.Value, err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		return ModParamResult{}, err
	}
	log.Printf("mod_param %s=%s (was %s)", a.Name, a.Value, strings.TrimSpace(string(before)))
	return ModParamResult{Prev: strings.TrimSpace(string(before)), Value: strings.TrimSpace(string(after))}, nil
}

func (s *Slave) doSetControl(a SetControlArgs) (SetControlResult, error) {
	if !settableControls[a.Key] {
		return SetControlResult{}, fmt.Errorf("control %q is not settable from here", a.Key)
	}
	path := devPath("/proc/fs/cetrafs", s.device, "controls")
	if err := os.WriteFile(path, []byte(a.Key+"="+a.Value+"\n"), 0o200); err != nil {
		return SetControlResult{}, fmt.Errorf("setting %s=%s: %w", a.Key, a.Value, err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		return SetControlResult{}, err
	}
	log.Printf("control %s=%s", a.Key, a.Value)
	return SetControlResult{Controls: string(after)}, nil
}

// doLink takes this slave's own backing device offline, or puts it
// back, by writing /sys/block/<dev>/device/state.
//
// Per-initiator: it affects only this node's view, never the LUN or the
// peer, which is exactly the asymmetry a fence scenario needs. It fails
// I/O fast (DID_NO_CONNECT) rather than queueing it, so the heartbeat's
// renew returns an error promptly and this node goes stale on a
// predictable schedule. Reversible in one write, with no bus rescan,
// and transport-neutral -- the same thing works for FC as for iSCSI.
//
// Only works on a real SCSI device; a loop device has no state to set,
// which is why the single-node coverage uses device-mapper instead.
//
// On MULTIPATH there is no single device to offline: a dm node has no
// /sys/block/<dm>/device at all, so this used to fail outright and took
// the fence scenarios with it. Taking "this node's view of the LUN"
// away there means offlining EVERY path beneath the map -- one healthy
// path left up and the node keeps right on heartbeating, which is the
// opposite of what a fence scenario is asking for.
func scsiPathsOf(base string) []string {
	// A plain SCSI disk IS the path.
	if _, err := os.Stat(sysBlock(base, "device", "state")); err == nil {
		return []string{base}
	}
	entries, err := os.ReadDir(sysBlock(base, "slaves"))
	if err != nil {
		return nil
	}
	var paths []string
	for _, e := range entries {
		paths = append(paths, scsiPathsOf(e.Name())...)
	}
	return paths
}

func (s *Slave) doDevLink(up bool) (DevLinkResult, error) {
	base := kernelDevName(s.device)
	want := "offline"
	if up {
		want = "running"
	}

	paths := scsiPathsOf(base)
	if len(paths) == 0 {
		return DevLinkResult{}, fmt.Errorf("%s: no SCSI path to set %s (not a SCSI disk, and no slaves)", base, want)
	}

	var states []string
	for _, p := range paths {
		path := sysBlock(p, "device", "state")
		if err := os.WriteFile(path, []byte(want+"\n"), 0o200); err != nil {
			return DevLinkResult{}, fmt.Errorf("setting %s to %s: %w", path, want, err)
		}
		got, err := os.ReadFile(path)
		if err != nil {
			return DevLinkResult{}, fmt.Errorf("reading back %s: %w", path, err)
		}
		states = append(states, p+"="+strings.TrimSpace(string(got)))
	}
	state := strings.Join(states, ",")

	// Bringing the SCSI devices back is NOT the same as bringing the
	// VOLUME back. dm-multipath still has those paths marked failed, so
	// the map has nothing usable under it and every read fails -- which
	// surfaced as "can't read superblock" on every mount after a fence
	// scenario, and took every later scenario in the suite with it. The
	// filesystem was right to refuse; the device really was unreadable.
	//
	// So reinstate each path in the map, then do not return until the
	// device actually answers a read. link_up means "usable again" to
	// every caller, and it has to be true before the next mount.
	if up && len(paths) > 0 {
		for _, p := range paths {
			mm, err := os.ReadFile(sysBlock(p, "dev"))
			if err != nil {
				continue
			}
			// Harmless on a non-multipath device: dmsetup simply fails.
			_ = exec.Command("dmsetup", "message", s.device, "0",
				"reinstate_path", strings.TrimSpace(string(mm))).Run()
		}
		if err := waitDeviceReadable(s.device, 30); err != nil {
			return DevLinkResult{State: state}, fmt.Errorf("%s: paths set running but the device is still "+
				"unreadable: %w", base, err)
		}
	}

	log.Printf("link %s: %s via %d path(s): %s", map[bool]string{true: "up", false: "down"}[up], base, len(paths), state)
	return DevLinkResult{State: state}, nil
}

// waitDeviceReadable blocks until a plain read of the device succeeds,
// or secs elapse. Multipath needs a moment after a path is reinstated
// (multipathd's checker, or the map's own retry), and a mount issued
// into that window fails for a reason that has nothing to do with the
// filesystem.
func waitDeviceReadable(dev string, secs int) error {
	var last error
	for i := 0; i < secs*4; i++ {
		f, err := os.Open(dev)
		if err == nil {
			buf := make([]byte, 4096)
			_, err = f.Read(buf)
			f.Close()
			if err == nil {
				return nil
			}
		}
		last = err
		time.Sleep(250 * time.Millisecond)
	}
	return last
}

// doDeviceRead runs one of tests/helpers' dump modes against THIS
// slave's device. Read-only by construction: the helper is chosen from
// a fixed table, the argument count is capped at whatever keeps that
// helper in its read mode, and the device path is the slave's own --
// never anything the master sent.
// flushBlockDevice syncs a block device and drops its cached pages, so
// the next userspace read of it sees what is actually on the platter
// rather than what this node last read. BLKFLSBUF, which is what
// `blockdev --flushbufs` issues; done directly to avoid depending on
// that tool being installed on every node.
func flushBlockDevice(dev string) error {
	f, err := os.OpenFile(dev, os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	const BLKFLSBUF = 0x1261
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), BLKFLSBUF, 0); errno != 0 {
		return errno
	}
	return nil
}

func (s *Slave) doDeviceRead(a DeviceReadArgs) (DeviceReadResult, error) {
	spec, ok := deviceReadHelpers[a.Kind]
	if !ok {
		return DeviceReadResult{}, fmt.Errorf("unknown device_read kind %q", a.Kind)
	}
	if len(a.Args) > spec.maxArgs {
		return DeviceReadResult{}, fmt.Errorf("device_read %q takes at most %d argument(s); %d would put %s into a "+
			"WRITE mode and this op is read-only", a.Kind, spec.maxArgs, len(a.Args), spec.helper)
	}
	for _, arg := range a.Args {
		for _, c := range arg {
			if c < '0' || c > '9' {
				return DeviceReadResult{}, fmt.Errorf("device_read argument %q is not a plain number", arg)
			}
		}
	}

	// Drop the kernel's cached copy of the block device FIRST.
	//
	// These helpers read /dev/<disk> with ordinary preads, which go
	// through the block device's own page cache -- a cache that knows
	// nothing about a peer's compare-and-swap going straight to the
	// platter. Without this the read returns whatever this node last
	// happened to fetch, which is exactly how the fence-reclaim
	// scenario reported a fence epoch of 0 on a row a peer had just
	// bumped: the kernel had seen the new value (the fenced node
	// detected it and fenced itself), while userspace here was handed a
	// stale page. Same trap the loop suites document as "flush the loop
	// device after poking the backing file", met on a real LUN.
	if err := flushBlockDevice(s.device); err != nil {
		return DeviceReadResult{}, fmt.Errorf("flushing %s before reading it: %w", s.device, err)
	}

	bin, err := s.helperPath(spec.helper)
	if err != nil {
		return DeviceReadResult{}, err
	}
	args := append([]string{s.device}, spec.prefix...)
	args = append(args, a.Args...)
	cmd := exec.Command(bin, args...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return DeviceReadResult{}, fmt.Errorf("%s: %w: %s", spec.helper, err, strings.TrimSpace(errb.String()))
	}
	return DeviceReadResult{Output: out.String()}, nil
}

// helperPath builds tests/helpers/<name>.c the same way the shell
// harness does, next to this checkout, caching the binary.
// repoRoot finds a cetrafs checkout: the helpers are compiled from
// SOURCE, so a tree really has to be present.
//
// It is resolved independently rather than inferred from mkfsPath --
// that inference broke the moment mkfs.cetra could come from the
// installed package (/usr/sbin/mkfs.cetra made the root "/usr", and
// fence-reclaim died on /usr/tests/helpers/node_poke.c). A candidate
// counts only if it actually holds tests/helpers AND the format header,
// so a wrong guess is rejected here instead of surfacing later as a
// confusing stat error.
func (s *Slave) repoRoot() string {
	var cands []string
	if s.mkfsPath != "" {
		cands = append(cands, filepath.Dir(filepath.Dir(s.mkfsPath)))
	}
	if exe, err := os.Executable(); err == nil {
		cands = append(cands, filepath.Dir(filepath.Dir(exe))) // <root>/ctest/ctest
	}
	if wd, err := os.Getwd(); err == nil {
		cands = append(cands, wd, filepath.Dir(wd))
	}
	cands = append(cands, "/root/cetrafs", "/root/cetrafs-core")

	for _, c := range cands {
		if c == "" || c == "/" {
			continue
		}
		if _, err := os.Stat(filepath.Join(c, "tests", "helpers")); err != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(c, "include", "cetrafs.h")); err != nil {
			continue
		}
		return c
	}
	return ""
}

// helperCacheDir holds helpers provisioned by the master (put_helper)
// on a node with no checkout of its own.
func helperCacheDir() string { return filepath.Join(os.TempDir(), "ctest-helpers") }

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func (s *Slave) helperPath(name string) (string, error) {
	root := s.repoRoot()
	if root == "" {
		// No checkout on this node: build from the sources embedded in
		// this binary (embed.go). Nothing but a C compiler is needed.
		return buildEmbeddedHelper(name)
	}
	src := filepath.Join(root, "tests", "helpers", name+".c")
	if _, err := os.Stat(src); err != nil {
		return "", fmt.Errorf("helper source %s: %w", src, err)
	}
	buildDir := filepath.Join(root, "tests", ".build")
	if err := os.MkdirAll(buildDir, 0o755); err != nil {
		return "", err
	}
	bin := filepath.Join(buildDir, name)
	si, errS := os.Stat(src)
	bi, errB := os.Stat(bin)
	// Rebuild when the SOURCE or the on-disk-format header is newer than
	// the cached binary -- the shell harness's ct_helper checks
	// include/cetrafs.h for exactly this reason: a helper's own .c can be
	// unchanged while a format change (e.g. a struct field removed,
	// shifting every later field's offset) silently invalidates it, and a
	// stale poke then reads the wrong offset (seen as node_poke's
	// "pread: Success" after the v3 field removal moved node_table_start).
	hdr := filepath.Join(root, "include", "cetrafs.h")
	hi, errH := os.Stat(hdr)
	stale := errB != nil ||
		(errS == nil && si.ModTime().After(bi.ModTime())) ||
		(errH == nil && errB == nil && hi.ModTime().After(bi.ModTime()))
	if stale {
		cc := exec.Command("cc", "-D_FILE_OFFSET_BITS=64",
			"-I", filepath.Join(root, "include"), "-I", filepath.Join(root, "userspace"),
			"-O2", "-std=gnu99", "-o", bin, src)
		var e bytes.Buffer
		cc.Stderr = &e
		if err := cc.Run(); err != nil {
			return "", fmt.Errorf("building %s: %w: %s", name, err, strings.TrimSpace(e.String()))
		}
	}
	return bin, nil
}
