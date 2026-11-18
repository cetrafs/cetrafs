// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// A slave runs as root, mounts and formats the shared LUN, writes
// anywhere its ops point, and can take a link down. It used to do all of
// that for anybody who could reach its port -- on every interface, with
// no credential (audit 2026-11-15 B-27). Every request now carries an
// HMAC under a key both ends read from a root-only file, bound to a
// nonce the slave sent for this connection and to a request id that only
// grows, so a frame can neither be forged nor replayed. A frame that
// fails is answered by closing the connection, never by running it.

// DefaultKeyPath is where both ends look for the shared key.
const DefaultKeyPath = "/etc/cetrafs/ctest.key"

// ctestKey is the shared key, loaded once by main before any slave
// listens or any client dials.
var ctestKey []byte

// Hello is the first frame on every connection, slave to master.
type Hello struct {
	Nonce string `json:"nonce"`
}

// loadKey reads the shared key and refuses one that others can read:
// a key in a world-readable file authenticates nobody.
func loadKey(path string) ([]byte, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("ctest key %s: %w -- create it on every node with the SAME contents: "+
			"install -m 600 /dev/null %s && head -c 32 /dev/urandom >%s, then copy it", path, err, path, path)
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("ctest key %s is not a regular file", path)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("ctest key %s is readable by others (mode %o) -- chmod 600 it", path, fi.Mode().Perm())
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Geteuid() {
		return nil, fmt.Errorf("ctest key %s is owned by uid %d, not by this user (%d)", path, st.Uid, os.Geteuid())
	}
	key, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("ctest key %s: %w", path, err)
	}
	if len(key) < 16 {
		return nil, fmt.Errorf("ctest key %s holds %d bytes; it needs at least 16", path, len(key))
	}
	return key, nil
}

func newNonce() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// frameMAC authenticates one request on the connection whose nonce is
// given: every field the slave acts on is covered.
func frameMAC(key []byte, nonce string, id uint64, op string, args []byte) string {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(nonce))
	m.Write([]byte{0})
	m.Write([]byte(strconv.FormatUint(id, 10)))
	m.Write([]byte{0})
	m.Write([]byte(op))
	m.Write([]byte{0})
	m.Write(args)
	return hex.EncodeToString(m.Sum(nil))
}

func frameOK(key []byte, nonce string, r Request) bool {
	want := frameMAC(key, nonce, r.ID, r.Op, r.Args)
	return hmac.Equal([]byte(want), []byte(r.Mac))
}

// checkListenAddr refuses an address with no host: ":9100" listens on
// every interface, the hypervisor's public ones included. Name the
// interface the master reaches (the storage or test network), or
// 127.0.0.1 for a slave in the master's own process.
func checkListenAddr(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("slave address %q: %w", addr, err)
	}
	if host == "" {
		return fmt.Errorf("slave address %q names no host, which listens on every interface -- "+
			"give the address the master reaches it on (e.g. 10.0.0.1:9100)", addr)
	}
	return nil
}

// joinUnder resolves relPath inside mp and refuses anything that leaves
// it: "..", an absolute path, or a symlink on the way that points out.
// A missing final component is fine (a create); its parent must exist.
func joinUnder(mp, relPath string) (string, error) {
	if !filepath.IsLocal(relPath) {
		return "", fmt.Errorf("path %q leaves the mountpoint", relPath)
	}
	root, err := filepath.EvalSymlinks(mp)
	if err != nil {
		return "", err
	}
	p := filepath.Join(root, relPath)
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		if isSymlinkLoop(err) {
			return p, nil // resolves nowhere: the op itself gets ELOOP
		}
		if !os.IsNotExist(err) {
			return "", err
		}
		dir, derr := filepath.EvalSymlinks(filepath.Dir(p))
		if derr != nil {
			if os.IsNotExist(derr) || isSymlinkLoop(derr) {
				return p, nil // the op itself reports the missing parent, or the loop
			}
			return "", derr
		}
		real = filepath.Join(dir, filepath.Base(p))
	}
	if real != root && !strings.HasPrefix(real, root+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q resolves to %s, outside the mountpoint", relPath, real)
	}
	return p, nil
}

// isSymlinkLoop: EvalSymlinks gave up on a cycle of symlinks. Such a
// path resolves nowhere -- not outside the mount either -- and the
// kernel answers the op ELOOP. ns-fuzz's symlinks among its pool names
// make cycles; refusing them here failed those ops with no errno at all.
// filepath has no sentinel for it, only this message.
func isSymlinkLoop(err error) bool {
	return err != nil && strings.HasSuffix(err.Error(), "too many links")
}

// safeArg admits the flags and numbers mkfs and insmod are given by the
// scenarios -- no paths, no shell metacharacters.
func safeArg(a string) bool {
	if a == "" || strings.ContainsAny(a, "/\\") {
		return false
	}
	for _, c := range a {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case strings.ContainsRune("-_=,.:+", c):
		default:
			return false
		}
	}
	return true
}
