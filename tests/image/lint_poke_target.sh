#!/usr/bin/env bash
# a poke must be written through whatever the thing that reads it reads
#
# A loop device and its backing file are the same bytes through two
# independent page caches, and which one a poke should go through
# depends entirely on WHO IS GOING TO READ IT. There is no blanket
# answer, and assuming there was one nearly broke twenty suites.
#
#   fsck reads the DEVICE          -> poke the DEVICE
#   a mounted kernel, simulating
#   a PEER's write                 -> poke the FILE, deliberately
#
# The second is not a mistake to be fixed. Poking the file is exactly
# how a change is made invisible to a mounted node until it re-reads,
# which is the only way to simulate a peer on a one-node harness --
# every "did it read fresh?" suite depends on it. Writing the DEVICE
# instead puts the change straight into the page cache the
# filesystem's own buffers are mapped onto, so the node sees it without
# re-reading at all, and an assertion of the form "it re-read and saw
# the peer's change" passes while testing nothing.
#
# What IS a mistake is a MISMATCH: poking the file where fsck, reading
# the device, is the one that has to see it. kernel/fsck_repair.sh had
# that -- fsck's own earlier reads left pages cached on the device, the
# poke landed behind them, and fsck checked the volume as it was before
# the fault was injected. The assertion that a non-repairable fault
# stops the repair then failed with no bug anywhere near fsck, and only
# under a full batch, because whether those pages were still resident
# depended on what every other suite had done first.
#
# So this lint flags exactly that shape and nothing else: an image poke
# with fsck reading the device on both sides of it and no flush
# between.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
CT_NEED_MODULE=0

POKE_RE='POKE[A-Z_0-9]*\}?" +"\$\{?(IMG|IMAGE|IMGFILE)'

offenders=""
scanned=0
for f in "$CT_TESTS"/kernel/*.sh "$CT_TESTS"/image/*.sh; do
    [ -f "$f" ] || continue
    grep -qE "$POKE_RE" "$f" || continue
    scanned=$((scanned + 1))
    grep -q 'flushbufs' "$f" && continue
    first="$(grep -nE "$POKE_RE" "$f" | head -1 | cut -d: -f1)"
    before="$(awk -v L="$first" 'NR<L && /ct_fsck/' "$f" | head -1)"
    after="$(awk -v L="$first" 'NR>L && /ct_fsck/' "$f" | head -1)"
    [ -n "$before" ] && [ -n "$after" ] && offenders="$offenders $(basename "$f")"
done

[ "$scanned" -gt 10 ] && pass "scanned $scanned suites that poke a backing file" ||
    fail "only $scanned suites matched -- the pattern has drifted and this lint now checks nothing"

[ -z "$offenders" ] &&
    pass "no suite pokes the backing file where fsck, reading the device, must see it" ||
    fail "fsck reads the device on both sides of a backing-file poke in:$offenders"

# Prove the pattern still matches the shape it exists to find.
probe="$(ct_tmp lintprobe)"
cat > "$probe" <<'PROBE'
ct_fsck "$DEV" >/dev/null
"$POKE" "$IMG" nlink 1 0
ct_fsck "$DEV" >/dev/null
PROBE
pfirst="$(grep -nE "$POKE_RE" "$probe" | head -1 | cut -d: -f1)"
pb="$(awk -v L="$pfirst" 'NR<L && /ct_fsck/' "$probe" | head -1)"
pa="$(awk -v L="$pfirst" 'NR>L && /ct_fsck/' "$probe" | head -1)"
[ -n "$pfirst" ] && [ -n "$pb" ] && [ -n "$pa" ] &&
    pass "the lint still recognises a fresh instance of the shape" ||
    fail "the lint no longer matches its own probe -- it would pass over a real offender"

ct_exit
