package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// RunDamageIncarnation: a damage mark belongs to the FILE, not the number.
//
// A node that finds a file damaged refuses every write to it (EUCLEAN)
// so nothing is freed on a damaged tree. Inode numbers are reused, and
// the node that marked a number never allocates it again when a PEER
// deletes the file and creates another: so the mark carries the
// damaged record's generation, and a new file under the same number
// must be writable here. One node cannot stage that (it never reuses a
// number it has marked); tests/kernel/damage_mark_new_gen.sh covers the
// other direction by editing the image.
//
// A marks file X damaged (defrag_damage_ino, the way a read that found
// damage would; damage_record_off keeps it off the superblock, the
// volume itself is healthy) and must have X's writes refused. B deletes
// X and creates files until one takes X's number. A must then write
// the new file and read back what it wrote.
//
// Negative control (CTEST_DAMAGE_CONTROL=1): damage_mark_any_gen on A,
// a mark keyed by the number alone -- A's write to B's new file must
// then be refused.
func RunDamageIncarnation(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("damage-incarnation needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	control := os.Getenv("CTEST_DAMAGE_CONTROL") != ""
	defer func() {
		for _, kv := range [][2]string{{"defrag_damage_ino", "0"}, {"damage_mark_any_gen", "0"}, {"damage_record_off", "0"}} {
			_ = callOK(a, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]})
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	// Before the mount: the heartbeat must never put this staged damage
	// on the superblock.
	if err := callOK(a, "mod_param", ModParamArgs{Name: "damage_record_off", Value: "1"}); err != nil {
		return false, err
	}
	if control {
		fmt.Printf("  NEGATIVE CONTROL: damage_mark_any_gen=1 on %s\n", a.Name)
		if err := callOK(a, "mod_param", ModParamArgs{Name: "damage_mark_any_gen", Value: "1"}); err != nil {
			return false, err
		}
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	dir := baseDir + "/damage-incarnation"
	fmt.Printf("=== damage-incarnation: %s marks a file damaged, %s reuses its number ===\n", a.Name, b.Name)
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	ok := true
	x := dir + "/x"
	if err := callOK(a, "write", WriteArgs{Path: x, Size: 8192, Stamp: "first"}); err != nil {
		return false, fmt.Errorf("setup write: %w", err)
	}
	st, there, err := statPath(a, x)
	if err != nil || !there {
		return false, fmt.Errorf("setup stat: %v", err)
	}
	ino := st.Ino
	if err := callOK(a, "mod_param", ModParamArgs{Name: "defrag_damage_ino", Value: strconv.FormatUint(ino, 10)}); err != nil {
		return false, err
	}
	_, _ = a.Call("defrag_file", DefragFileArgs{Path: x}) // marks it; the defrag itself may be refused
	resp, err := a.Call("write", WriteArgs{Path: x, Size: 4096, Stamp: "after-damage"})
	refused := err == nil && !resp.OK && strings.Contains(strings.ToLower(resp.Error), "structure needs cleaning")
	if !refused {
		check(&ok, "setup: "+a.Name+" refuses writes to the file it marked", false, fmt.Sprintf("%v / %+v", err, resp))
		return false, nil
	}
	fmt.Printf("  setup: %s marked ino %d damaged and refuses its writes\n", a.Name, ino)

	if err := callOK(b, "unlink", UnlinkArgs{Path: x}); err != nil {
		return false, fmt.Errorf("%s: unlink %s: %w", b.Name, x, err)
	}
	reused := ""
	for i := 0; i < 200 && reused == ""; i++ {
		p := fmt.Sprintf("%s/new%d", dir, i)
		if err := callOK(b, "write", WriteArgs{Path: p, Size: 4096, Stamp: "b"}); err != nil {
			return false, fmt.Errorf("%s: create %s: %w", b.Name, p, err)
		}
		if s, ok2, err := statPath(b, p); err == nil && ok2 && s.Ino == ino {
			reused = p
		}
	}
	if reused == "" {
		check(&ok, "setup: "+b.Name+" reused the number in 200 creates", false, fmt.Sprintf("ino %d", ino))
		return false, nil
	}
	fmt.Printf("  setup: %s created %s with ino %d\n", b.Name, reused, ino)

	resp, err = a.Call("write", WriteArgs{Path: reused, Size: 4096, Stamp: "a-writes-the-new-file"})
	var wr WriteResult
	werr := decodeResult(a.Name, resp, err, &wr)
	if control {
		check(&ok, "control: a mark keyed by the number refuses the new file", werr != nil &&
			strings.Contains(strings.ToLower(werr.Error()), "structure needs cleaning"), fmt.Sprint(werr))
	} else {
		check(&ok, a.Name+" writes the new file under the reused number", werr == nil, fmt.Sprint(werr))
		if werr == nil {
			resp, err = a.Call("read", ReadArgs{Path: reused})
			var rr ReadResult
			if e := decodeResult(a.Name, resp, err, &rr); e != nil {
				check(&ok, "read back", false, e.Error())
			} else {
				check(&ok, "the new file reads back what "+a.Name+" wrote", rr.Checksum == wr.Checksum, "")
			}
		}
	}

	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	resp, e := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	if ok {
		fmt.Printf("PASS: damage-incarnation\n")
	} else {
		fmt.Printf("FAIL: damage-incarnation: see failed checks above\n")
	}
	return ok, nil
}
