/// v01 — Initial schema.
///
/// Establishes the baseline conventions every later table follows:
/// * UUID primary keys (TEXT) — no auto-increment, no merge collisions
///   across devices in a future sync world.
/// * ISO 8601 timestamps stored as TEXT (createdAt, updatedAt).
/// * Soft-delete via deletedAt, never hard-deleted at the row level.
/// * Nullable userId column on every user-owned row, so adding a
///   backend later requires no schema migration.
const List<String> v01 = [
  '''CREATE TABLE IF NOT EXISTS notes (
    id        TEXT PRIMARY KEY,
    title     TEXT NOT NULL,
    body      TEXT NOT NULL DEFAULT '',
    userId    TEXT,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    deletedAt TEXT
  )''',
];