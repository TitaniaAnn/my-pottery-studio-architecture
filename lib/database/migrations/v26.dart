/// v26 — User-customizable categories.
///
/// Replaces a hardcoded NoteCategory enum with a DB-driven categories
/// table. The three built-in rows are seeded with IDs equal to the enum's
/// persisted string names ('personal', 'work', 'reference'), so any row
/// that stored one of those strings resolves to a valid categories.id
/// with no data migration.
///
/// In this published cut, no migration creates a `category` column on
/// `notes`: the toy domain keeps only the table and its seeds. The point
/// on display is the seeding trick, which only works because the enum
/// was persisted by name rather than by `.index` (see ARCHITECTURE.md §1
/// and BuiltInStage.dbName for the same rule).
///
/// This is the architectural pivot that makes the workflow engine
/// configurable: stages, transitions, and now categories all live as
/// data the user can edit, rather than as code the user can't touch.
const List<String> v26 = [
  '''CREATE TABLE IF NOT EXISTS categories (
    id        TEXT PRIMARY KEY,
    name      TEXT NOT NULL,
    icon      TEXT NOT NULL,
    color     TEXT,
    isBuiltIn INTEGER NOT NULL DEFAULT 0,
    sortOrder INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
  )''',

  // ── Seed the three built-in categories ────────────────────────────
  // IDs deliberately match the enum's persisted string names, so rows
  // that stored those strings resolve to the correct category row.

  '''INSERT OR IGNORE INTO categories (id,name,icon,color,isBuiltIn,sortOrder,createdAt,updatedAt) VALUES (
    'personal','Personal','📔','#6B7FD7',
    1,0,datetime('now'),datetime('now')
  )''',

  '''INSERT OR IGNORE INTO categories (id,name,icon,color,isBuiltIn,sortOrder,createdAt,updatedAt) VALUES (
    'work','Work','💼','#7FB069',
    1,1,datetime('now'),datetime('now')
  )''',

  '''INSERT OR IGNORE INTO categories (id,name,icon,color,isBuiltIn,sortOrder,createdAt,updatedAt) VALUES (
    'reference','Reference','🔖','#D9805C',
    1,2,datetime('now'),datetime('now')
  )''',
];