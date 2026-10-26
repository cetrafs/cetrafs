// SPDX-License-Identifier: GPL-2.0-or-later
// ctest -- multi-node concurrency/race-condition tester for cetrafs
// . Runs as either a slave (one per machine that will
// mount the shared device) or a master (drives one or more slaves through
// a named scenario and judges the result). See docs/LOCKING.md for the
// cross-node mechanisms these scenarios exercise, and this package's own
// files for per-scenario rationale.
//
// Each slave is told WHICH device it owns (-device) and decides for
// itself where to mount it (-mountpoint, default /mnt/ctest); the master
// never dictates a path, it asks (slave_info) and drives mount/unmount.
//
// The full-suite scenario begins by reformatting the device (mkfs-guard),
// so a run starts from a pristine volume rather than inheriting previous
// runs' ZG ownership and leftover files. Individual scenarios still
// tolerate pre-existing state, so running one on its own does not
// reformat anything.
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func main() {
	mode := flag.String("mode", "", "slave | master")

	// slave flags
	addr := flag.String("addr", ":9100", "slave: address to listen on")
	// The slave owns BOTH of these. The master used to send the
	// mountpoint over the wire, which meant a slave could be driven to
	// mount somewhere other than where it was configured -- and when
	// the two disagreed, scenarios wrote to the host filesystem through
	// a mountpoint that was just an ordinary directory.
	slaveDevice := flag.String("device", "/dev/sda", "slave: the shared block device this node mounts")
	slaveMount := flag.String("mountpoint", "/mnt/ctest",
		"slave: where this node mounts the device (created if it does not exist)")
	mkfsPath := flag.String("mkfs", "", "slave: path to mkfs.cetra, needed by the mkfs-guard scenario "+
		"(default: ../userspace/mkfs.cetra relative to this binary, if present)")

	// master flags
	slaveList := flag.String("slaves", "",
		"master: comma-separated name=host:port list, e.g. nodeA=127.0.0.1:9100,nodeB=10.0.0.2:9100")
	localSlave := flag.String("local-slave", "",
		"master: also start a slave listening on this address, in-process -- include it in -slaves too "+
			"(e.g. -local-slave=:9100 -slaves=local=127.0.0.1:9100,remote=10.0.0.2:9100) to run a slave on "+
			"the same machine as the master")
	scenario := flag.String("scenario", "", "lock-race | lock-sequential | lock-hold | explicit-lock | lock-suspend | cluster-lock-mode | nocaw-mount-race | symlink-publish | zg-fairness | diag | module-info | xattrs | "+
		"cross-node-visibility | concurrent-create | concurrent-unlink | concurrent-mkdir | concurrent-mkdir-storm | concurrent-rename | "+
		"read-presence | inode-reuse | dirent-cache | extent-leaf-staleness | record-write-race | "+
		"dirent-torn | caw | pending-free | scrub-transit | hypervisor-storm | space-accounting | dir-storm | sparse-bigfile | "+
		"ns-fuzz | mkfs-guard | full-suite")
	lockPath := flag.String("lock-path", "ctest-lockfile", "path (relative to mountpoint) used by the lock-* scenarios")
	// "" (the default) means "pick a fresh, timestamped directory for
	// this run" -- see below. Pass an explicit value to reuse a fixed
	// path across runs (e.g. to inspect leftover state by hand).
	testDir := flag.String("test-dir", "", "directory (relative to mountpoint) scratch space for the "+
		"cross-node-visibility/concurrent-*/full-suite scenarios (default: a fresh ctest-suite-<timestamp> "+
		"per run, so one run's leftover state -- especially a failed run's -- never contaminates the next)")
	accountingSizeMB := flag.Int("accounting-size-mb", 1, "space-accounting/full-suite: size (MiB) of the file "+
		"written then unlinked while checking statfs free-space accounting on both nodes")
	// 80, not the 200 this started at. The scenario's cost is almost
	// entirely the per-file metadata round trips (~24 of
	// them, ~1s per file on the real LUN), so the runtime is linear in
	// the COUNT and barely moves with the size -- 200 files made this
	// scenario 65% of the whole suite's wall clock. What the count has
	// to buy is the shared directory growing past its 4 inline extents
	// into a depth-1 external leaf, which 80 files clears comfortably
	// (82 entries at 15 per block = 6 blocks) and which the scenario now
	// ASSERTS rather than assumes, so this number can be tuned without
	// silently losing the coverage it exists for.
	dirStormFiles := flag.Int("dirstorm-files", 80, "dir-storm/full-suite: how many files the two nodes "+
		"write into one shared directory (split 50/50 between them, so the default is 40 each). Must stay "+
		"above ~62 or the directory never spills past its inline extents and the scenario asserts so.")
	dirStormMaxKB := flag.Int("dirstorm-max-kb", 128, "dir-storm/full-suite: maximum per-file size in KiB; "+
		"each file's size is random in [1 byte, this], so the run spans single-byte files and multi-block "+
		"ones in the same directory. Bigger values cost little time (writeback merges them) but a lot of "+
		"space; the extent-mapping coverage comes from the spread, not the maximum.")
	dirStormPar := flag.Int("par", 8, "how many concurrent connections each node drives in dir-storm and caw. "+
		"A connection carries one request at a time, so this is what makes a node concurrent with ITSELF -- "+
		"where same-node races live -- and what divides the wall clock, since a metadata operation on a real "+
		"LUN costs about a second. 1 restores the old one-at-a-time behaviour.")
	dirStormSeed := flag.Int64("dirstorm-seed", 1, "dir-storm/full-suite: PRNG seed for the random file sizes "+
		"(fixed by default so a failure reproduces exactly; change it to explore other size mixes)")
	dialTimeout := flag.Duration("dial-timeout", 5*time.Second, "master: per-slave connection timeout")
	dmesgLines := flag.Int("dmesg-lines", 100, "master: diag scenario -- how many trailing dmesg lines per slave")
	stormMins := flag.Int("storm-minutes", 6, "hypervisor-storm: how long to run the concurrent load "+
		"(minimum 1; the point is sustained overlap, so short runs prove little)")
	visRounds := flag.Int("visibility-rounds", 40, "create-visibility: how many mkdir/create/see rounds")
	stormSeed := flag.Int64("storm-seed", 1, "hypervisor-storm: PRNG seed, so a failing run reproduces")
	stormNoFileLock := flag.Bool("storm-nofilelock", false, "hypervisor-storm: mount every node -o nofilelock -- "+
		"the VM-image deployment mode, where no whole-file lock exists and freshness is gated on open-presence.")
	nsFuzzOps := flag.Int("nsfuzz-ops", 2500, "ns-fuzz: random namespace ops PER NODE (crank it, or -repeat, for a soak)")
	nsFuzzSeed := flag.Int64("nsfuzz-seed", 1, "ns-fuzz: PRNG seed, so a failing run reproduces")
	nsFuzzPool := flag.Int("nsfuzz-pool", 160, "ns-fuzz: size of the shared name pool in the one arena directory")
	nsFuzzOpset := flag.String("nsfuzz-opset", "", "ns-fuzz: comma list restricting ops (e.g. create,link) to triage a failure; empty = all")
	stormInject := flag.Bool("storm-inject", true, "hypervisor-storm: pull a node's device periodically. "+
		"Set false to separate faults that need a device failure from faults that do not -- the storm's "+
		"cross-node visibility failures are all reported by the node whose device gets pulled, which is "+
		"either a cause or a coincidence, and this is how you tell.")
	repeat := flag.Int("repeat", 1, "master: run the selected scenario this many times -- a two-node soak. "+
		"The dir-storm seed is advanced each pass so the random file sizes differ; stops at the first failure.")

	flag.Parse()

	effectiveTestDir := *testDir
	if effectiveTestDir == "" {
		effectiveTestDir = fmt.Sprintf("ctest-suite-%d", time.Now().Unix())
	}

	switch *mode {
	case "slave":
		if err := runSlave(*addr, *slaveDevice, *slaveMount, resolveMkfsPath(*mkfsPath)); err != nil {
			log.Fatal(err)
		}
	case "master":
		// -device and -mountpoint belong to the SLAVE, and the master
		// deliberately cannot dictate either (see protocol.go: a slave
		// told to mount somewhere other than where it was configured
		// once put 50 MB of a suite run on the host root filesystem).
		// Accepting them here silently and ignoring them is its own
		// trap -- an operator passing -mountpoint to the master has a
		// specific path in mind and gets a run against a different one.
		// Refuse, and say where the flag goes.
		{
			var misplaced []string
			flag.Visit(func(f *flag.Flag) {
				switch f.Name {
				case "mountpoint", "device", "mkfs", "addr":
					misplaced = append(misplaced, "-"+f.Name+"="+f.Value.String())
				}
			})
			if len(misplaced) > 0 {
				fmt.Fprintf(os.Stderr,
					"these are SLAVE flags and the master cannot apply them: %s\n\n"+
						"Each slave owns where it mounts, so that a scenario cannot be driven to\n"+
						"write outside the filesystem under test. Pass them when starting the slave:\n"+
						"    ctest -mode=slave -addr=:9100 -device=<dev> -mountpoint=<path>\n\n"+
						"The master then drives whatever each slave was configured with, and prints\n"+
						"it per node at the start of the run.\n",
					strings.Join(misplaced, " "))
				os.Exit(2)
			}
		}

		ok, err := runMaster(masterConfig{
			slaveList:           *slaveList,
			localSlave:          *localSlave,
			localSlaveDevice:    *slaveDevice,
			localSlaveMount:     *slaveMount,
			localSlaveMkfs:      *mkfsPath,
			scenario:            *scenario,
			lockPath:            *lockPath,
			testDir:             effectiveTestDir,
			accountingSizeBytes: *accountingSizeMB * 1024 * 1024,
			dirStormFiles:       *dirStormFiles,
			dirStormMaxBytes:    *dirStormMaxKB * 1024,
			dirStormPar:         *dirStormPar,
			dirStormSeed:        *dirStormSeed,
			dialTimeout:         *dialTimeout,
			dmesgLines:          *dmesgLines,
			repeat:              *repeat,
			stormDur:            time.Duration(*stormMins) * time.Minute,
			stormSeed:           *stormSeed,
			nsFuzzOps:           *nsFuzzOps,
			nsFuzzSeed:          *nsFuzzSeed,
			nsFuzzPool:          *nsFuzzPool,
			nsFuzzOpset:         *nsFuzzOpset,
			stormInject:         *stormInject,
			stormNoFileLock:     *stormNoFileLock,
			visRounds:           *visRounds,
		})
		if err != nil {
			log.Fatal(err)
		}
		if !ok {
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "usage:")
		fmt.Fprintln(os.Stderr, "  ctest -mode=slave -addr=:9100 -device=/dev/sda [-mountpoint=/mnt/ctest]")
		fmt.Fprintln(os.Stderr, "  ctest -mode=master -slaves=name=host:port,... [-local-slave=:port] \\")
		fmt.Fprintln(os.Stderr, "        -scenario=lock-race|zg-fairness|mkfs-guard|full-suite")
		os.Exit(2)
	}
}

type masterConfig struct {
	slaveList           string
	localSlave          string
	localSlaveDevice    string
	localSlaveMount     string
	localSlaveMkfs      string
	scenario            string
	lockPath            string
	testDir             string
	accountingSizeBytes int
	dirStormFiles       int
	dirStormMaxBytes    int
	dirStormPar         int
	dirStormSeed        int64
	dialTimeout         time.Duration
	dmesgLines          int
	repeat              int
	stormDur            time.Duration
	stormSeed           int64
	stormInject         bool
	stormNoFileLock     bool
	visRounds           int
	nsFuzzOps           int
	nsFuzzSeed          int64
	nsFuzzPool          int
	nsFuzzOpset         string
}

func runMaster(cfg masterConfig) (bool, error) {
	// Wall clock for the entire run, printed last (from the defer
	// below) so it survives every exit path -- a scenario failure, the
	// build-alignment gate refusing to start, a panic -- and so it lands
	// AFTER the cleanup unmount rather than being buried above it.
	runStart := time.Now()
	if cfg.localSlave != "" {
		go func() {
			if err := runSlave(cfg.localSlave, cfg.localSlaveDevice, cfg.localSlaveMount,
				resolveMkfsPath(cfg.localSlaveMkfs)); err != nil {
				log.Printf("local slave on %s exited: %v", cfg.localSlave, err)
			}
		}()
		// Give the local slave a moment to bind before we try to dial it
		// below -- it's one of the addresses in -slaves like any other.
		time.Sleep(200 * time.Millisecond)
	}

	clients, err := dialAll(cfg.slaveList, cfg.dialTimeout)
	if err != nil {
		return false, err
	}
	// Unmount on EVERY exit path, not just the ones a scenario thought
	// to handle: a normal finish, a scenario returning an error, the
	// build-alignment gate refusing to start, a panic, or the operator
	// pressing Ctrl-C mid-run. Leaving a shared LUN mounted by a run
	// that is no longer happening is how a later investigation ends up
	// chasing a node that looks alive but is not.
	//
	// Individual scenarios still unmount as they finish; doUnmount is a
	// no-op when nothing is mounted, so this is pure belt and braces.
	unmountAll := func(why string) {
		if err := ensureUnmounted(clients); err != nil {
			fmt.Printf("(cleanup after %s) unmount: %v\n", why, err)
		}
	}
	defer func() {
		if r := recover(); r != nil {
			unmountAll("panic")
			for _, c := range clients {
				_ = c.Close()
			}
			fmt.Printf("\ntotal elapsed: %s (panicked)\n", fmtDur(time.Since(runStart)))
			panic(r)
		}
		unmountAll("exit")
		for _, c := range clients {
			_ = c.Close()
		}
		fmt.Printf("\ntotal elapsed: %s\n", fmtDur(time.Since(runStart)))
	}()

	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigc
		fmt.Printf("\nmaster: got %s -- unmounting every slave before exiting\n", sig)
		unmountAll(sig.String())
		for _, c := range clients {
			_ = c.Close()
		}
		// os.Exit skips every defer, so the total is printed here too.
		fmt.Printf("\ntotal elapsed: %s (interrupted)\n", fmtDur(time.Since(runStart)))
		os.Exit(1)
	}()
	if len(clients) == 0 {
		return false, fmt.Errorf("no slaves given (-slaves=name=host:port,...)")
	}

	// Ask every slave what it is actually configured to use, rather than
	// telling it. Two things fall out of this that the old
	// master-dictates-the-path arrangement could not check at all:
	// the run prints the real device/mountpoint per node, and slaves
	// that are NOT sharing one device are refused up front instead of
	// producing a suite that passes because the nodes never met.
	var sharedDev string
	for _, c := range clients {
		var info SlaveInfoResult
		resp, err := c.Call("slave_info", struct{}{})
		if err := decodeResult(c.Name, resp, err, &info); err != nil {
			return false, fmt.Errorf("%s: slave_info: %w (an old slave build?)", c.Name, err)
		}
		c.Device, c.MountPoint = info.Device, info.MountPoint
		fmt.Printf("slave %-8s %-22s device=%s mountpoint=%s mounted=%v\n",
			c.Name, c.Addr, info.Device, info.MountPoint, info.Mounted)

		// A mount of the shared device at some path OTHER than the
		// slave's own is invisible to every mount check in ctest and
		// survives every unmount it issues -- but mkfs.cetra sees it by
		// device number and refuses, and any scenario that formats or
		// assumes an idle device is then testing something other than
		// what it says. Refuse up front, naming the path, instead of
		// reporting the environment as a filesystem failure. (A real
		// `make test` leftover at /root/cetrafs/test is what prompted
		// this: mkfs-guard printed "mkfs failed on an unmounted
		// device" when the device was in fact mounted.)
		//
		// Not unmounted automatically: ctest does not own paths the
		// operator mounted for other reasons.
		for _, mp := range info.DeviceMountedAt {
			if filepath.Clean(mp) == filepath.Clean(info.MountPoint) {
				continue
			}
			return false, fmt.Errorf("%s: %s is also mounted on %s, outside this slave's own mountpoint (%s) -- "+
				"ctest cannot see or unmount it, and mkfs will refuse while it is there; unmount it first",
				c.Name, info.Device, mp, info.MountPoint)
		}
		if sharedDev == "" {
			sharedDev = info.Device
		} else if info.Device != sharedDev {
			return false, fmt.Errorf("slaves disagree about the shared device (%s vs %s) -- "+
				"they would not be testing the same filesystem", sharedDev, info.Device)
		}
	}

	// Build alignment is a precondition for every scenario that makes a
	// cross-node claim. diag and module-info are exempt on purpose:
	// those are the tools you reach for to find out WHY the builds
	// differ, so refusing to run them on a mismatched cluster would
	// take away the diagnosis along with the problem.
	switch cfg.scenario {
	case "diag", "module-info":
	default:
		if err := requireSameModuleBuild(clients); err != nil {
			if uerr := ensureUnmounted(clients); uerr != nil {
				fmt.Printf("(cleanup) unmount: %v\n", uerr)
			}
			return false, err
		}
	}

	switch cfg.scenario {
	case "cross-node-visibility", "xattrs", "concurrent-create", "concurrent-unlink", "concurrent-mkdir", "concurrent-mkdir-storm",
		"concurrent-rename", "read-presence", "inode-reuse", "link-stale-reuse", "inode-unique", "dirent-cache", "extent-leaf-staleness",
		"record-write-race", "dirent-torn", "caw", "pending-free", "scrub-transit", "hypervisor-storm", "ns-fuzz",
		"create-visibility",
		"fence-reclaim", "replay-race",
		"space-accounting",
		"sparse-bigfile",
		"full-suite":
		fmt.Printf("(using test-dir %q)\n", cfg.testDir)
	}

	// -repeat turns any scenario into a soak: run it N times, advancing the
	// dir-storm seed each pass so a seeded scenario varies its workload, and
	// stop at the first failure (continuing to hammer a cluster that just
	// failed a consistency check is not informative, and may be unsafe).
	reps := cfg.repeat
	if reps < 1 {
		reps = 1
	}
	for i := 0; i < reps; i++ {
		c := cfg
		c.dirStormSeed = cfg.dirStormSeed + int64(i)
		if reps > 1 {
			fmt.Printf("\n===== soak pass %d/%d (scenario=%s seed=%d) =====\n", i+1, reps, cfg.scenario, c.dirStormSeed)
		}
		ok, err := dispatchScenario(c, clients)
		var skipped skipErr
		if errors.As(err, &skipped) {
			// A precondition the scenario could not meet. Not a failure
			// -- but it tested nothing, and skipScenario has already
			// said so on stdout, so do not dress it up as a pass either.
			fmt.Printf("===== %s: SKIPPED (%s) =====\n", cfg.scenario, skipped.reason)
			return true, nil
		}
		if err != nil {
			return false, err
		}
		if !ok {
			if reps > 1 {
				fmt.Printf("===== soak FAILED on pass %d/%d =====\n", i+1, reps)
			}
			return false, nil
		}
	}
	return true, nil
}

func dispatchScenario(cfg masterConfig, clients []*Client) (bool, error) {
	switch cfg.scenario {
	case "lock-race":
		return RunLockRace(clients, cfg.lockPath)
	case "lock-sequential":
		return RunLockSequential(clients, cfg.lockPath)
	case "lock-hold":
		return RunLockHold(clients, cfg.lockPath)
	case "explicit-lock":
		return RunExplicitLock(clients, cfg.lockPath)
	case "lock-suspend":
		return RunLockSuspend(clients, cfg.lockPath)
	case "cluster-lock-mode":
		return RunClusterLockMode(clients)
	case "nocaw-mount-race":
		return RunNoCawMountRace(clients, 5)
	case "symlink-publish":
		return RunSymlinkPublish(clients, cfg.testDir)
	case "zg-fairness":
		return RunZGFairness(clients)
	case "diag":
		return RunDiag(clients, cfg.dmesgLines)
	case "module-info":
		return RunModuleInfo(clients)
	case "cross-node-visibility":
		return RunCrossNodeVisibility(clients, cfg.testDir)
	case "xattrs":
		return RunXattrs(clients, cfg.testDir)
	case "concurrent-create":
		return RunConcurrentCreate(clients, cfg.testDir+"/concurrent-create-file")
	case "concurrent-unlink":
		return RunConcurrentUnlink(clients, cfg.testDir+"/concurrent-unlink-file")
	case "concurrent-mkdir":
		return RunConcurrentMkdir(clients, cfg.testDir+"/concurrent-mkdir-dir")
	case "concurrent-mkdir-storm":
		return RunConcurrentMkdirStorm(clients, cfg.testDir)
	case "concurrent-rename":
		return RunConcurrentRename(clients, cfg.testDir)
	case "read-presence":
		return RunReadPresence(clients, cfg.testDir)
	case "fence-reclaim":
		return RunFenceReclaim(clients, cfg.testDir)
	case "replay-race":
		return RunReplayRace(clients, cfg.testDir)
	case "inode-reuse":
		return RunInodeReuse(clients, cfg.testDir)
	case "link-stale-reuse":
		return RunLinkStaleReuse(clients, cfg.testDir)
	case "inode-unique":
		return RunInodeUnique(clients, cfg.testDir)
	case "dirent-cache":
		return RunDirentCache(clients, cfg.testDir, cfg.dirStormPar)
	case "extent-leaf-staleness":
		return RunExtentLeafStaleness(clients, cfg.testDir)
	case "record-write-race":
		return RunRecordWriteRace(clients, cfg.testDir)
	case "dirent-torn":
		return RunDirentTorn(clients, cfg.testDir, cfg.dirStormPar)
	case "caw":
		return RunCAW(clients, cfg.testDir, cfg.dirStormPar)
	case "pending-free":
		return RunPendingFree(clients, cfg.testDir)
	case "create-visibility":
		return RunCreateVisibility(clients, cfg.testDir, cfg.visRounds)
	case "hypervisor-storm":
		return RunHypervisorStorm(clients, cfg.testDir, cfg.stormDur, cfg.stormSeed, cfg.stormInject, cfg.stormNoFileLock)
	case "scrub-transit":
		return RunScrubTransit(clients, cfg.testDir)
	case "space-accounting":
		return RunSpaceAccounting(clients, cfg.testDir, cfg.accountingSizeBytes)
	case "dir-storm":
		return RunDirStorm(clients, cfg.testDir,
			cfg.dirStormFiles, cfg.dirStormMaxBytes, cfg.dirStormPar, cfg.dirStormSeed)
	case "sparse-bigfile":
		return RunSparseBigFile(clients, cfg.testDir+"/sparse-bigfile")
	case "mkfs-guard":
		return RunMkfsGuard(clients)
	case "ns-fuzz":
		return RunNsFuzz(clients, cfg.testDir, cfg.nsFuzzSeed, cfg.nsFuzzOps, cfg.nsFuzzPool, cfg.nsFuzzOpset)
	case "full-suite":
		return RunFullSuite(clients, cfg.lockPath, cfg.testDir, cfg.accountingSizeBytes,
			cfg.dirStormFiles, cfg.dirStormMaxBytes, cfg.dirStormPar, cfg.dirStormSeed)
	case "release-suite":
		return RunReleaseSuite(clients, cfg)
	default:
		return false, fmt.Errorf("unknown -scenario %q (see -help for the full list)", cfg.scenario)
	}
}

func dialAll(slaveList string, timeout time.Duration) ([]*Client, error) {
	var clients []*Client
	for _, spec := range strings.Split(slaveList, ",") {
		spec = strings.TrimSpace(spec)
		if spec == "" {
			continue
		}
		parts := strings.SplitN(spec, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("bad -slaves entry %q, want name=host:port", spec)
		}
		c, err := dialClient(parts[0], parts[1], timeout)
		if err != nil {
			return nil, err
		}
		clients = append(clients, c)
	}
	return clients, nil
}

// resolveMkfsPath defaults to the mkfs.cetra that sits next to this
// checkout (ctest lives in the same repo), so the common case needs no
// flag at all; an explicit -mkfs always wins.
func resolveMkfsPath(explicit string) string {
	if explicit != "" {
		return explicit
	}
	// A checkout's own build first -- a ctest run is normally testing
	// what is in that tree, not what happens to be installed.
	if exe, err := os.Executable(); err == nil {
		cand := filepath.Join(filepath.Dir(exe), "..", "userspace", "mkfs.cetra")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	// Then an installed one (the cetrafs-tools package). Without this a
	// node that has cetrafs installed but no built checkout reported
	// "slave was started without -mkfs", which reads like a missing flag
	// rather than what it is -- and it only fails on the SECOND node, in
	// the middle of a suite, because the first node happened to have a
	// checkout.
	for _, cand := range []string{"/usr/sbin/mkfs.cetra", "/usr/local/sbin/mkfs.cetra", "/sbin/mkfs.cetra"} {
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	return ""
}

// fmtDur prints a duration at a resolution a human reads at a glance:
// sub-minute runs in seconds with one decimal, longer ones as m+s. The
// raw Duration.String() ("1m32.439182736s") is precise and unreadable.
func fmtDur(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%.1fs", d.Seconds())
	}
	d = d.Round(time.Second)
	return fmt.Sprintf("%dm%02ds", int(d/time.Minute), int((d%time.Minute)/time.Second))
}
