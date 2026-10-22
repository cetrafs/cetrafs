// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// Client is the master's connection to one slave. Not safe for concurrent
// use from multiple goroutines -- one TCP connection, one request in
// flight at a time. Scenarios that need N *concurrent* commands use N
// separate Clients (one per slave), each driven by its own goroutine;
// they never share a Client to get concurrency on a single slave.
type Client struct {
	Name string // scenario-facing label, e.g. "nodeA" -- not a protocol concept
	Addr string

	// Learned from the slave itself at connect time (slave_info), never
	// dictated by the master: the slave owns which device it mounts and
	// where. Scenarios read these when they need to name the device
	// (e.g. the /proc/fs/cetrafs/<dev>/ paths).
	Device     string
	MountPoint string

	conn net.Conn
	fc   *frameConn

	// Serializes a whole request/response round trip. The wire protocol
	// is strictly one-at-a-time per connection, and frameConn locks only
	// its WRITES -- so two goroutines sharing a Client both land in
	// Decoder.Decode on the same decoder and corrupt its internal state.
	// That is not hypothetical: Ctrl-C mid-run sends the signal handler
	// (main.go) into ensureUnmounted on the very clients the scenario
	// goroutine is calling, and the run died with
	// "slice bounds out of range [-61:]" inside consumeWhitespace
	// instead of unmounting cleanly. Scenarios get their concurrency from
	// one Client PER SLAVE (see fireConcurrently), so serializing here
	// costs nothing they rely on.
	callMu sync.Mutex
	seq    atomic.Uint64
}

func dialClient(name, addr string, timeout time.Duration) (*Client, error) {
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, fmt.Errorf("dial %s (%s): %w", name, addr, err)
	}
	return &Client{Name: name, Addr: addr, conn: conn, fc: newFrameConn(conn)}, nil
}

func (c *Client) Close() error {
	return c.conn.Close()
}

// Parallel returns n Clients driving the SAME slave, each safe for one
// goroutine, plus a closer for the extra connections it opened. The
// first element is c itself, so the caller never has to special-case
// it.
//
// A Client is one TCP connection carrying one request at a time, so
// until now the only concurrency a scenario could create was "one
// operation per node at a time" -- which is not how a host uses a
// filesystem, and which made every scenario latency-bound on a real
// LUN, where a single metadata operation costs around a second.
// The slave has always been able to take this: it serves
// every connection in its own goroutine and its handle table is
// process-global, by design.
//
// Both reasons to use it matter. It is the only way to make one node
// genuinely concurrent with ITSELF, which is where same-node races live
// (the buffer-update protocol, the local alloc mutex, the per-inode
// ns mutex) -- and it is what turns a scenario's wall clock from
// files * latency into files * latency / n.
func (c *Client) Parallel(n int, timeout time.Duration) ([]*Client, func(), error) {
	out := []*Client{c}
	var extra []*Client
	closeAll := func() {
		for _, e := range extra {
			_ = e.Close()
		}
	}
	for i := 1; i < n; i++ {
		e, err := dialClient(c.Name, c.Addr, timeout)
		if err != nil {
			closeAll()
			return nil, func() {}, fmt.Errorf("%s: opening connection %d of %d: %w", c.Name, i+1, n, err)
		}
		// Carry the slave's own device/mountpoint across: scenarios read
		// these off whichever Client they happen to hold.
		e.Device, e.MountPoint = c.Device, c.MountPoint
		extra = append(extra, e)
		out = append(out, e)
	}
	return out, closeAll, nil
}

// Call sends one request and blocks for its matching response.
func (c *Client) Call(op string, args any) (Response, error) {
	b, err := json.Marshal(args)
	if err != nil {
		return Response{}, err
	}

	c.callMu.Lock()
	defer c.callMu.Unlock()

	id := c.seq.Add(1)
	if err := c.fc.writeRequest(Request{ID: id, Op: op, Args: b}); err != nil {
		return Response{}, fmt.Errorf("%s: write request: %w", c.Name, err)
	}

	resp, err := c.fc.readResponse()
	if err != nil {
		return Response{}, fmt.Errorf("%s: read response: %w", c.Name, err)
	}
	if resp.ID != id {
		return Response{}, fmt.Errorf("%s: response id mismatch: got %d want %d", c.Name, resp.ID, id)
	}
	return resp, nil
}

// decodeResult is a small helper for scenarios: unmarshal a successful
// Response's Result into the given pointer, or return an error that
// already incorporates the response's own Error string if it wasn't OK.
func decodeResult(name string, resp Response, err error, v any) error {
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if !resp.OK {
		return fmt.Errorf("%s: %s", name, resp.Error)
	}
	if v == nil {
		return nil
	}
	return json.Unmarshal(resp.Result, v)
}
