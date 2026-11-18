// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// startTestSlave serves a Slave on loopback with a fresh key and
// returns its address. Nothing is mounted: ping is the only op these
// tests need answered.
func startTestSlave(t *testing.T) string {
	t.Helper()
	ctestKey = []byte("0123456789abcdef0123456789abcdef")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	s := &Slave{device: "/nonexistent", mountPoint: t.TempDir()}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handleConn(c)
		}
	}()
	return ln.Addr().String()
}

// rawFrame dials, takes the hello, sends one request with the given MAC
// and reports whether ANY response came back.
func rawFrame(t *testing.T, addr string, id uint64, mac func(nonce string) string, again bool) (answered int) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fc := newFrameConn(conn)
	h, err := fc.readHello()
	if err != nil {
		t.Fatalf("no hello: %v", err)
	}
	args, _ := json.Marshal(struct{}{})
	req := Request{ID: id, Op: "ping", Args: args, Mac: mac(h.Nonce)}
	n := 1
	if again {
		n = 2
	}
	for i := 0; i < n; i++ {
		if err := fc.writeRequest(req); err != nil {
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(time.Second))
		if _, err := fc.readResponse(); err != nil {
			return
		}
		answered++
	}
	return
}

func TestSlaveAnswersOnlyAuthenticatedFrames(t *testing.T) {
	addr := startTestSlave(t)
	args, _ := json.Marshal(struct{}{})

	c, err := dialClient("t", addr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if resp, err := c.Call("ping", struct{}{}); err != nil || !resp.OK {
		t.Fatalf("an authenticated ping failed: %v %+v", err, resp)
	}

	good := func(nonce string) string { return frameMAC(ctestKey, nonce, 1, "ping", args) }
	if got := rawFrame(t, addr, 1, good, false); got != 1 {
		t.Fatalf("setup: a correctly signed raw frame got %d answers, want 1", got)
	}
	none := func(string) string { return "" }
	if got := rawFrame(t, addr, 1, none, false); got != 0 {
		t.Fatalf("a frame with no MAC was answered")
	}
	wrongKey := func(nonce string) string { return frameMAC([]byte("not-the-key-at-all!!"), nonce, 1, "ping", args) }
	if got := rawFrame(t, addr, 1, wrongKey, false); got != 0 {
		t.Fatalf("a frame signed with another key was answered")
	}
	otherNonce := func(string) string { return frameMAC(ctestKey, "00", 1, "ping", args) }
	if got := rawFrame(t, addr, 1, otherNonce, false); got != 0 {
		t.Fatalf("a frame signed for another connection's nonce was answered")
	}
	if got := rawFrame(t, addr, 1, good, true); got != 1 {
		t.Fatalf("a replayed frame (same id) was answered: %d answers, want 1", got)
	}
}

func TestJoinUnderStaysInside(t *testing.T) {
	mp := t.TempDir()
	outside := t.TempDir()
	if err := os.Mkdir(filepath.Join(mp, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(mp, "escape")); err != nil {
		t.Fatal(err)
	}
	// A cycle of symlinks resolves nowhere: let through, the op gets
	// ELOOP from the kernel (ns-fuzz makes them among its pool names).
	if err := os.Symlink("loopb", filepath.Join(mp, "loopa")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("loopa", filepath.Join(mp, "loopb")); err != nil {
		t.Fatal(err)
	}
	for _, ok := range []string{"f", "d/f", "d", "missing/f", "loopa", "loopa/f"} {
		if _, err := joinUnder(mp, ok); err != nil {
			t.Errorf("joinUnder(%q) refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"../x", "d/../../x", "/etc/passwd", "escape/x", "escape", ""} {
		if p, err := joinUnder(mp, bad); err == nil {
			t.Errorf("joinUnder(%q) = %s, want a refusal", bad, p)
		}
	}
}

func TestListenAddrAndArgs(t *testing.T) {
	if checkListenAddr(":9100") == nil {
		t.Error(":9100 (every interface) was accepted")
	}
	if err := checkListenAddr("127.0.0.1:9100"); err != nil {
		t.Errorf("127.0.0.1:9100 refused: %v", err)
	}
	for _, ok := range []string{"-z", "4", "-f", "node_uuid=ab-cd", "hb_tick_stall_ms=500"} {
		if !safeArg(ok) {
			t.Errorf("safeArg(%q) = false", ok)
		}
	}
	for _, bad := range []string{"", "/dev/sda", "-o;rm", "caw_probe=/dev/sdb", "a b", "$(x)"} {
		if safeArg(bad) {
			t.Errorf("safeArg(%q) = true", bad)
		}
	}
}
