# cetrafs — Logging

What the module logs, what it deliberately does not, and how to turn the
full trace on when troubleshooting — at runtime, with no rebuild and no
remount.

## Default behavior (production)

Out of the box the module is quiet. Three kinds of lines reach dmesg:

- **Errors** (`pr_err`): something is actually wrong — a checksum that
  stayed wrong after retries, a refused mount, a failed replay, an I/O
  error. Always on.
- **Warnings** (`pr_warn`): recoverable anomalies worth an operator's
  attention — counter drift being corrected, an unsupported feature
  forcing read-only, clock skew between nodes (ratelimited, since a
  skewed cluster would otherwise repeat it every heartbeat). Always on.
- **Lifecycle information** (`pr_info`): once-per-event lines, never
  per-operation. A full mount/unmount cycle is about seven lines:

```
cetrafs: cetrafs module loaded
cetrafs: CAW: class=scsi logical_block_size=512 max_caw_blocks=1 -> atomic CAS available
cetrafs: node registration: re-attached row 1 (hb_seq=46)
cetrafs: ZG claim: own 1 of 9 zone group(s) (atomic CAS)
cetrafs: mounted OK: Z=9, B=9, bg_size=131072 blocks, data@34168, node_id=1
cetrafs: '/dev/sda' mount success
...
cetrafs: node mark-offline: row 0 backdated, now immediately reclaimable by a peer
cetrafs: unmounted
```

  Rare cluster *events* also log at this level: claiming an additional
  Zone Group on demand, releasing a surplus one, revoking a stale peer's
  lease, a journal replay, a `controls` setting changed through procfs.
  The ZG-claim summary appears at mount and whenever a claim or steal
  actually happens — not on every quiet heartbeat tick.

Everything per-operation or per-activity is `pr_debug` and therefore
**off by default**: the operation trace (lookup/create/iget/statfs,
journal transactions), per-close lock timing, per-file auto-defrag
lines, pending-free drain activity, slow-allocation telemetry.

## Turning the trace on (dynamic debug)

The debug sites are compiled in and switched at runtime by the kernel's
dynamic debug facility (`CONFIG_DYNAMIC_DEBUG`, standard on
Debian/Proxmox kernels):

```sh
# everything the module can say
echo 'module cetrafs +p' > /sys/kernel/debug/dynamic_debug/control

# narrower: one source file, or one function
echo 'file dir.c +p'            > /sys/kernel/debug/dynamic_debug/control
echo 'func cetrafs_lookup +p'   > /sys/kernel/debug/dynamic_debug/control

# off again
echo 'module cetrafs -p' > /sys/kernel/debug/dynamic_debug/control

# what is currently enabled / available
grep cetrafs /sys/kernel/debug/dynamic_debug/control
```

Flags add decoration if wanted: `+pfl` prefixes each line with function
and line number. Settings are per-site and cleared automatically when
the module unloads; they do not persist across a reboot (add the
`dyndbg` module option or a boot parameter if that is ever wanted).

On a kernel built **without** `CONFIG_DYNAMIC_DEBUG`, `pr_debug`
compiles out entirely — the same quiet default, but re-enabling the
trace then requires rebuilding the module with `-DDEBUG`.

## Notes for developers

- `fs_debug(info, ...)` maps to `pr_debug()`, so tracing is off unless
  dynamic debug turns it on. New trace lines go through
  `fs_debug`/`pr_debug`. New `pr_info` lines must be **once per event,
  never per operation**: a `pr_info` on a periodic path — the heartbeat
  ticks every 15 s — fills every deployment's dmesg forever, for nothing.
- Every `.c` file defines `pr_fmt` as `"cetrafs: "`, so never hardcode
  the prefix into a message (it doubles), and never omit it in a new
  file (the line becomes invisible to `grep cetrafs`).
- The **test harness enables `module cetrafs +p` for every suite**
  (`require_module` in `tests/lib/harness.sh`), because several suites
  assert on dmesg trace lines ("auto-defrag: ino=", "pending free: ...
  drained"). A new test may therefore grep for `pr_debug` text — but a
  line that production operators are expected to see must be `pr_info`
  lifecycle, not debug.
