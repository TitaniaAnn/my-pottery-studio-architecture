/// v12 — Notes v2: rich metadata, archival state, and pinning.
///
/// Demonstrates the "one ALTER TABLE per column" pattern SQLite requires:
/// ALTER TABLE ADD COLUMN adds exactly one column per statement.
///
/// Keeping each ALTER in its own string also matters to the runner. Its
/// idempotency catch works per statement, so on a database that already
/// has some of these columns, each duplicate-column error is swallowed
/// on its own and the remaining ALTERs still run.
///
/// It does NOT mean earlier ALTERs survive a later failure. sqflite runs
/// the whole upgrade in one transaction, so if any statement fails, every
/// statement in the upgrade rolls back and the next open retries from the
/// old version (see test/migration_transaction_test.dart).
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