// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
)

// Wire protocol: newline-delimited JSON over a plain TCP connection, one
// Request per line from master->slave and one Response per line back.
// Deliberately not gRPC/net-rpc/anything requiring extra dependencies --
// this project otherwise has zero external deps, and the protocol here is
// simple enough (small number of ops, no streaming) that stdlib
// encoding/json + net is all it needs.

type Request struct {
	ID   uint64          `json:"id"`
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args,omitempty"`
}

type Response struct {
	ID     uint64          `json:"id"`
	OK     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
}

// frameConn wraps a net.Conn with a json.Encoder/Decoder pair. Encoder.
// Encode writes exactly one JSON value followed by '\n' per call, and
// Decoder.Decode reads exactly one JSON value per call tolerating
// whitespace between them -- together these give newline-delimited
// framing for free, no manual length-prefixing needed.
type frameConn struct {
	enc *json.Encoder
	dec *json.Decoder
	mu  sync.Mutex // serializes writers sharing this frameConn
}

func newFrameConn(c net.Conn) *frameConn {
	return &frameConn{
		enc: json.NewEncoder(c),
		dec: json.NewDecoder(bufio.NewReader(c)),
	}
}

func (f *frameConn) writeRequest(r Request) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.enc.Encode(r)
}

func (f *frameConn) readRequest() (Request, error) {
	var r Request
	err := f.dec.Decode(&r)
	return r, err
}

func (f *frameConn) writeResponse(r Response) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.enc.Encode(r)
}

func (f *frameConn) readResponse() (Response, error) {
	var r Response
	err := f.dec.Decode(&r)
	return r, err
}

// ---- Per-op argument/result types ----
//
// Every op is one Request.Args -> Response.Result pair; ops with nothing
// to report just get struct{}{} as their result and OK/Error conveys
// success.

// MountArgs/UnmountArgs carry nothing: WHICH device a slave mounts and
// WHERE it mounts it are the slave's own configuration (-device and
// -mountpoint on the slave command line), not something the master
// dictates over the wire.
//
// That split is deliberate. When the master named the path, a slave
// started with one mountpoint could be driven to mount at another, and
// the only thing standing between a scenario and the HOST filesystem
// was that the master and the operator happened to agree. They did not:
// a slave launched with -mountpoint /root/cetrafs/test was told to
// mount /mnt/ctest, and 50 MB of a suite run landed on the root
// filesystem of the machine instead of on cetrafs. A slave that owns
// its own mountpoint cannot be talked into writing somewhere else.
type MountArgs struct {
	// NoFileLock mounts with `-o nofilelock`, turning off the open-time
	// automatic whole-file exclusive lock. The explicit-lock scenario
	// needs this: it is the mount under which userspace drives the lock
	// by flock(2) rather than the kernel locking on open.
	// Ignored when the slave adopts an already-live mount, so a scenario
	// wanting a specific option must unmount first.
	NoFileLock bool `json:"nofilelock,omitempty"`
}

type UnmountArgs struct{}

// LockFileArgs / UnlockFileArgs flock(LOCK_EX) / flock(LOCK_UN) an
// already-open held fd (from open_hold). The lock is fd-scoped, so the
// handle must stay open for the lock to persist -- which is exactly why
// it runs against a held handle rather than opening and closing its own.
type LockFileArgs struct {
	Handle uint64 `json:"handle"`
}

type UnlockFileArgs struct {
	Handle uint64 `json:"handle"`
}

// SlaveInfoResult lets the master learn each slave's own device and
// mountpoint rather than assuming them -- used to print what is actually
// under test, and to refuse a run where the slaves disagree about which
// device they are sharing.
type SlaveInfoResult struct {
	Device     string `json:"device"`
	MountPoint string `json:"mount_point"`
	Mounted    bool   `json:"mounted"`

	// Every path this slave's machine has the DEVICE mounted on, not
	// just the slave's own mountpoint. A mount elsewhere is invisible to
	// Mounted and survives doUnmount, but mkfs.cetra sees it and refuses
	// -- so the master checks this up front rather than letting a
	// scenario misreport its own environment as a filesystem bug.
	DeviceMountedAt []string `json:"device_mounted_at,omitempty"`
}

// MkfsArgs runs mkfs.cetra against the slave's own device.
//
// MkfsResult reports the command's exit status as DATA rather than as a
// transport error, because "mkfs refused" is the expected, required
// outcome in the mkfs-guard scenario -- a failing mkfs must be
// distinguishable from a slave that could not run mkfs at all. Collapsing
// both into an error would make the guard test unable to fail for the
// right reason.
type MkfsArgs struct {
	Force bool     `json:"force"`
	Extra []string `json:"extra,omitempty"`
}

type MkfsResult struct {
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
}

// WriteArgs: create (or truncate) the file at Path and write exactly Size
// bytes of Stamp repeated/truncated to fill it -- a verifiable pattern (not
// random data) so a master comparing two slaves' writes to the same file
// can tell whose bytes ended up where, rather than just "it's some bytes".
type WriteArgs struct {
	Path  string `json:"path"`
	Size  int    `json:"size"`
	Stamp string `json:"stamp"`
}

type WriteResult struct {
	BytesWritten int    `json:"bytes_written"`
	Checksum     string `json:"checksum"` // sha256 hex
}

type ReadArgs struct {
	Path string `json:"path"`
}

type ReadResult struct {
	Size     int64  `json:"size"`
	Checksum string `json:"checksum"`          // sha256 hex
	Content  string `json:"content,omitempty"` // base64, only included for small files
}

// WriteAtArgs: pwrite-style -- write exactly Size bytes of Stamp
// repeated/truncated to fill it, at Offset, without truncating or
// otherwise touching the rest of the file. The plain "write" op always
// creates the file fresh and writes the whole thing from offset 0,
// which would mean materializing the entire file in memory and on the
// wire just to touch a small region at the far end of a huge sparse
// file (RunSparseBigFile's reason for needing this). Create requests
// O_CREATE (the file may not exist yet at Offset 0); growing the file
// large enough to write at a non-zero Offset is the caller's own job
// (e.g. a "truncate" call first), not implied by this op.
type WriteAtArgs struct {
	Path   string `json:"path"`
	Offset int64  `json:"offset"`
	Size   int    `json:"size"`
	Stamp  string `json:"stamp"`
	Create bool   `json:"create,omitempty"`
}

type WriteAtResult struct {
	BytesWritten int    `json:"bytes_written"`
	Checksum     string `json:"checksum"` // sha256 hex of exactly the bytes written
}

// ReadAtArgs/Result: pread-style counterpart to WriteAtArgs above, for
// the same reason -- the plain "read" op reads the entire file into
// memory.
type ReadAtArgs struct {
	Path   string `json:"path"`
	Offset int64  `json:"offset"`
	Size   int    `json:"size"`
}

type ReadAtResult struct {
	BytesRead int    `json:"bytes_read"`
	Checksum  string `json:"checksum"`
}

// HeldIOArgs: read or write through an ALREADY-OPEN handle, never through
// a fresh open. Load-bearing for anything about cache freshness: an open()
// is itself a refresh boundary (cetrafs_lock_open's mtime-gated refresh and
// its tree reconcile), so a path-based read cannot tell a correctly
// invalidated cache from one that was simply re-read on open. The lock
// suspension scenario needs reads that go through the SAME fd that was
// open before a peer touched the file.
type HeldIOArgs struct {
	Handle uint64 `json:"handle"`
	Offset int64  `json:"offset"`
	Size   int    `json:"size"`
	Stamp  string `json:"stamp,omitempty"` // write only: repeated to fill Size
}

type HeldIOResult struct {
	Bytes    int    `json:"bytes"`
	Checksum string `json:"checksum"`
}

// OpenHoldArgs: open the file and keep the fd open on the slave side,
// tracked by Handle, until a later "close" call -- needed for any
// scenario where one node must hold a file open while another node tries
// something against it (the whole-file-lock race, unlink-vs-open, etc).
type OpenHoldArgs struct {
	Path   string `json:"path"`
	Mode   string `json:"mode"` // "rdonly" | "wronly" | "rdwr"
	Create bool   `json:"create"`
	// Excl requests O_EXCL alongside O_CREATE, so a losing concurrent
	// create actually fails with EEXIST instead of silently opening the
	// file a peer just created -- same bug class as MkdirArgs.Strict
	// (see its comment). Only RunConcurrentCreate's race probe wants
	// this; every lock-contention scenario (RunLockRace, RunLockHold,
	// the sequential variant) deliberately opens an *already-created*
	// file with plain O_CREATE to test the cross-node write lock itself,
	// not file-creation races, and must not set this.
	Excl bool `json:"excl,omitempty"`
}

type OpenHoldResult struct {
	Handle uint64 `json:"handle"`
}

type CloseArgs struct {
	Handle uint64 `json:"handle"`
}

type UnlinkArgs struct {
	Path string `json:"path"`
}

type RenameArgs struct {
	Old string `json:"old"`
	New string `json:"new"`
}

type MkdirArgs struct {
	Path string `json:"path"`
	// Strict requests a plain, non-recursive mkdir(2) that fails with
	// EEXIST if the path is already a directory, instead of the default
	// os.MkdirAll() idempotency every setup call relies on (creating a
	// suite's shared base directory from multiple scenario functions
	// across one run, where "already exists" is expected and fine).
	// Concurrent-mkdir needs this: os.MkdirAll() silently swallows the
	// EEXIST a genuinely-losing concurrent mkdir(2) call gets back from
	// the kernel (it treats "already a directory" as success regardless
	// of which caller created it), which was reporting "2 successes" on
	// real two-node races where the kernel had in fact correctly
	// rejected the loser -- confirmed via kmod dmesg logging showing
	// cetrafs_dir_add_entry() returning -EEXIST for the loser while
	// ctest still reported "mkdir SUCCEEDED" for it.
	Strict bool `json:"strict,omitempty"`
}

type StatArgs struct {
	Path string `json:"path"`

	// NoFollow makes this an lstat(2): the SYMLINK's own record, not
	// whatever it points at. Without it a symlink with a dangling
	// target -- which is the normal case for a test symlink -- stats as
	// ENOENT, so its inode number cannot be observed at all.
	NoFollow bool `json:"nofollow,omitempty"`
}

type StatResult struct {
	Size  int64  `json:"size"`
	Nlink uint32 `json:"nlink"`

	// Ino is what makes inode REUSE observable across nodes: a number
	// freed by one node and handed to a different file by the other is
	// the whole premise of the generation field (format v0x0008), and a
	// scenario cannot assert the reuse actually happened without seeing
	// the number.
	Ino  uint64 `json:"ino"`
	Mode string `json:"mode"`
	// ModeBits is the raw permission bits (st_mode & 0777) -- Mode's
	// textual rendering ("-rw-r--r--") is for humans; a chmod
	// cross-node check wants to compare the exact numeric bits.
	ModeBits uint32 `json:"mode_bits"`
	IsDir    bool   `json:"is_dir"`
}

type RmdirArgs struct {
	Path string `json:"path"`
}

type ChmodArgs struct {
	Path string `json:"path"`
	Mode uint32 `json:"mode"` // e.g. 0640
}

type TruncateArgs struct {
	Path string `json:"path"`
	Size int64  `json:"size"`
}

type SymlinkArgs struct {
	Target   string `json:"target"`
	LinkPath string `json:"link_path"`
}

type ReadlinkArgs struct {
	Path string `json:"path"`
}

type ReadlinkResult struct {
	Target string `json:"target"`
}

type LinkArgs struct {
	OldPath string `json:"old_path"`
	NewPath string `json:"new_path"`
}

type XattrSetArgs struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

type XattrGetArgs struct {
	Path string `json:"path"`
	Name string `json:"name"`
}

type XattrGetResult struct {
	Found bool   `json:"found"`
	Value string `json:"value"`
}

type ReaddirArgs struct {
	Path string `json:"path"`
}

type ReaddirResult struct {
	Names []string `json:"names"`
}

type XattrRemoveArgs struct {
	Path string `json:"path"`
	Name string `json:"name"`
}

type XattrListArgs struct {
	Path string `json:"path"`
}

type XattrListResult struct {
	Names []string `json:"names"`
}

// StatfsResult is a real statfs(2) on this slave's current mountpoint --
// exactly what `df` would report, straight from cetrafs_statfs(). Used
// to check whether space freed/consumed by a write or unlink on one
// node is actually visible in another node's own free-space accounting,
// not just on the node that did it.
type StatfsResult struct {
	BlockSize   int64  `json:"block_size"`
	TotalBlocks uint64 `json:"total_blocks"`
	FreeBlocks  uint64 `json:"free_blocks"`
	AvailBlocks uint64 `json:"avail_blocks"`
	TotalFiles  uint64 `json:"total_files"`
	FreeFiles   uint64 `json:"free_files"`
}

type ProcSnapshotArgs struct {
	Device string `json:"device"`
}

// ZGInfo mirrors one "zg N: ..." line of /proc/fs/cetrafs/<dev>/info.
// Owner is -1 for "none" (CETRAFS_NODE_ID_NONE).
type ZGInfo struct {
	ID             int    `json:"id"`
	Owner          int    `json:"owner"`
	ThisNode       bool   `json:"this_node"`
	FirstBG        int    `json:"first_bg"`
	BGCount        int    `json:"bg_count"`
	FreeDataBlocks uint64 `json:"free_data_blocks"`
	// Gone from the kernel's info line when journals went per-node; kept
	// out of the struct so nothing reads a field that is always zero.
}

// NodeInfo mirrors one "node N: ..." line of
// /proc/fs/cetrafs/<dev>/cluster.
type NodeInfo struct {
	ID       int    `json:"id"`
	State    string `json:"state"`
	UUID     string `json:"uuid"`
	HBSeq    uint64 `json:"hb_seq"`
	LastSeen uint64 `json:"last_seen"`
	Label    string `json:"label"`
	Stale    bool   `json:"stale"`
	ThisNode bool   `json:"this_node"`
}

type ProcSnapshotResult struct {
	ThisNodeID int        `json:"this_node_id"`
	ZoneGroups []ZGInfo   `json:"zone_groups"`
	Nodes      []NodeInfo `json:"nodes"`
	// MaxFileSizeBytes/WriteReady mirror info's max_file_size_bytes/
	// write_ready lines (kmod/procfs.c): the live
	// sb->s_maxbytes cap and whether this node currently owns any ZG
	// to allocate new blocks from. MaxFileSizeBytes is mkfs-time-fixed
	// and must read identically on every node mounting the same
	// volume -- RunSparseBigFile's cross-node check of that is
	// something a single-node test structurally cannot make.
	MaxFileSizeBytes int64 `json:"max_file_size_bytes"`
	WriteReady       bool  `json:"write_ready"`
	Fenced           bool  `json:"fenced"`

	// CASMiscompares is how many compare-and-swaps this host has had
	// REJECTED by the device because the image changed under them --
	// i.e. how much real cross-node contention it is seeing. Each was
	// retried against a fresh image, so a rising count is healthy
	// traffic. It is the evidence a concurrency scenario needs: "no
	// errors" is not proof the contention it claims to create happened.
	CASMiscompares uint64 `json:"cas_miscompares"`

	// Background scrub counters (kmod/scrub.c). ScrubCycles counts only
	// cycles that ran BOTH passes and the free loop, so "it reclaimed
	// nothing" can be told apart from "it never ran" -- without that a
	// scenario asserting the scrub left something alone passes
	// vacuously whenever the scrub was simply asleep.
	ScrubReclaimed uint64 `json:"scrub_reclaimed"`
	ScrubCycles    uint64 `json:"scrub_cycles"`

	// Replay-claim outcomes (kmod/journal.c). The loser of a contended
	// claim returns success and does nothing, so JournalReplayDeclines
	// is the only evidence two nodes ever met over one dead node's
	// journal area; JournalReplays counts the areas this node actually
	// replayed.
	JournalReplays        uint64 `json:"journal_replays"`
	JournalReplayDeclines uint64 `json:"journal_replay_declines"`

	// PendingFreeAppends is how many times this host freed a block in a
	// Zone Group a PEER owns and therefore appended it to that peer's
	// pending-free queue (instead of touching the peer's bitmap directly).
	// Zero on a single-node volume by construction -- the only confirmation
	// the foreign-free append path runs at all, which only a real two-node
	// run can produce. dir-storm, where each node unlinks the other's
	// files, drives it.
	PendingFreeAppends uint64 `json:"pending_free_appends"`

	// The device's atomic COMPARE AND WRITE capability, from
	// properties. If this is not available, every claim path in the
	// filesystem takes the serialised fallback and the volume can only
	// safely have one mounter -- so a two-node run that does not check
	// it may be testing something quite different from what it says.
	CAWClass            string `json:"caw_class"`
	CAWLogicalBlockSize int    `json:"caw_logical_block_size"`
	CAWMaxBlocks        int    `json:"caw_max_blocks"`
	CAWAvailable        bool   `json:"caw_available"`
}

// ProcRawArgs/Result: the raw, unparsed text of all three
// /proc/fs/cetrafs/<device>/ files -- for troubleshooting a real
// multi-node run directly (e.g. checking clustering_pr_supported, or
// eyeballing a cluster/info disagreement the parsed ProcSnapshot doesn't
// surface) without needing someone to manually ssh in and cat them.
// SetControlArgs writes one setting to this slave's own
// /proc/fs/cetrafs/<dev>/controls.
//
// Whitelisted by KEY, like device_read is by structure: the master may
// adjust how this node behaves, not reach arbitrary paths under /proc.
// The value is checked by the kernel, which bounds it.
//
// The point is the cluster timing. The real staleness window is ~60 s,
// so every scenario that needs a node to time out spends a minute
// waiting; compressing it to ~10 s costs nothing in fidelity because
// the peer-advertised floor still applies on top.
type SetControlArgs struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

type SetControlResult struct {
	Controls string `json:"controls"` // the file as it reads afterwards
}

// ModParamArgs: set a cetrafs MODULE parameter on this slave --
// /sys/module/cetrafs/parameters/<name>. Whitelisted by NAME exactly as
// set_control is by key, and the list holds only the knobs that make a
// cross-node scenario possible at all: caw_fail_discover forces CAW
// discovery to fail at the next mount, so a CAW-capable LUN mounts in
// no-CAW mode -- the only way two REAL nodes can exercise the no-CAW
// single-mounter paths, which the loop harness (one node by definition)
// never can; hb_interval_secs/stale_secs compress the gate's watch window
// so a scenario round takes seconds, not minutes. Unlike set_control these
// act BEFORE a mount exists, which is exactly when the mount-path
// scenarios need them.
// FsckArgs: run fsck.cetra against this slave's own device. The binary
// is the one embedded in this ctest (compiled on first use), so a node
// with no cetrafs checkout can still check the volume it is standing on
// -- which is most of a real fleet.
//
// The device MUST be unmounted everywhere: fsck reads a quiet disk, and
// running it under a live mount reports garbage. The caller is
// responsible for that; this refuses if ITS OWN mount is up, which
// catches the common mistake.
type FsckArgs struct {
	Repair bool `json:"repair,omitempty"`
}

type FsckResult struct {
	ExitCode int    `json:"exit_code"`
	Output   string `json:"output"`
	Clean    bool   `json:"clean"`
}

type ModParamArgs struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type ModParamResult struct {
	Prev  string `json:"prev"`  // the parameter as it read BEFORE the write (for restoring)
	Value string `json:"value"` // as it reads afterwards
}

// DevLinkResult: take THIS slave's own device offline, and put
// it back. No arguments at all -- the device is the one the slave was
// started with, never a path the master supplies, for the same reason
// device_read works that way: the master must not be able to name
// another node's disk.
//
// This is the only way to produce the state the fence scenarios need --
// a node that STOPS BEATING while still mounted and still holding its
// zone group, its file locks and its journal area. A clean unmount
// releases all of that first; killing the slave process leaves the
// kernel heartbeat running. Taking the SCSI device offline makes the
// heartbeat's renew fail, so peers see the node go stale, while the
// mount stays up with its claims intact. Verified single-node first:
// tests/kernel/device_failure.sh.
type DevLinkResult struct {
	State string `json:"state"` // the device state as the kernel reports it afterwards
}

// DeviceReadArgs: read one on-disk structure straight off the slave's
// device, using the same helpers tests/ already has.
//
// Read-only, and deliberately so. The whole point of ctest is that two
// real kernels disagree in ways one kernel cannot reproduce, and until
// now a scenario could inspect the FILESYSTEM but never the DEVICE --
// so the structures that only exist to be read by a peer (a
// pending-free queue, a registry row's fence epoch) were unobservable.
// The loop suite has fifteen poke helpers; ctest had none.
//
// WHICH device is the slave's own choice, exactly as with mount: the
// master names a structure, never a path. A master that could name the
// device could aim this at the host's disk.
type DeviceReadArgs struct {
	// Kind selects the helper: "pending" | "node" | "zg" | "inode-lock".
	Kind string `json:"kind"`
	// Args are the helper's own arguments AFTER the device: a zone
	// group id, a row index, an inode number. Anything that would make
	// the helper WRITE is rejected by the slave.
	Args []string `json:"args,omitempty"`
}

type DeviceReadResult struct {
	Output string `json:"output"`
}

type ProcRawArgs struct {
	Device string `json:"device"`
}

type ProcRawResult struct {
	Info       string `json:"info"`
	Properties string `json:"properties"`
	Cluster    string `json:"cluster"`
}

// DmesgTailArgs/Result: the last N lines of this slave's own dmesg --
// same self-serve troubleshooting motivation as ProcRaw, for seeing a
// real multi-node race's actual kernel-side log lines (e.g. "lock: ino=...
// lost race claiming write lock", or its absence) without needing someone
// to copy-paste dmesg output by hand.
type DmesgTailArgs struct {
	Lines int `json:"lines"`
	// Since: return only lines AFTER the last occurrence of this marker
	// (planted by dmesg_mark). Lets a scenario scan exactly its own
	// window of a ring buffer that persists across runs -- without it, a
	// warning from a previous run fails the current one.
	Since string `json:"since,omitempty"`
}

type DmesgTailResult struct {
	Text string `json:"text"`
}

// DmesgMarkArgs: write a marker line into this slave's kernel log so a
// later dmesg_tail{Since} reads only what happened after it. Same idea
// as tests/lib/harness.sh's dmesg_mark/dmesg_since, cluster-side.
type DmesgMarkArgs struct {
	Marker string `json:"marker"`
}

// ModuleInfoResult answers "which build of cetrafs.ko is actually
// running on this node right now" -- the two-node fixes in this project
// are easy to misalign (rebuild one side, forget the other, or rebuild
// but forget to rmmod/insmod), and waiting on a failing scenario to find
// that out wastes a round trip. Loaded is determined from
// /sys/module/cetrafs existing (NOT from srcversion -- see BuildID
// below, this kernel's build never produces a srcversion file at all,
// loaded or not, confirmed via `modinfo` showing no srcversion line
// either; treating its absence as "not loaded" was a real ctest bug,
// caught when a user correctly called out "loaded=false" while `lsmod`
// plainly showed it loaded). BuildID is the ELF .note.gnu.build-id of
// whatever is *actually loaded* (parsed from
// /sys/module/cetrafs/notes/.note.gnu.build-id) -- two slaves reporting
// different BuildID means they're definitely running different code, no
// guessing required, and unlike srcversion this note is always present
// (toolchains stamp it by default). KoSHA256/KoModTime are the on-disk
// .ko file's own fingerprint/mtime, which can differ from what's loaded
// if it was rebuilt but not yet reloaded (KoPath reports which
// candidate path was actually found, or "" if none were).
type ModuleInfoResult struct {
	Loaded bool `json:"loaded"`
	// How it came to be loaded: "already-loaded", "modprobe", or
	// "insmod <path>". Reported rather than silent because the whole
	// point of this precondition is knowing WHICH build each node is
	// running -- a node that auto-loaded a different module than the
	// operator expected must be visible, not convenient.
	LoadedBy string `json:"loaded_by,omitempty"`
	LoadErr  string `json:"load_err,omitempty"`
	BuildID  string `json:"build_id,omitempty"`
	// The LOADED module's MODULE_VERSION, read from
	// /sys/module/cetrafs/version. It embeds a hash of the source it was
	// built from, and unlike KoSHA256 it describes what is actually
	// RUNNING -- a node whose .ko file was replaced but never reloaded
	// reports a new file hash and an old version, which is precisely the
	// case that once let a stale module through this gate.
	Version   string `json:"version,omitempty"`
	KoPath    string `json:"ko_path,omitempty"`
	KoSHA256  string `json:"ko_sha256,omitempty"`
	KoModTime string `json:"ko_mod_time,omitempty"`
}
