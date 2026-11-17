package main

// Direct I/O operations for the direct-write scenario: O_DIRECT block
// writes (foreground or in the background), fallocate, and a reader that
// classifies every block of a file.

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const dioBlock = 4096

type dioJob struct {
	done chan struct{}
	res  DioWriteResult
}

// alignedBuf returns n bytes aligned to dioBlock, as O_DIRECT requires of
// the user buffer.
func alignedBuf(n int) []byte {
	b := make([]byte, n+dioBlock)
	off := 0
	if r := int(uintptr(unsafe.Pointer(&b[0])) & (dioBlock - 1)); r != 0 {
		off = dioBlock - r
	}
	return b[off : off+n]
}

// blockStamp fills dst with the content a writer stamped stamp puts at
// offset off: the pair repeated, so a block at the wrong offset, a torn
// block or another writer's block never compares equal.
func blockStamp(dst []byte, stamp string, off int64) {
	unit := []byte(fmt.Sprintf("%s@%012x;", stamp, off))
	for i := 0; i < len(dst); i++ {
		dst[i] = unit[i%len(unit)]
	}
}

func dioOffsets(a DioWriteArgs) ([]int64, error) {
	if len(a.Offsets) > 0 {
		return a.Offsets, nil
	}
	if a.Count <= 0 || a.Hi <= a.Lo {
		return nil, fmt.Errorf("dio_write: give offsets, or count with lo < hi")
	}
	n := (a.Hi - a.Lo) / dioBlock
	rnd := rand.New(rand.NewSource(a.Seed))
	out := make([]int64, a.Count)
	for i := range out {
		out[i] = a.Lo + rnd.Int63n(n)*dioBlock
	}
	return out, nil
}

func (s *Slave) doFallocate(a FallocateArgs) error {
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	ferr := syscall.Fallocate(int(f.Fd()), a.Mode, a.Offset, a.Length)
	cerr := f.Close()
	if ferr != nil {
		return fmt.Errorf("fallocate: %w", ferr)
	}
	return cerr
}

// doChurn runs churn_io; a nonzero exit is a result (the oracle's
// verdict), not an error.
func (s *Slave) doChurn(a ChurnArgs) (ChurnResult, error) {
	if a.Mode != "churn" && a.Mode != "verify" {
		return ChurnResult{}, fmt.Errorf("churn mode %q", a.Mode)
	}
	root, err := s.resolvePath(a.Dir)
	if err != nil {
		return ChurnResult{}, err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return ChurnResult{}, err
	}
	// Per test directory: actor ids repeat across runs, and a state left
	// by an earlier run describes files that no longer exist.
	state := filepath.Join(os.TempDir(), "ctest-churn-state", strings.ReplaceAll(a.Dir, "/", "_"))
	if err := os.MkdirAll(state, 0o755); err != nil {
		return ChurnResult{}, err
	}
	bin, err := s.helperPath("churn_io")
	if err != nil {
		return ChurnResult{}, err
	}
	args := []string{a.Mode, root, state}
	if a.Mode == "churn" {
		args = append(args, fmt.Sprint(a.Seed), fmt.Sprint(a.Actor), fmt.Sprint(a.Secs), fmt.Sprint(a.Files),
			fmt.Sprint(a.MaxBlk))
	} else {
		args = append(args, fmt.Sprint(a.Actor))
	}
	cmd := exec.Command(bin, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err = cmd.Run()
	res := ChurnResult{}
	if ee, ok := err.(*exec.ExitError); ok {
		res.ExitCode = ee.ExitCode()
	} else if err != nil {
		return ChurnResult{}, err
	}
	o := out.String()
	if len(o) > 8192 {
		o = o[len(o)-8192:]
	}
	res.Output = o
	return res, nil
}

// doFstrim issues FITRIM on the mountpoint over the whole volume.
func (s *Slave) doFstrim() (FstrimResult, error) {
	mp, err := s.resolvePath(".") // the mountpoint itself: "" is not a local path to filepath.IsLocal
	if err != nil {
		return FstrimResult{}, err
	}
	f, err := os.Open(mp)
	if err != nil {
		return FstrimResult{}, err
	}
	defer f.Close()
	r := struct{ start, length, minlen uint64 }{0, ^uint64(0), 0}
	const fitrim = 0xC0185879 // _IOWR('X', 121, struct fstrim_range)
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), fitrim, uintptr(unsafe.Pointer(&r))); e != 0 {
		return FstrimResult{}, fmt.Errorf("FITRIM: %w", e)
	}
	return FstrimResult{Bytes: r.length}, nil
}

func (s *Slave) doDioWrite(a DioWriteArgs) (DioWriteResult, error) {
	offs, err := dioOffsets(a)
	if err != nil {
		return DioWriteResult{}, err
	}
	for _, o := range offs {
		if o%dioBlock != 0 || o < 0 {
			return DioWriteResult{}, fmt.Errorf("dio_write: offset %d is not block aligned", o)
		}
	}
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return DioWriteResult{}, err
	}
	flags := os.O_WRONLY | syscall.O_DIRECT
	if a.Create {
		flags |= os.O_CREATE
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return DioWriteResult{}, fmt.Errorf("mkdir parent: %w", err)
		}
	}
	f, err := os.OpenFile(path, flags, 0644)
	if err != nil {
		return DioWriteResult{}, err
	}
	par := a.Par
	if par < 1 {
		par = 1
	}

	run := func() DioWriteResult {
		var mu sync.Mutex
		var res DioWriteResult
		ch := make(chan int64)
		var wg sync.WaitGroup
		for w := 0; w < par; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				buf := alignedBuf(dioBlock)
				for o := range ch {
					blockStamp(buf, a.Stamp, o)
					_, werr := f.WriteAt(buf, o)
					mu.Lock()
					if werr != nil {
						res.Failed++
						if res.FirstError == "" {
							res.FirstError = fmt.Sprintf("offset %d: %v", o, werr)
						}
					} else {
						res.Written++
					}
					mu.Unlock()
				}
			}()
		}
		for _, o := range offs {
			ch <- o
		}
		close(ch)
		wg.Wait()
		if a.Fsync && res.Failed == 0 {
			if serr := f.Sync(); serr != nil {
				res.Failed++
				res.FirstError = fmt.Sprintf("fsync: %v", serr)
			}
		}
		if cerr := f.Close(); cerr != nil && res.FirstError == "" {
			res.FirstError = fmt.Sprintf("close: %v", cerr)
			res.Failed++
		}
		res.Done = true
		return res
	}

	if !a.Background {
		return run(), nil
	}
	j := &dioJob{done: make(chan struct{})}
	id := s.jobSeq.Add(1)
	s.jobs.Store(id, j)
	go func() {
		j.res = run()
		j.res.Job = id
		close(j.done)
	}()
	return DioWriteResult{Job: id}, nil
}

func (s *Slave) doDioWait(a DioWaitArgs) (DioWriteResult, error) {
	v, ok := s.jobs.Load(a.Job)
	if !ok {
		return DioWriteResult{}, fmt.Errorf("no such dio job %d", a.Job)
	}
	j := v.(*dioJob)
	select {
	case <-j.done:
		s.jobs.Delete(a.Job)
		return j.res, nil
	case <-time.After(time.Duration(a.TimeoutSecs) * time.Second):
		return DioWriteResult{Job: a.Job, Done: false}, nil
	}
}

func (s *Slave) doVerifyBlocks(a VerifyBlocksArgs) (VerifyBlocksResult, error) {
	res := VerifyBlocksResult{Valid: map[string]int{}}
	path, err := s.resolvePath(a.Path)
	if err != nil {
		return res, err
	}
	flags := os.O_RDONLY
	if a.Direct {
		flags |= syscall.O_DIRECT
	}
	f, err := os.OpenFile(path, flags, 0)
	if err != nil {
		return res, err
	}
	defer f.Close()

	must := map[int64]string{}
	for _, m := range a.Must {
		for _, o := range m.Offsets {
			must[o] = m.Stamp
		}
	}
	detail := func(format string, args ...any) {
		if len(res.Details) < 8 {
			res.Details = append(res.Details, fmt.Sprintf(format, args...))
		}
	}

	const chunk = 1 << 20
	buf := alignedBuf(chunk)
	want := make([]byte, dioBlock)
	zero := make([]byte, dioBlock)
	forbidden := []byte(a.Forbidden)
	for base := int64(0); base < a.Size; base += chunk {
		n := chunk
		if a.Size-base < chunk {
			n = int(a.Size - base)
		}
		got, rerr := f.ReadAt(buf[:n], base)
		if got != n {
			return res, fmt.Errorf("read at %d: got %d of %d bytes: %v", base, got, n, rerr)
		}
		for i := 0; i+dioBlock <= n; i += dioBlock {
			off := base + int64(i)
			blk := buf[i : i+dioBlock]
			res.Blocks++
			kind := ""
			switch {
			case bytes.Equal(blk, zero):
				res.Zero++
				kind = "zero"
			case len(forbidden) > 0 && bytes.Contains(blk, forbidden):
				res.Forbidden++
				kind = "forbidden"
				detail("block at %d holds %q: data of a deleted file", off, a.Forbidden)
			default:
				for _, st := range a.Stamps {
					blockStamp(want, st, off)
					if bytes.Equal(blk, want) {
						res.Valid[st]++
						kind = st
						break
					}
				}
				if kind == "" {
					res.Garbage++
					kind = "garbage"
					detail("block at %d is neither zeros nor a valid block: %q...", off, blk[:32])
				}
			}
			if st, ok := must[off]; ok && kind != st {
				res.Missing++
				detail("block at %d should be %s's, reads as %s", off, st, kind)
			}
		}
	}
	return res, nil
}

// CETRAFS_IOC_DEFRAG: _IOR('C', 0x01, struct cetrafs_defrag_stats), three
// u64s (include/cetrafs.h).
const cetrafsIocDefrag = 2<<30 | 24<<16 | 'C'<<8 | 0x01

func doDefragFile(path string) (DefragFileResult, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return DefragFileResult{}, err
	}
	defer f.Close()
	var st [3]uint64
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(cetrafsIocDefrag),
		uintptr(unsafe.Pointer(&st[0]))); e != 0 {
		return DefragFileResult{}, fmt.Errorf("defrag ioctl: %w", e)
	}
	return DefragFileResult{ExtentsBefore: st[0], ExtentsAfter: st[1], BlocksMoved: st[2]}, nil
}
