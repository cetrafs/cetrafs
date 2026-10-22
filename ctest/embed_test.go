// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The embedded sources are what lets a node with NO cetrafs checkout run
// the device_read scenarios -- the case that failed mid-suite on a real
// three-node cluster. It cannot be exercised through the slave on a
// machine that HAS a checkout (repoRoot finds it and is preferred, as it
// should be: a run normally tests the tree in front of you), so it is
// tested here directly.
//
// This also guards the Makefile step: a binary built without `make -C
// ctest embed` has an empty embedded/ and this fails rather than
// surfacing on a node at 2am.
func TestEmbeddedHelperBuilds(t *testing.T) {
	if _, err := exec.LookPath("cc"); err != nil {
		t.Skip("no C compiler")
	}
	for _, name := range []string{"node_poke", "zg_poke", "pending_poke", "inode_lock_poke"} {
		bin, err := buildEmbeddedHelper(name)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if _, err := os.Stat(bin); err != nil {
			t.Fatalf("%s: built but missing: %v", name, err)
		}
		// Built from the REAL sources, so it must behave like the real
		// helper: run with no arguments and it prints its usage.
		out, _ := exec.Command(bin).CombinedOutput()
		if !strings.Contains(string(out), "usage") {
			t.Fatalf("%s: does not look like the real helper: %q", name, string(out))
		}
	}
}
