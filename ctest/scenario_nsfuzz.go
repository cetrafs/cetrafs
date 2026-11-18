package main

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// RunNsFuzz is the seeded, invariant-checking generalization of
// RunConcurrentMkdirStorm: the cross-node fuzzer that guards the bug class
// 0.7 shipped a fix for (a stale directory extent-leaf read letting two
// nodes diverge on a directory, so two mkdir()s of one name both "won",
// children were orphaned, and entries went INVISIBLE) -- and, since it
// gained file operations, everything a file can go through while a peer
// works on the same names.
//
// From a fixed seed each node fires a long random stream of operations
// against a SHARED, small name pool in ONE arena directory. A small pool in
// one directory is deliberate: it maximises same-name collisions and
// extent-tree churn. The vocabulary (nsFuzzAllOps): the namespace
// (create/mkdir/unlink/rmdir/rename/symlink/link/chmod/truncate), data
// (buffered, O_DIRECT and held-fd block writes), xattrs, fallocate
// (allocate, punch, zero-range), defrag, and open-and-hold: an fd a node
// keeps across its next operations, so names are unlinked, renamed over and
// truncated under a live opener, and flock(2) is taken and dropped on it.
//
// The oracles, once the storm quiesces:
//
//  0. Errors: every result is judged. A lost race fails with one of the
//     errnos nsFuzzLegal allows for that op; anything else -- EIO,
//     EUCLEAN, ESTALE, an errno-less failure -- fails the run.
//  1. Agreement: every node lists the arena identically, and sees every
//     entry identically -- kind, inode, size, nlink, content, xattrs,
//     symlink target.
//  2. Content: every block of every file is zeros or the file's own block
//     at that offset (slave_fuzz.go: the stamp names the file by a fid that
//     survives rename and link, and inode-number reuse cannot fake).
//  3. fsck, strict.
//  4. No node detected a double free.
//
// Before the storm a self-test plants what oracles 0 and 2 exist to catch
// (a block with another file's fid, one at the wrong offset, an errno no op
// allows) and requires each to be caught: a fuzzer whose checks cannot fail
// is worse than none.
//
// Runs nofilelock by default (the VM-image / live-migration mode, where
// peers really do share files); -nsfuzz-filelock runs the default mount.
// Reproducible from its seed; a larger -nsfuzz-ops (or -repeat) is a soak.

// nsFuzzAllOps is the full operation vocabulary; opset (a comma list) can
// restrict it, which is how a failing run is triaged down to the culprit
// op(s) -- e.g. opset="create,link" to isolate hardlink nlink accounting.
var nsFuzzAllOps = []string{
	"create", "mkdir", "unlink", "rmdir", "rename", "symlink", "link", "chmod", "truncate",
	"write", "dwrite", "fill", "read", "hread", "xset", "xrm", "falloc", "punch", "zero", "defrag",
	"hold", "release", "hwrite", "flock", "funlock",
}

// nsFuzzLegal: the errnos an op may legally lose a race with. Every pool
// name can be absent, a file, a directory or a symlink (to a name that may
// itself be any of those, or a loop), so the namespace errnos are legal
// everywhere; the rest are each op's own. Anything outside fails the run --
// add to it only with the reason the kernel returns it.
var nsFuzzNsErrnos = []syscall.Errno{syscall.ENOENT, syscall.EEXIST, syscall.ENOTEMPTY, syscall.EISDIR,
	syscall.ENOTDIR, syscall.ELOOP}

var nsFuzzLegal = map[string][]syscall.Errno{
	"link": {syscall.EPERM}, // a hard link to a directory
	"xrm":  {syscall.ENODATA},
	// Defrag declines a file in use (cetrafs_lock_defrag_begin()), one it
	// cannot move as one run (interior holes, preallocated blocks, more
	// extents than its list holds), and -- under nofilelock, always -- a
	// file it has no lock to pin (lock.c: EOPNOTSUPP).
	"defrag": {syscall.EBUSY, syscall.EOPNOTSUPP},
	// With a peer in the file the extent map is not rewritten under it:
	// a preallocation is refused (B-11), and so is a zero-range that must
	// grow the file or a punch where the peer holds the file's lock or
	// the device cannot zero in place -- EOPNOTSUPP, which qemu takes as
	// "write the zeros yourself" (file.c, cetrafs_fallocate()).
	"falloc": {syscall.EOPNOTSUPP},
	"zero":   {syscall.EOPNOTSUPP},
	"punch":  {syscall.EOPNOTSUPP},
	// LOCK_NB, contended; and on the default mount, taking back a lock
	// this fd gave up (LOCK_UN suspends it) on a file unlinked meanwhile:
	// the resume refuses a record with nlink 0 (inode.c, the apply's
	// identity checks), since it cannot tell whether a peer reclaimed it.
	"flock": {syscall.EWOULDBLOCK, syscall.ESTALE},
}

// nsFuzzTouchesFile: ops refused ETXTBSY while a PEER holds the file's
// lock (flock under nofilelock, the automatic lock otherwise) or has it
// open: opens for write (lock.c), the record writers -- chmod, xattrs,
// link, truncate and fallocate (the setattr/xattr guards) -- and the
// namespace changes that would drop a name an opener's record dirt still
// counts (dir.c: unlink, rename-replace). "rmdir" is os.Remove, which
// unlinks a file. A write's ETXTBSY can be its fid's fsetxattr.
var nsFuzzTouchesFile = map[string]bool{
	"create": true, "write": true, "dwrite": true, "fill": true, "hwrite": true, "hold": true,
	"unlink": true, "rmdir": true, "rename": true, "link": true, "chmod": true, "truncate": true,
	"xset": true, "xrm": true, "falloc": true, "punch": true, "zero": true, "defrag": true,
	"read": true, // a read-open of a file a peer holds the lock of (default mount)
}

func nsFuzzErrnoOK(op string, errno int) bool {
	if errno == 0 {
		return false
	}
	for _, e := range nsFuzzNsErrnos {
		if int(e) == errno {
			return true
		}
	}
	if nsFuzzTouchesFile[op] && errno == int(syscall.ETXTBSY) {
		return true
	}
	for _, e := range nsFuzzLegal[op] {
		if int(e) == errno {
			return true
		}
	}
	return false
}

type nsFuzzHeld struct {
	handle uint64
	path   string
}

// nsFuzzNode is one node's side of the storm: its handles and its tally.
type nsFuzzNode struct {
	c       *Client
	held    []nsFuzzHeld
	okCount map[string]int
	errs    map[string]int // "op errno-name" -> count, legal ones
	bad     []string       // illegal results, first few verbatim
	badN    int
	moved   uint64 // blocks defrag moved
}

func (n *nsFuzzNode) judge(op, what, rpc string, args any) Response {
	r, err := n.c.Call(rpc, args)
	if err == nil && r.OK {
		n.okCount[op]++
		return r
	}
	errno, msg := 0, ""
	if err != nil {
		msg = err.Error()
	} else {
		errno, msg = r.Errno, r.Error
	}
	if nsFuzzErrnoOK(op, errno) {
		n.errs[fmt.Sprintf("%s %s", op, syscall.Errno(errno).Error())]++
		return r
	}
	n.badN++
	if len(n.bad) < 20 {
		n.bad = append(n.bad, fmt.Sprintf("%s %s: errno %d: %s", op, what, errno, msg))
	}
	return r
}

const nsFuzzMaxHeld = 4

// nsFuzzSpan: the blocks a file's operations range over. Wide enough that
// two nodes' interleaved allocations split a file past the record's four
// inline extents into leaf blocks -- the cached tree blocks whose
// freshness (file_seq) a peer's write must invalidate, and which a span of
// 16 never produced (file_seq_ignore went unnoticed).
const nsFuzzSpan = 64

func (n *nsFuzzNode) doOp(rnd *rand.Rand, op, a, b string, pool int) {
	c := n.c
	blk := int64(rnd.Intn(nsFuzzSpan))
	switch op {
	case "create":
		n.judge(op, a, "fuzz_write", FuzzWriteArgs{Path: a, Block: 0, Count: 1 + rnd.Intn(4), Create: true, Node: c.Name})
	case "fill":
		// A dense file, the only kind defrag moves: two nodes filling one
		// name interleave their allocations into many extents.
		n.judge(op, a, "fuzz_write", FuzzWriteArgs{Path: a, Block: 0, Count: 8, Create: true, Node: c.Name})
	case "read", "hread":
		args := FuzzReadArgs{Path: a, Block: blk, Count: 1 + rnd.Intn(8)}
		what := a
		if op == "hread" {
			if len(n.held) == 0 {
				return
			}
			h := n.held[rnd.Intn(len(n.held))]
			args.Path, args.Handle, what = "", h.handle, h.path+" (held)"
		}
		if r := n.judge(op, what, "fuzz_read", args); r.OK {
			var fr FuzzReadResult
			if decodeResult(c.Name, r, nil, &fr) == nil && len(fr.Bad) > 0 {
				n.badN++
				if len(n.bad) < 20 {
					n.bad = append(n.bad, fmt.Sprintf("%s %s: CONTENT: %s", op, what, strings.Join(fr.Bad, "; ")))
				}
			}
		}
	case "write":
		n.judge(op, a, "fuzz_write", FuzzWriteArgs{Path: a, Block: blk, Count: 1 + rnd.Intn(3), Node: c.Name})
	case "dwrite":
		n.judge(op, a, "fuzz_write", FuzzWriteArgs{Path: a, Block: blk, Count: 1 + rnd.Intn(3), Direct: true, Node: c.Name})
	case "mkdir":
		n.judge(op, a, "mkdir", MkdirArgs{Path: a, Strict: true})
	case "unlink":
		n.judge(op, a, "unlink", UnlinkArgs{Path: a})
	case "rmdir":
		n.judge(op, a, "rmdir", RmdirArgs{Path: a})
	case "rename":
		n.judge(op, a+" -> "+b, "rename", RenameArgs{Old: a, New: b})
	case "symlink":
		n.judge(op, a, "symlink", SymlinkArgs{Target: fmt.Sprintf("e%04d", rnd.Intn(pool)), LinkPath: a})
	case "link":
		n.judge(op, a+" -> "+b, "link", LinkArgs{OldPath: a, NewPath: b})
	case "chmod":
		n.judge(op, a, "chmod", ChmodArgs{Path: a, Mode: 0600 | uint32(rnd.Intn(0100))})
	case "truncate":
		n.judge(op, a, "truncate", TruncateArgs{Path: a, Size: int64(4096 * rnd.Intn(nsFuzzSpan))})
	case "xset":
		n.judge(op, a, "xattr_set", XattrSetArgs{Path: a, Name: fmt.Sprintf("user.x%d", rnd.Intn(2)),
			Value: fmt.Sprintf("%s-%d", c.Name, rnd.Intn(1000))})
	case "xrm":
		n.judge(op, a, "xattr_remove", XattrRemoveArgs{Path: a, Name: fmt.Sprintf("user.x%d", rnd.Intn(2))})
	case "falloc":
		mode := uint32(0)
		if rnd.Intn(2) == 0 {
			mode = fallocKeepSize
		}
		n.judge(op, a, "fallocate", FallocateArgs{Path: a, Offset: blk * 4096, Length: int64(1+rnd.Intn(4)) * 4096, Mode: mode})
	case "punch":
		n.judge(op, a, "fallocate", FallocateArgs{Path: a, Offset: blk * 4096, Length: int64(1+rnd.Intn(3)) * 4096,
			Mode: 0x02 | fallocKeepSize}) // FALLOC_FL_PUNCH_HOLE
	case "zero":
		n.judge(op, a, "fallocate", FallocateArgs{Path: a, Offset: blk * 4096, Length: int64(1+rnd.Intn(3)) * 4096,
			Mode: fallocZeroRange})
	case "defrag":
		if r := n.judge(op, a, "defrag_file", DefragFileArgs{Path: a}); r.OK {
			var d DefragFileResult
			if decodeResult(c.Name, r, nil, &d) == nil {
				n.moved += d.BlocksMoved
			}
		}
	case "hold":
		if len(n.held) >= nsFuzzMaxHeld {
			n.release(0)
		}
		r := n.judge(op, a, "open_hold", OpenHoldArgs{Path: a, Mode: "rdwr"})
		if r.OK {
			var h OpenHoldResult
			if decodeResult(c.Name, r, nil, &h) == nil {
				n.held = append(n.held, nsFuzzHeld{h.Handle, a})
			}
		}
	case "release":
		if len(n.held) > 0 {
			n.release(rnd.Intn(len(n.held)))
		}
	case "hwrite":
		if len(n.held) > 0 {
			h := n.held[rnd.Intn(len(n.held))]
			n.judge(op, h.path+" (held)", "fuzz_write", FuzzWriteArgs{Handle: h.handle, Block: blk,
				Count: 1 + rnd.Intn(3), Node: c.Name})
		}
	case "flock", "funlock":
		if len(n.held) > 0 {
			h := n.held[rnd.Intn(len(n.held))]
			if op == "flock" {
				n.judge(op, h.path+" (held)", "lock_file", LockFileArgs{Handle: h.handle})
			} else {
				n.judge(op, h.path+" (held)", "unlock_file", UnlockFileArgs{Handle: h.handle})
			}
		}
	}
}

func (n *nsFuzzNode) release(i int) {
	h := n.held[i]
	n.held = append(n.held[:i], n.held[i+1:]...)
	n.judge("release", h.path+" (held)", "close", CloseArgs{Handle: h.handle})
}

// nsFuzzSelfTest plants what the error and content oracles exist to catch,
// and requires each to be caught. Returns a description of the first
// instrument that failed, or "".
func nsFuzzSelfTest(c *Client, arena string) string {
	ctl := arena + "/selftest"
	if r, e := c.Call("fuzz_write", FuzzWriteArgs{Path: ctl, Block: 0, Count: 4, Create: true, Node: c.Name}); decodeResult(c.Name, r, e, nil) != nil {
		return "self-test: the control file could not be written"
	}
	// Block 1: another file's fid. Block 2: this file's block for offset 3.
	if r, e := c.Call("fuzz_write", FuzzWriteArgs{Path: ctl, Block: 1, Count: 1, Node: c.Name, PlantFid: "0badf1d0badf"}); decodeResult(c.Name, r, e, nil) != nil {
		return "self-test: the planted foreign block could not be written"
	}
	if r, e := c.Call("fuzz_write", FuzzWriteArgs{Path: ctl, Block: 2, Count: 1, Node: c.Name, PlantSkew: 1}); decodeResult(c.Name, r, e, nil) != nil {
		return "self-test: the planted misplaced block could not be written"
	}
	var vr FuzzVerifyResult
	if r, e := c.Call("fuzz_verify", FuzzVerifyArgs{Dir: arena}); decodeResult(c.Name, r, e, &vr) != nil {
		return "self-test: fuzz_verify failed"
	}
	var bad []string
	for _, f := range vr.Files {
		if f.Name == "selftest" {
			bad = f.Bad
		}
	}
	foreign, misplaced := false, false
	for _, b := range bad {
		foreign = foreign || strings.Contains(b, "@4096: another file's block")
		misplaced = misplaced || strings.Contains(b, "@8192: this file's block from offset 12288")
	}
	if !foreign || !misplaced || len(bad) != 2 {
		return fmt.Sprintf("self-test: the content oracle reported %v for a foreign block @4096 and a misplaced one @8192", bad)
	}
	if r, e := c.Call("unlink", UnlinkArgs{Path: ctl}); decodeResult(c.Name, r, e, nil) != nil {
		return "self-test: the control file could not be removed"
	}
	// The error oracle: an errno must arrive, and one no op allows must be judged illegal.
	r, _ := c.Call("unlink", UnlinkArgs{Path: ctl})
	if r.OK || r.Errno != int(syscall.ENOENT) || !nsFuzzErrnoOK("unlink", r.Errno) {
		return fmt.Sprintf("self-test: unlink of a missing name gave ok=%v errno=%d, want a legal ENOENT", r.OK, r.Errno)
	}
	if nsFuzzErrnoOK("write", int(syscall.EIO)) || nsFuzzErrnoOK("unlink", int(syscall.EUCLEAN)) ||
		nsFuzzErrnoOK("rename", 0) {
		return "self-test: the error oracle accepts EIO, EUCLEAN or an errno-less failure"
	}
	return ""
}

func RunNsFuzz(clients []*Client, baseDir string, seed int64, opsPerNode, pool int, opset string, filelock bool,
	knob string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("ns-fuzz: needs at least 2 nodes, have %d", len(clients))
	}
	ops := nsFuzzAllOps
	if strings.TrimSpace(opset) != "" {
		ops = nil
		for _, o := range strings.Split(opset, ",") {
			o = strings.TrimSpace(o)
			for _, known := range nsFuzzAllOps {
				if o == known {
					ops = append(ops, o)
				}
			}
		}
		if len(ops) == 0 {
			return false, fmt.Errorf("ns-fuzz: opset %q selected no known ops (known: %s)", opset, strings.Join(nsFuzzAllOps, ","))
		}
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	mode := "nofilelock"
	if filelock {
		mode = "default file lock"
		if err := mountAllDefault(clients); err != nil {
			return false, err
		}
	} else if err := mountAllNoFileLock(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	// A fresh arena per run: the content oracle judges every file in it,
	// and a file an earlier build wrote is not this run's to judge.
	arena := fmt.Sprintf("%s/nsfuzz-%d-%d", baseDir, seed, time.Now().Unix())
	if r, e := clients[0].Call("mkdir", MkdirArgs{Path: arena}); decodeResult(clients[0].Name, r, e, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", arena)
	}
	fmt.Printf("=== ns-fuzz: %d nodes x %d ops, pool=%d, seed=%d, %s, ops=[%s] ===\n",
		len(clients), opsPerNode, pool, seed, mode, strings.Join(ops, ","))

	ok := true
	if why := nsFuzzSelfTest(clients[0], arena); why != "" {
		check(&ok, "the fuzzer's oracles catch what they are planted with", false, why)
		return false, nil
	}
	check(&ok, "self-test: a foreign block, a misplaced block and an illegal errno are each caught", true, "")

	// Scope oracle 4's dmesg scan to THIS run: the ring buffer persists
	// across runs, and without the marker one failing run poisons every
	// run after it on the same slaves. Best-effort -- a slave too old to
	// know the RPC just gets an unscoped (stricter) scan.
	dmesgMark := fmt.Sprintf("nsfuzz-%d-%d", seed, time.Now().UnixNano())
	for _, c := range clients {
		if r, e := c.Call("dmesg_mark", DmesgMarkArgs{Marker: dmesgMark}); decodeResult(c.Name, r, e, nil) != nil {
			fmt.Printf("    (%s: dmesg_mark unsupported -- its double-free scan covers the whole ring)\n", c.Name)
		}
	}

	// A negative control: a TEST ONLY knob set on every node for the
	// whole run -- the storm AND the read-back, since a fault that only the
	// readers' freshness gate would show is undone by restoring it first.
	// Put back to 0 when the scenario returns.
	var knobName, knobVal string
	if knob != "" {
		eq := strings.IndexByte(knob, '=')
		if eq <= 0 {
			return false, fmt.Errorf("ns-fuzz: -nsfuzz-knob %q is not name=value", knob)
		}
		knobName, knobVal = knob[:eq], knob[eq+1:]
		fmt.Printf("    NEGATIVE CONTROL: %s=%s on every node for the storm -- this run is expected to FAIL\n", knobName, knobVal)
	}
	setKnob := func(val string) error {
		for _, c := range clients {
			r, e := c.Call("mod_param", ModParamArgs{Name: knobName, Value: val})
			if err := decodeResult(c.Name, r, e, nil); err != nil {
				return err
			}
		}
		return nil
	}
	if knobName != "" {
		if err := setKnob(knobVal); err != nil {
			return false, fmt.Errorf("ns-fuzz: setting %s: %w", knobName, err)
		}
		defer func() {
			if err := setKnob("0"); err != nil {
				fmt.Printf("WARNING: %s not restored: %v\n", knobName, err)
			}
		}()
	}

	nm := func(i int) string { return fmt.Sprintf("%s/e%04d", arena, i) }

	nodes := make([]*nsFuzzNode, len(clients))
	var wg sync.WaitGroup
	for ci, c := range clients {
		n := &nsFuzzNode{c: c, okCount: map[string]int{}, errs: map[string]int{}}
		nodes[ci] = n
		ci := ci
		wg.Add(1)
		go func() {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(seed + int64(ci)*7919 + 1))
			for i := 0; i < opsPerNode; i++ {
				n.doOp(rnd, ops[rnd.Intn(len(ops))], nm(rnd.Intn(pool)), nm(rnd.Intn(pool)), pool)
			}
			for len(n.held) > 0 {
				n.release(len(n.held) - 1)
			}
		}()
	}
	wg.Wait()

	// Oracle 0: every result was a success or a legal loss.
	okTotal, lostTotal := map[string]int{}, map[string]int{}
	var moved uint64
	for _, n := range nodes {
		moved += n.moved
		for op, k := range n.okCount {
			okTotal[op] += k
		}
		for k, v := range n.errs {
			lostTotal[k] += v
		}
		for _, b := range n.bad {
			fmt.Printf("    %s: %s\n", n.c.Name, b)
		}
		check(&ok, fmt.Sprintf("%s: every failed op lost a race legally", n.c.Name), n.badN == 0,
			fmt.Sprintf("%d op(s) failed with an errno no race explains -- replay with seed %d", n.badN, seed))
	}
	var tally []string
	for _, op := range ops {
		tally = append(tally, fmt.Sprintf("%s=%d", op, okTotal[op]))
	}
	fmt.Printf("    succeeded: %s\n", strings.Join(tally, " "))
	var losses []string
	for k, v := range lostTotal {
		losses = append(losses, fmt.Sprintf("%s=%d", k, v))
	}
	sort.Strings(losses)
	fmt.Printf("    lost races: %s\n", strings.Join(losses, ", "))
	// The setup: an op that never once succeeded was never exercised, and
	// every check below says nothing about it.
	if opsPerNode*len(clients) >= 40*len(ops) {
		var never []string
		for _, op := range ops {
			if op == "defrag" && !filelock {
				continue // refused by design under nofilelock
			}
			if okTotal[op] == 0 {
				never = append(never, op)
			}
		}
		check(&ok, "setup: every op in the vocabulary succeeded at least once", len(never) == 0,
			fmt.Sprintf("never succeeded: %s", strings.Join(never, ",")))
		for _, op := range ops {
			if op == "defrag" && filelock {
				check(&ok, fmt.Sprintf("setup: defrag moved blocks (%d) -- the mover ran under the storm", moved), moved > 0,
					"every defrag declined or found its file contiguous")
			}
		}
	}

	// Let any deferred cross-node block frees (the pending-free queue)
	// settle, so the views and fsck reflect the quiesced state and a
	// still-draining free cannot masquerade as a leak.
	statfsOf := func(c *Client, label string) (StatfsResult, error) {
		resp, err := c.Call("statfs", struct{}{})
		var res StatfsResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return StatfsResult{}, fmt.Errorf("%s: statfs (%s): %w", c.Name, label, err)
		}
		return res, nil
	}
	_ = quiesceFreeBlocks(statfsOf, clients)

	// Oracles 1 and 2: agreement on every entry, and every block judged.
	var ref map[string]FuzzFileView
	refName := ""
	files, data, leafy := 0, 0, 0
	for _, c := range clients {
		var vr FuzzVerifyResult
		r, e := c.Call("fuzz_verify", FuzzVerifyArgs{Dir: arena})
		if decodeResult(c.Name, r, e, &vr) != nil {
			check(&ok, fmt.Sprintf("%s could read the arena back", c.Name), false, "fuzz_verify failed")
			continue
		}
		view := map[string]FuzzFileView{}
		var bad []string
		for _, f := range vr.Files {
			view[f.Name] = f
			for _, b := range f.Bad {
				bad = append(bad, f.Name+": "+b)
			}
		}
		for i, b := range bad {
			if i >= 10 {
				fmt.Printf("    ... and %d more\n", len(bad)-10)
				break
			}
			fmt.Printf("    %s: %s\n", c.Name, b)
		}
		check(&ok, fmt.Sprintf("%s: every block of every file is zeros or the file's own", c.Name), len(bad) == 0,
			fmt.Sprintf("%d finding(s) -- replay with seed %d", len(bad), seed))
		if ref == nil {
			ref, refName = view, c.Name
			for _, f := range vr.Files {
				if f.Kind == "file" {
					files++
					data += f.Data
					if f.Extents > 4 {
						leafy++
					}
				}
			}
			continue
		}
		var diff []string
		for name, a := range ref {
			b, there := view[name]
			if !there {
				diff = append(diff, fmt.Sprintf("%s: %s only", name, refName))
				continue
			}
			a.Bad, b.Bad = nil, nil
			if fmt.Sprintf("%+v", a) != fmt.Sprintf("%+v", b) {
				diff = append(diff, fmt.Sprintf("%s: %s %+v, %s %+v", name, refName, a, c.Name, b))
			}
		}
		for name := range view {
			if _, there := ref[name]; !there {
				diff = append(diff, fmt.Sprintf("%s: %s only", name, c.Name))
			}
		}
		sort.Strings(diff)
		for i, d := range diff {
			if i >= 10 {
				fmt.Printf("    ... and %d more\n", len(diff)-10)
				break
			}
			fmt.Printf("    differs: %s\n", d)
		}
		check(&ok, fmt.Sprintf("%s and %s agree on all %d entries: kind, inode, size, nlink, content, xattrs, target",
			refName, c.Name, len(ref)), len(diff) == 0,
			fmt.Sprintf("%d entr(ies) differ -- cross-node visibility divergence", len(diff)))
	}
	fmt.Printf("    judged: %d files, %d stamped blocks; %d file(s) past the 4 inline extents\n", files, data, leafy)
	if opsPerNode*len(clients) >= 40*len(ops) {
		check(&ok, fmt.Sprintf("setup: %d file(s) keep their map in leaf blocks -- the cached-tree path is exercised", leafy),
			leafy > 0, "no file grew past its inline extents")
	}

	// Oracle 3: fsck, strict. An uninjected run must leave NO orphan, NO
	// detached subtree, NO duplicate name, NO nlink disagreement and none
	// of fsck's hard corruptions.
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	r, e := clients[0].Call("fsck", FsckArgs{})
	if decodeResult(clients[0].Name, r, e, &fr) != nil {
		check(&ok, "fsck ran after the fuzz", false, "fsck call failed")
	} else {
		var bad []string
		for _, ln := range strings.Split(fr.Output, "\n") {
			l := strings.TrimSpace(ln)
			if !strings.HasPrefix(l, "ERR") {
				continue
			}
			low := strings.ToLower(l)
			if strings.Contains(low, "but no directory") || // orphan: allocated but nothing names it
				strings.Contains(low, "not reachable") || // detached subtree
				strings.Contains(low, "duplicate") ||
				strings.Contains(low, "nlink") ||
				strings.Contains(low, "marked free") || // referenced block reads free -- data loss
				(strings.Contains(low, "referenced by") && strings.Contains(low, "inodes")) ||
				strings.Contains(low, "overlap") || strings.Contains(low, "cross") ||
				strings.Contains(low, "checksum") || strings.Contains(low, "magic") ||
				strings.Contains(low, "no '.'") || strings.Contains(low, "no '..'") {
				bad = append(bad, l)
			}
		}
		for i, l := range bad {
			if i >= 10 {
				fmt.Printf("    ... and %d more\n", len(bad)-10)
				break
			}
			fmt.Printf("    fsck: %s\n", l)
		}
		check(&ok, fmt.Sprintf("fsck clean after %d ops/node -- no orphan / detached / duplicate / nlink / corruption", opsPerNode),
			len(bad) == 0, fmt.Sprintf("%d corruption finding(s) -- replay with seed %d", len(bad), seed))
	}

	// Oracle 4: NO node may have detected a double free. The kernel
	// absorbs the benign orderings and only warns -- but those are the
	// lucky interleavings of the exact race whose unlucky one is fsck's
	// "referenced by an inode but marked FREE": the second free landing
	// after the block was handed to a live file.
	for _, c := range clients {
		var dm DmesgTailResult
		r, e := c.Call("dmesg_tail", DmesgTailArgs{Lines: 50000, Since: dmesgMark})
		if decodeResult(c.Name, r, e, &dm) != nil {
			check(&ok, fmt.Sprintf("%s dmesg readable for the double-free scan", c.Name), false, "dmesg_tail failed")
			continue
		}
		// Only the BLOCK-level message: a losing evict's inode-bitmap
		// arbitration is the arbiter working as designed.
		var hits []string
		for _, ln := range strings.Split(dm.Text, "\n") {
			if strings.Contains(ln, "double free of extent") {
				hits = append(hits, strings.TrimSpace(ln))
			}
		}
		for i, h := range hits {
			if i >= 5 {
				fmt.Printf("    ... and %d more\n", len(hits)-5)
				break
			}
			fmt.Printf("    %s dmesg: %s\n", c.Name, h)
		}
		check(&ok, fmt.Sprintf("%s saw no double free", c.Name), len(hits) == 0,
			fmt.Sprintf("%d double-free warning(s) -- a block or inode number was freed twice", len(hits)))
	}

	if ok {
		fmt.Printf("PASS: ns-fuzz seed=%d -- every op judged, all nodes agree, every block accounted for, fsck clean after %d ops/node\n", seed, opsPerNode)
	}
	return ok, nil
}
