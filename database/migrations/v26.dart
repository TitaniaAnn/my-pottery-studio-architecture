/// v26 — User-customizable categories.
///
/// Replaces the hardcoded NoteCategory enum with a DB-driven categories
/// table. The three built-in categories are seeded with IDs that match
/// the existing `category` TEXT values on notes, so no data migration
/// is needed for existing rows — every note's category string already
/// resolves to a valid categories.id after this migration runs.
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
  // IDs deliberately match the existing notes.category TEXT values so
  // that all existing notes automatically resolve to the correct row.

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