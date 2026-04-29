/// v31 — Sync foundation.
///
/// This is the migration where the universal-columns convention from v01
/// (UUID primary keys, ISO 8601 timestamps, nullable userId) earns its
/// keep. None of the existing tables need to be migrated — every row
/// already has the metadata a sync layer needs to detect changes,
/// resolve conflicts, and replicate state to peers.
///
/// What this migration adds is the *new* infrastructure sync needs that
/// the existing tables don't already cover:
///
///   1. A registry of paired peer devices, so the app remembers who it
///      syncs with across restarts.
///   2. A tombstone table for hard-deletes, so peers can replicate
///      deletions on rows that don't have a deletedAt column to read.
///   3. A staging area for conflicts that can't be auto-resolved, so
///      the user can pick which version wins on next sync.
///
/// The fact that this migration adds zero columns to existing user-data
/// tables is the architecture's central bet paying off: the schema was
/// shaped for sync from v01, so adding sync only required new tables.
const List<String> v31 = [
  // Paired devices registry — one row per trusted peer.
  // Pairing survives restarts because it's stored as data, not held
  // as ephemeral connection state in memory.
  '''CREATE TABLE IF NOT EXISTS sync_trusted_devices (
    id           TEXT PRIMARY KEY,
    displayName  TEXT NOT NULL,
    platform     TEXT NOT NULL,
    pairedAt     TEXT NOT NULL,
    lastSeenAt   TEXT,
    lastSyncedAt TEXT
  )''',

  // Tombstones for tables that don't carry a deletedAt column.
  // Most user-data tables soft-delete via deletedAt and can be synced
  // by reading that column directly; some tables (mostly join tables)
  // hard-delete rows. For those, this log lets peers learn about the
  // deletion after the fact.
  '''CREATE TABLE IF NOT EXISTS sync_hard_delete_log (
    id        TEXT PRIMARY KEY,
    tableName TEXT NOT NULL,
    rowId     TEXT NOT NULL,
    deletedAt TEXT NOT NULL,
    pushedAt  TEXT
  )''',
  'CREATE INDEX IF NOT EXISTS idx_sdl ON sync_hard_delete_log(tableName, rowId)',

  // Conflict staging — when local and remote both edited the same row
  // since the last sync, the conflict is recorded here for manual
  // resolution rather than being silently auto-resolved.
  '''CREATE TABLE IF NOT EXISTS sync_conflicts (
    id           TEXT PRIMARY KEY,
    tableName    TEXT NOT NULL,
    rowId        TEXT NOT NULL,
    localJson    TEXT NOT NULL,
    remoteJson   TEXT NOT NULL,
    remoteDevice TEXT NOT NULL,
    detectedAt   TEXT NOT NULL,
    resolvedAt   TEXT
  )''',

  // Track originating device for media files. Enables lazy download
  // on peers — the row replicates immediately, but the binary stays
  // on the originating device until another peer requests it.
  'ALTER TABLE notes ADD COLUMN syncSourceDevice TEXT',
];