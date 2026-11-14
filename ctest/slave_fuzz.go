package main

// The slave half of the namespace fuzzer's content oracle (scenario_nsfuzz.go):
// block writes that say whose they are, and a reader that judges every block.
//
// Every block a fuzz write puts down is the unit "F<fid>.<node>@<offset>;"
// repeated (blockStamp), where <fid> is the file's identity -- a random id
// kept in its user.fid xattr, set once with XATTR_CREATE -- and <offset> the
// block's byte offset in the file. Inode numbers are reused and so cannot
// name a file; the fid can. A block is then provably one of: zeros (a hole,
// a punch, a preallocation, a truncate-and-extend), or this file's own block
// at this offset, whole. Anything else -- another file's block, a block at
// the wrong offset, a torn mix -- is damage, whoever wrote it.

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

const fuzzFidXattr = "user.fid"

type FuzzWriteArgs struct {
	Path   string `json:"path,omitempty"`
	Handle uint64 `json:"handle,omitempty"` // write through a held fd instead of opening Path
	Block  int64  `json:"block"`
	Count  int    `json:"count"`
	Direct bool   `json:"direct,omitempty"`
	Create bool   `json:"create,omitempty"`
	Node   string `json:"node"`
	// Instrument controls only (the scenario's self-test): stamp with this
	// fid instead of the file's, or with an offset this many blocks off.
	PlantFid  string `json:"plant_fid,omitempty"`
	PlantSkew int64  `json:"plant_skew,omitempty"`
}

type FuzzWriteResult struct {
	Fid string `json:"fid"`
}

// FuzzReadArgs: read [Block, Block+Count) through a fresh open of Path or
// a held fd, and judge it on the spot (fuzzJudgeLive).
type FuzzReadArgs struct {
	Path   string `json:"path,omitempty"`
	Handle uint64 `json:"handle,omitempty"`
	Block  int64  `json:"block"`
	Count  int    `json:"count"`
}

type FuzzReadResult struct {
	Bad []string `json:"bad,omitempty"`
}

type FuzzVerifyArgs struct {
	Dir string `json:"dir"`
}

// FuzzFileView is one directory entry as this node sees it.
type FuzzFileView struct {
	Name   string `json:"name"`
	Kind   string `json:"kind"` // file | dir | symlink | other
	Ino    uint64 `json:"ino"`
	Size   int64  `json:"size"`
	Nlink  uint64 `json:"nlink"`
	Fid    string `json:"fid,omitempty"`
	Hash   string `json:"hash,omitempty"`   // content
	Xattrs string `json:"xattrs,omitempty"` // names and values
	Target string `json:"target,omitempty"`
	Data   int    `json:"data"` // stamped blocks
	// Extents: FIEMAP's mapped-extent count (-1 when it failed). Past the
	// record's four inline slots the map lives in leaf blocks.
	Extents int      `json:"extents"`
	Bad     []string `json:"bad,omitempty"`
}

type FuzzVerifyResult struct {
	Files []FuzzFileView `json:"files"`
}

func fgetxattr(fd uintptr, name string) ([]byte, error) {
	n, err := syscall.BytePtrFromString(name)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, 256)
	r, _, e := syscall.Syscall6(syscall.SYS_FGETXATTR, fd, uintptr(unsafe.Pointer(n)),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0)
	if e != 0 {
		return nil, e
	}
	return buf[:r], nil
}

func fsetxattrCreate(fd uintptr, name string, val []byte) error {
	n, err := syscall.BytePtrFromString(name)
	if err != nil {
		return err
	}
	const xattrCreate = 1
	_, _, e := syscall.Syscall6(syscall.SYS_FSETXATTR, fd, uintptr(unsafe.Pointer(n)),
		uintptr(unsafe.Pointer(&val[0])), uintptr(len(val)), xattrCreate, 0)
	if e != 0 {
		return e
	}
	return nil
}

// fuzzFid returns the file's identity, giving it one if it has none. Two
// nodes racing to name one file: XATTR_CREATE lets exactly one win, and
// the loser reads the winner's.
func fuzzFid(f *os.File) (string, error) {
	if v, err := fgetxattr(f.Fd(), fuzzFidXattr); err == nil {
		return string(v), nil
	} else if !errors.Is(err, syscall.ENODATA) {
		return "", fmt.Errorf("fgetxattr %s: %w", fuzzFidXattr, err)
	}
	var r [6]byte
	if _, err := rand.Read(r[:]); err != nil {
		return "", err
	}
	id := hex.EncodeToString(r[:])
	if err := fsetxattrCreate(f.Fd(), fuzzFidXattr, []byte(id)); err != nil {
		if errors.Is(err, syscall.EEXIST) {
			if v, err := fgetxattr(f.Fd(), fuzzFidXattr); err == nil {
				return string(v), nil
			} else {
				return "", fmt.Errorf("fgetxattr %s after losing its create: %w", fuzzFidXattr, err)
			}
		}
		return "", fmt.Errorf("fsetxattr %s: %w", fuzzFidXattr, err)
	}
	return id, nil
}

func fuzzStamp(fid, node string) string { return "F" + fid + "." + node }

func (s *Slave) doFuzzWrite(a FuzzWriteArgs) (FuzzWriteResult, error) {
	if a.Count < 1 || a.Block < 0 {
		return FuzzWriteResult{}, fmt.Errorf("fuzz_write: block %d count %d", a.Block, a.Count)
	}
	var f *os.File
	if a.Handle != 0 {
		v, ok := s.handles.Load(a.Handle)
		if !ok {
			return FuzzWriteResult{}, fmt.Errorf("no such handle %d", a.Handle)
		}
		f = v.(*os.File)
	} else {
		path, err := s.resolvePath(a.Path)
		if err != nil {
			return FuzzWriteResult{}, err
		}
		flags := os.O_WRONLY
		if a.Direct {
			flags |= syscall.O_DIRECT
		}
		if a.Create {
			flags |= os.O_CREATE
		}
		f, err = os.OpenFile(path, flags, 0644)
		if err != nil {
			return FuzzWriteResult{}, err
		}
		defer f.Close()
	}
	fid, err := fuzzFid(f)
	if err != nil {
		return FuzzWriteResult{}, err
	}
	stampFid := fid
	if a.PlantFid != "" {
		stampFid = a.PlantFid
	}
	buf := alignedBuf(dioBlock * a.Count)
	for i := 0; i < a.Count; i++ {
		off := (a.Block + int64(i)) * dioBlock
		blockStamp(buf[i*dioBlock:(i+1)*dioBlock], fuzzStamp(stampFid, a.Node), off+a.PlantSkew*dioBlock)
	}
	if _, err := f.WriteAt(buf, a.Block*dioBlock); err != nil {
		return FuzzWriteResult{}, err
	}
	if err := f.Sync(); err != nil {
		return FuzzWriteResult{}, fmt.Errorf("fsync: %w", err)
	}
	return FuzzWriteResult{Fid: fid}, nil
}

// fuzzJudgeBlock says what is wrong with one block of a file whose fid is
// fid, at byte offset off -- "" when it is zeros or the file's own block.
func fuzzJudgeBlock(b []byte, fid string, off int64) string {
	if len(bytes.Trim(b, "\x00")) == 0 {
		return ""
	}
	if b[0] != 'F' {
		return fmt.Sprintf("block @%d: not a fuzz stamp (%q...)", off, b[:min(16, len(b))])
	}
	end := bytes.IndexByte(b[:min(128, len(b))], ';')
	at := bytes.IndexByte(b[:max(end, 0)], '@')
	if end < 0 || at < 0 {
		return fmt.Sprintf("block @%d: unparseable stamp (%q...)", off, b[:min(32, len(b))])
	}
	stamp := string(b[:at])
	soff, err := strconv.ParseInt(string(b[at+1:end]), 16, 64)
	if err != nil {
		return fmt.Sprintf("block @%d: unparseable offset in %q", off, b[:end+1])
	}
	want := make([]byte, len(b))
	blockStamp(want, stamp, soff)
	if !bytes.Equal(want, b) {
		return fmt.Sprintf("block @%d: torn (starts as %q, does not repeat it)", off, b[:end+1])
	}
	dot := strings.IndexByte(stamp, '.')
	if dot < 0 {
		return fmt.Sprintf("block @%d: stamp %q names no node", off, stamp)
	}
	if bfid := stamp[1:dot]; bfid != fid {
		return fmt.Sprintf("block @%d: another file's block (fid %s, this file's %q)", off, bfid, fid)
	}
	if soff != off {
		return fmt.Sprintf("block @%d: this file's block from offset %d", off, soff)
	}
	return ""
}

var fuzzUnitRE = regexp.MustCompile(`F([0-9a-f]+)\.[^@;]*@([0-9a-f]{12});`)

// fuzzJudgeLive judges a block read while writers may still be at it. A
// read racing a write of the same block can see it torn between two of
// THIS file's stamps for THIS offset (a device write is atomic per
// sector, not per block), so torn is not damage here. What a stale map
// produces is: a complete unit naming another file, or this file's block
// from another offset -- and that is what this refuses.
func fuzzJudgeLive(b []byte, fid string, off int64) string {
	for _, m := range fuzzUnitRE.FindAllSubmatch(b, -1) {
		if string(m[1]) != fid {
			return fmt.Sprintf("block @%d: another file's block (fid %s, this file's %q)", off, m[1], fid)
		}
		if soff, err := strconv.ParseInt(string(m[2]), 16, 64); err == nil && soff != off {
			return fmt.Sprintf("block @%d: this file's block from offset %d", off, soff)
		}
	}
	return ""
}

func (s *Slave) doFuzzRead(a FuzzReadArgs) (FuzzReadResult, error) {
	var f *os.File
	if a.Handle != 0 {
		v, ok := s.handles.Load(a.Handle)
		if !ok {
			return FuzzReadResult{}, fmt.Errorf("no such handle %d", a.Handle)
		}
		f = v.(*os.File)
	} else {
		path, err := s.resolvePath(a.Path)
		if err != nil {
			return FuzzReadResult{}, err
		}
		f, err = os.Open(path)
		if err != nil {
			return FuzzReadResult{}, err
		}
		defer f.Close()
	}
	// The fid first: a file without one has never been fuzz-written, and
	// any stamp in it is another file's.
	fid := ""
	if v, err := fgetxattr(f.Fd(), fuzzFidXattr); err == nil {
		fid = string(v)
	} else if !errors.Is(err, syscall.ENODATA) {
		return FuzzReadResult{}, fmt.Errorf("fgetxattr %s: %w", fuzzFidXattr, err)
	}
	buf := make([]byte, int64(a.Count)*dioBlock)
	n, err := f.ReadAt(buf, a.Block*dioBlock)
	if err != nil && n == 0 && !errors.Is(err, io.EOF) {
		return FuzzReadResult{}, err
	}
	var res FuzzReadResult
	for i := 0; i+dioBlock <= n; i += dioBlock {
		if why := fuzzJudgeLive(buf[i:i+dioBlock], fid, a.Block*dioBlock+int64(i)); why != "" {
			res.Bad = append(res.Bad, why)
		}
	}
	return res, nil
}

func xattrDigest(path string) (string, error) {
	sz, err := syscall.Listxattr(path, nil)
	if err != nil {
		return "", err
	}
	names := []string{}
	if sz > 0 {
		buf := make([]byte, sz)
		n, err := syscall.Listxattr(path, buf)
		if err != nil {
			return "", err
		}
		for _, nm := range strings.Split(string(buf[:n]), "\x00") {
			if nm != "" {
				names = append(names, nm)
			}
		}
	}
	sort.Strings(names)
	h := sha256.New()
	for _, nm := range names {
		v := make([]byte, 65536)
		n, err := syscall.Getxattr(path, nm, v)
		if err != nil {
			return "", fmt.Errorf("getxattr %s: %w", nm, err)
		}
		fmt.Fprintf(h, "%s=%x\n", nm, v[:n])
	}
	return hex.EncodeToString(h.Sum(nil))[:16], nil
}

func (s *Slave) doFuzzVerify(a FuzzVerifyArgs) (FuzzVerifyResult, error) {
	dir, err := s.resolvePath(a.Dir)
	if err != nil {
		return FuzzVerifyResult{}, err
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return FuzzVerifyResult{}, err
	}
	var res FuzzVerifyResult
	for _, e := range ents {
		p := filepath.Join(dir, e.Name())
		v := FuzzFileView{Name: e.Name()}
		var st syscall.Stat_t
		if err := syscall.Lstat(p, &st); err != nil {
			v.Kind = "gone"
			v.Bad = append(v.Bad, fmt.Sprintf("listed but lstat fails: %v", err))
			res.Files = append(res.Files, v)
			continue
		}
		v.Ino, v.Size, v.Nlink = st.Ino, st.Size, uint64(st.Nlink)
		switch st.Mode & syscall.S_IFMT {
		case syscall.S_IFDIR:
			v.Kind = "dir"
			v.Size = 0 // a directory's size is its block count: allowed to differ by caching
		case syscall.S_IFLNK:
			v.Kind = "symlink"
			v.Target, _ = os.Readlink(p)
		case syscall.S_IFREG:
			v.Kind = "file"
			fuzzVerifyFile(p, &v)
		default:
			v.Kind = "other"
		}
		res.Files = append(res.Files, v)
	}
	return res, nil
}

func fuzzVerifyFile(p string, v *FuzzFileView) {
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		v.Bad = append(v.Bad, fmt.Sprintf("open: %v", err))
		return
	}
	defer f.Close()
	if fid, err := fgetxattr(f.Fd(), fuzzFidXattr); err == nil {
		v.Fid = string(fid)
	} else if !errors.Is(err, syscall.ENODATA) {
		v.Bad = append(v.Bad, fmt.Sprintf("fgetxattr fid: %v", err))
	}
	if x, err := xattrDigest(p); err == nil {
		v.Xattrs = x
	} else {
		v.Bad = append(v.Bad, fmt.Sprintf("xattrs: %v", err))
	}
	v.Extents = fiemapCount(f)
	data := make([]byte, v.Size)
	if n, err := f.ReadAt(data, 0); int64(n) != v.Size {
		v.Bad = append(v.Bad, fmt.Sprintf("read %d of %d bytes: %v", n, v.Size, err))
		return
	}
	sum := sha256.Sum256(data)
	v.Hash = hex.EncodeToString(sum[:])[:16]
	for off := int64(0); off < v.Size; off += dioBlock {
		b := data[off:min(off+dioBlock, v.Size)]
		if len(b) < dioBlock {
			// A partial tail: every fuzz size is whole blocks, so it must be zeros.
			if len(bytes.Trim(b, "\x00")) != 0 {
				v.Bad = append(v.Bad, fmt.Sprintf("partial tail @%d holds data", off))
			}
			continue
		}
		if len(bytes.Trim(b, "\x00")) != 0 {
			v.Data++
		}
		if why := fuzzJudgeBlock(b, v.Fid, off); why != "" {
			v.Bad = append(v.Bad, why)
		}
	}
	if v.Data > 0 && v.Fid == "" {
		v.Bad = append(v.Bad, fmt.Sprintf("%d stamped block(s) but no %s", v.Data, fuzzFidXattr))
	}
}

// fiemapCount asks FS_IOC_FIEMAP for the number of mapped extents only
// (fm_extent_count = 0). -1 when the ioctl fails.
func fiemapCount(f *os.File) int {
	// struct fiemap: fm_start, fm_length u64; fm_flags, fm_mapped_extents,
	// fm_extent_count, fm_reserved u32.
	var fm struct {
		start, length                  uint64
		flags, mapped, count, reserved uint32
	}
	fm.length = ^uint64(0)
	fm.flags = 1 // FIEMAP_FLAG_SYNC
	const fsIocFiemap = 0xC020660B
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), fsIocFiemap, uintptr(unsafe.Pointer(&fm))); e != 0 {
		return -1
	}
	return int(fm.mapped)
}
