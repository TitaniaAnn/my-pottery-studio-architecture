/// v36 — Make the hard-delete tombstone log self-deduplicating.
///
/// `sync_hard_delete_log` was created in v31 with `id TEXT PRIMARY KEY`
/// and a non-unique index on `(tableName, rowId)`. Both the DAO writes
/// and the sync inbound path generate a fresh random `id` per insert,
/// so an `INSERT OR IGNORE` on the random PK never trips and duplicates
/// accumulate on every sync round. Replacing the index with a UNIQUE
/// one makes `INSERT OR IGNORE` actually do its job — repeat tombstones
/// for the same `(tableName, rowId)` are silently dropped.
///
/// Order matters here:
///   1. Dedupe existing rows (idempotent — no-op on a fresh DB).
///   2. Drop the non-unique index from v31.
///   3. Create the UNIQUE index.
///
/// The dedupe DELETE keeps the lowest `_rowid_` per group, which
/// preserves the earliest tombstone's `pushedAt` state. Losing one
/// would silently drop a deletion from the next outbound delta — an
/// invariant violation a sync runtime can't recover from after the
/// fact.
///
/// We use `_rowid_` (not `rowid`) because the table has a user column
/// called `rowId` and SQLite identifiers are case-insensitive — the
/// user column would shadow the implicit name and the DELETE would
/// silently no-op.
///
/// This migration is the second piece of evidence in the file for
/// v31's design holding up under real use: v31 set up the sync
/// schema; v36 hardens one of its tables without touching any of
/// the user-data tables. Both shipped without a single row of
/// existing-table backfill.
const List<String> v36 = [
  // 1. Dedupe before adding the unique constraint.
  '''DELETE FROM sync_hard_delete_log
     WHERE _rowid_ NOT IN (
       SELECT MIN(_rowid_) FROM sync_hard_delete_log
       GROUP BY tableName, rowId
     )''',

  // 2. Drop the v31 non-unique index.
  'DROP INDEX IF EXISTS idx_sdl',

  // 3. Replace it with a UNIQUE one — same columns, but enforces the
  //    invariant that each `(tableName, rowId)` is logged at most once.
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_sdl_unique '
      'ON sync_hard_delete_log(tableName, rowId)',
];
