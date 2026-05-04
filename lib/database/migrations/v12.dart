/// v12 — Notes v2: rich metadata, archival state, and pinning.
///
/// Demonstrates the "one ALTER TABLE per column" pattern SQLite requires.
/// Each ALTER is its own statement so that a partial failure mid-migration
/// leaves the database in a recoverable state — every prior ALTER has
/// already committed by the time the next one runs.
///
/// Note on defaults: NOT NULL columns added to a table with existing rows
/// must have a DEFAULT, otherwise the ALTER fails on populated databases.
/// Nullable columns can be added without one.
const List<String> v12 = [
  // ── notes — new v2 columns (one ALTER TABLE per column) ───────────
  "ALTER TABLE notes ADD COLUMN status     TEXT NOT NULL DEFAULT 'active'",
  'ALTER TABLE notes ADD COLUMN pinned     INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE notes ADD COLUMN pinnedAt   TEXT',
  'ALTER TABLE notes ADD COLUMN archivedAt TEXT',
  'ALTER TABLE notes ADD COLUMN wordCount  INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE notes ADD COLUMN lastViewedAt TEXT',
  'ALTER TABLE notes ADD COLUMN sortOrder  INTEGER NOT NULL DEFAULT 0',
];