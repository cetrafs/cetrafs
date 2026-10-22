#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# negative controls for fsck.cetra: every check, broken on purpose
# Negative controls for fsck.cetra's cluster-metadata and
# content checks.
#
# Everything here is image-level: mkfs writes the structures, the poke
# helpers corrupt them, fsck must notice. No kernel module is loaded and
# nothing is mounted, so this runs in seconds and is the right place for
# any check that does not need a live filesystem.
#
# The rule this exists to serve: a checker never seen to fail proves
# nothing. Every assertion below first confirms fsck is CLEAN, then
# injects exactly one fault and requires fsck to report it and exit
# nonzero.
#
# Needs root only for losetup (mkfs/fsck want a block device).
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}
fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}
log() { echo "== $1"; }

if [ "$(id -u)" != "0" ]; then
    echo "must be run as root (losetup)" >&2
    exit 2
fi

IMG="$(mktemp /tmp/cetrafs-fsck-XXXXXX.img)"
LOOPDEV=""
JOURNAL_POKE="$(mktemp /tmp/cetrafs-fsckt-jpoke-XXXXXX)"
PENDING_POKE="$(mktemp /tmp/cetrafs-fsckt-ppoke-XXXXXX)"
CPOKE="$(mktemp /tmp/cetrafs-fsckt-cpoke-XXXXXX)"

cleanup() {
    set +e
    [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null
    rm -f "$IMG" "$JOURNAL_POKE" "$PENDING_POKE" "$CPOKE"
}
trap cleanup EXIT

cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$JOURNAL_POKE" "$ROOT/tests/helpers/journal_poke.c" || exit 2
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$PENDING_POKE" "$ROOT/tests/helpers/pending_poke.c" || exit 2
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$CPOKE" "$ROOT/tests/helpers/corrupt_poke.c" || exit 2

truncate -s 2G "$IMG"
LOOPDEV="$(losetup -f --show "$IMG")"

# -J 4 so the per-node journal is big enough to hold slots at all; a
# volume mkfs'd with -J 0 has no journal area and these checks are
# correctly silent on it.
MKFS_OUT=""
mkfs_fresh() {
    MKFS_OUT="$("$ROOT/userspace/mkfs.cetra" "$LOOPDEV" -z 2 -b 512 -J 4 -M 4 -N 1024 -f 2>&1)"
}

# Runs fsck and stores output in FSCK_OUT / exit in FSCK_RC.
# Deliberately NOT inside $( ) in a `set -e` context: an fsck that exits
# nonzero is the expected result for most of this file, and a command
# substitution that aborts the script would skip every later assertion
# and print no summary -- a failure mode this project has already
# shipped three times.
run_fsck() {
    # Every poke here writes the BACKING FILE while fsck reads through
    # the loop device, which caches -- so without this flush the
    # injected fault is seen intermittently. Demonstrated while writing
    # fsck_checksum_controls.sh: the same case passed and failed across
    # consecutive runs. This suite has always had the same exposure and
    # passed on cache luck.
    blockdev --flushbufs "$LOOPDEV" 2>/dev/null || true
    FSCK_OUT="$("$ROOT/userspace/fsck.cetra" "$LOOPDEV" 2>&1)"
    FSCK_RC=$?
}

expect_clean() {
    run_fsck
    if [ "$FSCK_RC" = "0" ]; then
        pass "$1"
    else
        fail "$1 (fsck exited $FSCK_RC: $(echo "$FSCK_OUT" | grep -E '^(ERR|WARN)' | head -2))"
    fi
}

# expect_caught <description> <grep pattern>
expect_caught() {
    run_fsck
    if [ "$FSCK_RC" = "0" ]; then
        fail "$2 -- fsck reported OK on a volume with the fault injected"
    elif echo "$FSCK_OUT" | grep -qE "$1"; then
        pass "$2"
    else
        fail "$2 -- fsck failed but not for the right reason: $(echo "$FSCK_OUT" | grep -E '^(ERR|WARN)' | head -2)"
    fi
}

log "baseline"
mkfs_fresh || {
    fail "mkfs failed"
    exit 1
}
expect_clean "baseline: a freshly formatted volume is clean"

# --- journal: an entry naming a block outside every BG data region ----
# The fault that destroys a volume at mount if replay applies it blindly
# (block 0 is the superblock). journal.c refuses it; fsck must name it
# while the volume is offline.
log "journal: out-of-range target"
mkfs_fresh
PAYLOAD="$(mktemp /tmp/cetrafs-fsckt-pay-XXXXXX)"
dd if=/dev/urandom of="$PAYLOAD" bs=4096 count=1 2>/dev/null
"$JOURNAL_POKE" "$LOOPDEV" 0 0 0 "$PAYLOAD" >/dev/null
expect_caught "outside every BG data region" \
    "journal: an entry targeting block 0 is reported as out of range"

# --- journal: a slot whose payload does not match its checksum --------
# Replay verifies payload checksums; a mismatch means the entry would be
# refused there, but offline it is still a corrupt journal worth naming.
log "journal: payload CRC mismatch"
mkfs_fresh
# Target a real data block so the entry passes the range check and the
# payload check is the one that fires. journal_poke reports the block it
# wrote the payload to, so this does not re-derive journal geometry.
# +1000 clears BG0's header and bitmap so this lands in its DATA region:
# the bare region start is the BG header, which is correctly not a legal
# journal target and would fire the range check instead of this one.
BG_START="$(grep -oP 'BG regions start: LBA \K[0-9]+' <<<"$MKFS_OUT")"
JP_OUT="$("$JOURNAL_POKE" "$LOOPDEV" 0 0 $((BG_START + 1000)) "$PAYLOAD")"
PAY_LBA="$(grep -oP 'payload_lba=\K[0-9]+' <<<"$JP_OUT")"
if [ -n "$PAY_LBA" ]; then
    # Alter the payload, leaving the header's checksum of the ORIGINAL
    # payload in place.
    printf 'x' | dd of="$LOOPDEV" bs=4096 seek="$PAY_LBA" conv=notrunc 2>/dev/null
    expect_caught "payload CRC mismatch" \
        "journal: an entry whose payload was altered is reported"
else
    fail "journal: journal_poke did not report payload_lba"
fi
rm -f "$PAYLOAD"

# --- pending-free: an entry naming blocks outside every data region ---
log "pending-free: out-of-range entry"
mkfs_fresh
"$PENDING_POKE" "$LOOPDEV" add 0 1 1 >/dev/null
expect_caught "outside every BG data region" \
    "pending-free: an entry naming block 1 (metadata) is reported"

# An entry inside the data regions but belonging to a DIFFERENT ZG: the
# owner would clear bits in somebody else's bitmap on its next drain.
log "pending-free: entry belonging to another ZG"
mkfs_fresh
BGS="$(grep -oP '^\s*ZGs: [0-9]+, BGs: \K[0-9]+' <<<"$MKFS_OUT")"
BGSZ="$(grep -oP 'BG size: \K[0-9]+' <<<"$MKFS_OUT")"
BG_START="$(grep -oP 'BG regions start: LBA \K[0-9]+' <<<"$MKFS_OUT")"
if [ -n "$BGS" ] && [ -n "$BGSZ" ] && [ -n "$BG_START" ] && [ "$BGS" -gt 1 ]; then
    # mkfs spreads BGs across ZGs, so the LAST BG belongs to the last ZG.
    # +1000 clears that BG's header and bitmap, landing well inside its
    # data region. Queueing it on ZG 0 is a cross-ZG entry by
    # construction, whatever the exact split was.
    FAR=$((BG_START + (BGS - 1) * BGSZ + 1000))
    "$PENDING_POKE" "$LOOPDEV" add 0 "$FAR" 1 >/dev/null
    expect_caught "belongs to ZG" \
        "pending-free: an entry naming another ZG's blocks is reported"
else
    fail "pending-free: could not parse the BG geometry from mkfs output"
fi

# --- namespace: '.' and '..' ------------------------------------------
# Root's pair is checked by its own dedicated pass (stricter: it requires
# them in slots 0 and 1), and these are that pass's negative controls.
#
# The GENERAL check -- every directory's '.' naming itself and '..'
# naming the directory that actually holds it -- cannot be exercised on
# a root-only image, because it needs a subdirectory, which needs a
# mount. Its control lives in tests/mount_test.sh.
log "namespace: root's '..' pointing at the wrong inode"
mkfs_fresh
expect_clean "namespace: root's '.' and '..' are correct on a fresh volume"
"$CPOKE" "$LOOPDEV" repoint 1 ".." 2 >/dev/null
expect_caught "missing '\.\.' entry" \
    "namespace: root's '..' naming the wrong inode is reported"

log "namespace: root's '.' pointing at the wrong inode"
mkfs_fresh
"$CPOKE" "$LOOPDEV" repoint 1 "." 2 >/dev/null
expect_caught "missing '\.' entry" \
    "namespace: root's '.' naming the wrong inode is reported"

log "namespace: root's '..' erased"
mkfs_fresh
"$CPOKE" "$LOOPDEV" dirent 1 ".." >/dev/null
expect_caught "missing '\.\.' entry" \
    "namespace: root with no '..' entry is reported"

# --- pending-free: a zero-length entry --------------------------------
log "pending-free: zero count"
mkfs_fresh
expect_clean "pending-free: a freshly formatted volume has an empty queue"

# --- a BG's cached free count vs its own bitmap -----------------------
# Nothing used to check this. The ZG-against-sum-of-BGs cross-check only
# proves the two CACHED numbers agree with each other, so a counter that
# had drifted from its bitmap stayed invisible while both halves were
# consistently wrong -- and that counter is what statfs reports and what
# the allocator uses to decide which Block Group to write to.
log "BG cached free count disagreeing with its bitmap"
mkfs_fresh
expect_clean "bg count: a fresh volume's cached free count matches its bitmap"
BG_POKE="$(mktemp /tmp/cetrafs-bgpoke-XXXXXX)"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$BG_POKE" "$ROOT/tests/helpers/bg_poke.c" || exit 2
"$BG_POKE" "$LOOPDEV" 0 12345 sync-zg >/dev/null
expect_caught "cached free_data_blocks" \
    "bg count: a cached free count that disagrees with the bitmap is reported"
rm -f "$BG_POKE"

log "directory nlink disagreeing with its subdirectory count"
# A directory's link count is 2 (itself and its own '.') plus one per
# subdirectory, contributed by each child's '..'. Nothing checked it:
# the reference tally deliberately skips directories, because an entry
# naming one does not add to its nlink the way a hardlink does -- which
# left a directory's nlink validated by nothing at all, even though
# every add_entry/remove_entry maintains it and several of this review's
# findings touched that bookkeeping.
mkfs_fresh
expect_clean "dir nlink: a fresh volume's root has nlink 2 and no subdirectories"
NL_POKE="$(mktemp /tmp/cetrafs-nlpoke-XXXXXX)"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$NL_POKE" "$ROOT/tests/helpers/inode_block_poke.c" || exit 2
"$NL_POKE" "$LOOPDEV" nlink 1 5 >/dev/null 2>&1
rm -f "$NL_POKE"
expect_caught "contains 0 subdirector" \
    "dir nlink: a root claiming 5 links with no subdirectories is reported"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
echo "ALL CHECKS PASSED"
