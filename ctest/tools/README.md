# Trace-driven hunt tooling

Companions to the kernel's `CETRAFS_TRACE=1` instrumentation (see
kmod/kmod.h, `ctrace()`): build the module with tracing, stream each
node's dmesg to a file, run the storm, and feed the streams to these.

- `storm_hunt.sh` -- the reproduce-until-caught loop: per-iteration
  module reload with binary-verified probes, verified unmount before
  mkfs (NEVER mkfs over a live mount), SAN path restore, live
  corruption stop, and a pluggable post-iteration detector. Stops at
  the first hit and freezes the LUN as evidence.
- `trace_premature_free.py` -- replays ADDNAME/REMNAME/RETGT/INOFREE
  and flags any inode freed while names still reference it.
- `trace_cas_chain.py` -- replays IBCAS images and flags multi-bit
  writes and backward jumps in the inode bitmap's CAS history.
- `observe_sector.sh` -- independent O_DIRECT poll of one sector: the
  device-truth timeline kernel claims are checked against.
- `jreplay_guard.sh` -- two-node proof of the journal replay guard:
  kills the remote node mid-write with sysrq-b under `nofilelock`, lets
  the survivor take the file over, and asserts what the stale-reclaim
  replay does to it. Three required modes -- `corrupt` (guard off, the
  bug MUST reproduce), `intact` (peer's newer write survives), `repair`
  (a genuine lost write is still redone).
- `stale_tree_cache.sh` -- two-node proof that a survivor sees a peer's
  committed extent tree without a remount. A writes and closes, A is
  killed, B must agree with a cold mount. `FSI=1` sets file_seq_ignore
  for the negative control, which MUST come back STALE.
- `caw_duel.sh` / `caw_duel_rawpath.sh` -- two-node COMPARE AND WRITE
  atomicity contest on a raw sector, via dm or explicit paths. Proves
  (or indicts) the array primitive with no filesystem involved.

Hard-won rules encoded here: a guard that refuses everything looks
exactly like a guard that works, so every "it held" assertion needs a
companion proving the thing still HAPPENS when it should; verify probes
in the BINARY on every node before trusting a run; cross-node log correlation suggests, only
same-node arithmetic or device truth confirms; stop at the first hit --
the next mkfs destroys the evidence.
