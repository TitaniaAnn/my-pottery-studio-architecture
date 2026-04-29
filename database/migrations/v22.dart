/// v22 — Backfill `color` column on `tags` for databases that had the
/// table from v11 (before v15's CREATE TABLE IF NOT EXISTS was a no-op
/// and never ran the ALTER TABLE that v15 assumed had been applied).
///
/// This is the kind of migration you only write after seeing it in the
/// wild: an early install upgrades through v11 → v15 and ends up with a
/// tags table missing a column that fresh installs got for free.
/// Re-issuing the ALTER as its own version makes the upgrade path
/// idempotent regardless of which historical state the database is in.
const v22 = [
  // Safe to run even on databases where the column already exists,
  // provided the migration runner catches "duplicate column" errors
  // for ALTER TABLE ADD COLUMN. See DatabaseService.runMigration.
  'ALTER TABLE tags ADD COLUMN color TEXT',
];