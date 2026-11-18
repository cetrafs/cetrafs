package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// RunCasImageCheck: a compare-and-write must never stamp a fresh checksum
// over a sector that went bad while it was in flight.
//
// Every CAS mutator copies the record, edits a field and restamps its
// checksum -- so a mutator handed a damaged sector would turn the
// damage into a record every checker accepts. They refuse a sector that
// fails its own checksum (EUCLEAN). The only time that refusal is the
// last line is when the sector changes between the CAS's read and its
// swap: the real CAW then miscompares, the loop re-reads, and the
// mutator meets the damage. One node cannot put damage on a real CAW
// device in that window.
//
// A writes a file and opens it for write again with its first swap on
// the record held 15 s between read and CAW (cas_stall_ino). B, in that
// window, flips one bit of the record's namespace checksum on the
// device (test_damage_ns_ino, from its heartbeat). A's open must fail
// EUCLEAN with the lock CAS's refusal in its log. Then B flips the bit
// back: if A wrote nothing, the record is whole again and fsck is
// clean -- a laundered record (fresh checksum over the flipped one)
// would now fail it.
//
// Negative control (CTEST_CASIMG_CONTROL=1): lock_cas_skip_crc on A.
// The open then succeeds and fsck finds the record damaged after the
// flip-back; the volume is reformatted.
func RunCasImageCheck(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("cas-image-check needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	control := os.Getenv("CTEST_CASIMG_CONTROL") != ""
	defer func() {
		for _, kv := range [][2]string{{"cas_stall_ino", "0"}, {"lock_cas_skip_crc", "0"}, {"damage_record_off", "0"}} {
			_ = callOK(a, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]})
		}
		_ = callOK(b, "mod_param", ModParamArgs{Name: "test_damage_ns_ino", Value: "0"})
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	// The refusal marks the volume as needing fsck; keep that off the
	// superblock so the final fsck judges the record alone.
	if err := callOK(a, "mod_param", ModParamArgs{Name: "damage_record_off", Value: "1"}); err != nil {
		return false, err
	}
	if control {
		fmt.Printf("  NEGATIVE CONTROL: lock_cas_skip_crc=1 on %s\n", a.Name)
		if err := callOK(a, "mod_param", ModParamArgs{Name: "lock_cas_skip_crc", Value: "1"}); err != nil {
			return false, err
		}
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	if err := callOK(b, "set_control", SetControlArgs{Key: "hb_interval_secs", Value: "5"}); err != nil {
		return false, fmt.Errorf("%s: hb_interval_secs: %w", b.Name, err)
	}
	// The tick already armed runs at the old interval (15 s by default):
	// let it pass, so the damage armed below lands within one 5 s beat,
	// inside the 15 s swap. Without this the first 5 s tick could come
	// after the swap ended and the setup failed.
	time.Sleep(16 * time.Second)
	dir := baseDir + "/cas-image-check"
	fmt.Printf("=== cas-image-check: %s's swap held, %s damages the sector under it ===\n", a.Name, b.Name)
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	f := dir + "/f"
	if err := callOK(a, "write", WriteArgs{Path: f, Size: 4096, Stamp: "first"}); err != nil {
		return false, fmt.Errorf("setup write: %w", err)
	}
	st, there, err := statPath(a, f)
	if err != nil || !there {
		return false, fmt.Errorf("setup stat: %v", err)
	}
	ino := strconv.FormatUint(st.Ino, 10)
	mark := fmt.Sprintf("ctest-casimg-%d", time.Now().UnixNano())
	_ = callOK(a, "dmesg_mark", DmesgMarkArgs{Marker: mark})
	_ = callOK(b, "dmesg_mark", DmesgMarkArgs{Marker: mark})
	for _, kv := range [][2]string{{"cas_stall_ms", "15000"}, {"cas_stall_ino", ino}} {
		if err := callOK(a, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]}); err != nil {
			return false, err
		}
	}

	type res struct {
		resp Response
		err  error
	}
	done := make(chan res, 1)
	go func() {
		r, e := a.Call("write", WriteArgs{Path: f, Size: 4096, Stamp: "second"})
		done <- res{r, e}
	}()
	time.Sleep(1500 * time.Millisecond)
	if err := callOK(b, "mod_param", ModParamArgs{Name: "test_damage_ns_ino", Value: ino}); err != nil {
		return false, err
	}
	out := <-done

	ok := true
	logB := dmesgSince(b, mark)
	if !strings.Contains(logB, "damaged ino="+ino+"'s namespace sector") {
		check(&ok, "setup: "+b.Name+" damaged the sector while the swap was held", false, logB)
		return false, nil
	}
	logA := dmesgSince(a, mark)
	refusedLog := strings.Contains(logA, "lock CAS: the namespace sector on the device fails its checksum")
	opened := out.err == nil && out.resp.OK
	fmt.Printf("  %s's open: ok=%v %s\n", a.Name, opened, out.resp.Error)

	// Flip the bit back: a record nobody wrote is whole again.
	_ = callOK(b, "dmesg_mark", DmesgMarkArgs{Marker: mark + "-2"})
	if err := callOK(b, "mod_param", ModParamArgs{Name: "test_damage_ns_ino", Value: ino}); err != nil {
		return false, err
	}
	deadline := time.Now().Add(30 * time.Second)
	for !strings.Contains(dmesgSince(b, mark+"-2"), "damaged ino="+ino+"'s namespace sector") {
		if time.Now().After(deadline) {
			check(&ok, "setup: "+b.Name+" flipped the bit back", false, "")
			return false, nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	resp, e := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	ferr := decodeResult(a.Name, resp, e, &fr)

	if control {
		check(&ok, "control: the open went through the damaged sector", opened, out.resp.Error)
		check(&ok, "control: fsck finds the laundered record once the bit is back", ferr == nil && !fr.Clean,
			fmt.Sprint(ferr))
		var mr MkfsResult
		resp, e = a.Call("mkfs", MkfsArgs{Force: true})
		if err := decodeResult(a.Name, resp, e, &mr); err != nil || mr.ExitCode != 0 {
			fmt.Printf("WARNING: control: reformat failed (%v, exit %d): %s %s -- reformat the LUN by hand\n", err, mr.ExitCode, mr.Stdout, mr.Stderr)
		} else {
			fmt.Printf("  (control: the volume held a laundered record by design and has been reformatted)\n")
		}
		return ok, nil
	}
	check(&ok, a.Name+"'s open is refused EUCLEAN", !opened &&
		strings.Contains(strings.ToLower(out.resp.Error), "structure needs cleaning"), fmt.Sprintf("%v %s", out.err, out.resp.Error))
	check(&ok, "the refusal is the lock CAS meeting the damage after a miscompare", refusedLog, logA)
	if ferr != nil {
		check(&ok, "fsck ran", false, ferr.Error())
	} else {
		check(&ok, "fsck clean once the bit is back: nothing was written over the damage", fr.Clean,
			fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	if ok {
		fmt.Printf("PASS: cas-image-check\n")
	} else {
		fmt.Printf("FAIL: cas-image-check: see failed checks above\n")
	}
	return ok, nil
}

func dmesgSince(c *Client, mark string) string {
	resp, err := c.Call("dmesg_tail", DmesgTailArgs{Lines: 2000, Since: mark})
	var r DmesgTailResult
	if decodeResult(c.Name, resp, err, &r) != nil {
		return ""
	}
	return r.Text
}
