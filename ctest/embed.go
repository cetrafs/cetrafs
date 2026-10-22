// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"bytes"
	"embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The test helpers are compiled from C so they reuse the real on-disk
// structs in include/cetrafs.h -- that is the whole point of them, and
// why a Go reimplementation would be a second source of truth waiting to
// drift. But compiling them meant every node needed a cetrafs checkout,
// which on a real cluster is a deployment burden: a node running an
// installed ctest binary failed mid-suite with "no cetrafs checkout on
// this node", and no amount of path-guessing fixes a tree that is not
// there.
//
// So the binary carries the sources. `make -C ctest build` copies them
// into embedded/ first (go:embed cannot reach outside the package
// directory), and the slave writes them to a temp dir and builds there.
// Nothing but a C compiler is needed on a node.
//
// embedded/ is generated, not committed -- a committed copy of
// cetrafs.h is exactly the kind of duplication that drifts from the
// format it describes. A binary built without the Makefile step simply
// has none, and says so at the point of use.
//
//go:embed all:embedded
var embeddedHelpers embed.FS

// buildEmbeddedHelper writes the embedded sources for one helper into a
// cache dir and compiles it, returning the binary's path.
func buildEmbeddedHelper(name string) (string, error) {
	dir := filepath.Join(os.TempDir(), "ctest-helpers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	want := map[string]string{
		name + ".c": "embedded/" + name + ".c",
		"cetrafs.h": "embedded/cetrafs.h",
		"crc32c.h":  "embedded/crc32c.h",
	}
	// fsck and mkfs are the userspace TOOLS, carried for the same reason
	// as the pokes: a node running an installed ctest has no cetrafs
	// checkout, and until now that meant no fsck on most of the fleet --
	// so a scenario could not check the volume from the node it was
	// standing on, and mkfs-guard could not run at all. They need one
	// extra header the pokes do not.
	if name == "fsck" || name == "mkfs" {
		want["devutil.h"] = "embedded/devutil.h"
	}
	for out, src := range want {
		body, err := embeddedHelpers.ReadFile(src)
		if err != nil {
			return "", fmt.Errorf("this ctest binary has no embedded %s (build it with "+
				"`make -C ctest build`, which copies the sources into ctest/embedded/): %w",
				filepath.Base(src), err)
		}
		if err := os.WriteFile(filepath.Join(dir, out), body, 0o644); err != nil {
			return "", err
		}
	}

	bin := filepath.Join(dir, name)
	cc := exec.Command("cc", "-D_FILE_OFFSET_BITS=64", "-I", dir, "-O2", "-std=gnu99",
		"-o", bin, filepath.Join(dir, name+".c"))
	var e bytes.Buffer
	cc.Stderr = &e
	if err := cc.Run(); err != nil {
		return "", fmt.Errorf("building embedded %s: %w: %s", name, err, strings.TrimSpace(e.String()))
	}
	return bin, nil
}
