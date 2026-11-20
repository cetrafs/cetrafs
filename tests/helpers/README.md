# tests/helpers

Small C tools that read or corrupt a cetrafs image directly.  Every one
reuses `include/cetrafs.h` and `userspace/crc32c.h` rather than
hand-deriving on-disk offsets, so a format change breaks the helper at
compile time instead of silently making it poke the wrong bytes.

None of them is part of the normal build.  Suites get one with
`ct_helper <name>`, which compiles it into `tests/.build/` and rebuilds
only when the source or the format header is newer.

| helper | what it touches | modes |
|---|---|---|
| `zg_poke` | a Zone Group's `owner_node_id`, checksum recomputed; `stamp` prints hb_seq, pool shard and G-6 stamp | set owner |
| `bg_poke` | a Block Group's cached `free_data_blocks` | fake "this BG is full" without writing hundreds of MiB |
| `node_poke` | a Node Registry row: state / `hb_seq` / `last_seen` / uuid / `fence_epoch` | write a row, `--beat`, `--beat-keep-time`, `--bump-fence` |
| `inode_lock_poke` | an inode's `lock_owner_node` / `lock_mode`, and dumps `ns_owner` / `readers` | read-only dump (safe while mounted) or write |
| `inode_block_poke` | a whole inode record | probe a packed-block clobber, `retype` a record (new mode + generation + valid checksum) |
| `leaf_poke` | a depth-1 file's external extent leaf | `setphys`, `setblock` (an entry's logical start, restamped: an alias on purpose), `show`, `growlen` |
| `pending_poke` | a ZG's pending-free queue | `add`, `dump`, and `extent <ino>` (prints an inode's first extent, so a test can learn a real LBA) |
| `journal_poke` | a node's journal area | write a valid entry, force the clean flag back to MUST-SCAN |
| `corrupt_poke` | arbitrary structures, for fsck's negative controls | per-field corruption |
| `bmap_poke` | one bit of a bitmap (inode or data), its sector's CRC restamped | read, set/clear, `raw` (leave the CRC stale: a fault), `count`/`clear0` over a run. The only way a suite reaches a bitmap bit -- bit N is not at byte N/8 (cetrafs.h `CETRAFS_BMAP_SECTOR`) |
| `fsx_cetra` | one file, a seeded stream of data ops against an in-memory model | `kernel/fsx_model.sh`; `FSX_NEGATIVE` corrupts the model on purpose |
| `fsstress_cetra` | several processes, a seeded namespace stream, per-process model, shared-directory errno contract | `kernel/fsstress_namespace.sh`; `FSSTRESS_NEGATIVE` corrupts the model |

**Poke while unmounted** unless the helper's own header says otherwise.
Writing behind a live mount races the kernel's buffer cache, and a read
of a block the kernel has dirty will not show what you wrote.  The
read-only dump modes are safe mounted because the kernel's writes to
those fields go through `sync_dirty_buffer()`.
