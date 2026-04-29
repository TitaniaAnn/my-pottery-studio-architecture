/// v11 — Tags and note-tag join.
///
/// Adds many-to-many tagging to notes. Three new tables in one migration
/// because they're meaningless apart: a tag with no notes is dead data,
/// and a join row with no tag or note is invalid by definition.
const List<String> v11 = [
  '''CREATE TABLE IF NOT EXISTS tags (
    id        TEXT PRIMARY KEY,
    name      TEXT NOT NULL UNIQUE,
    color     TEXT,
    userId    TEXT,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    deletedAt TEXT
  )''',

  '''CREATE TABLE IF NOT EXISTS note_tags (
    id        TEXT PRIMARY KEY,
    noteId    TEXT NOT NULL,
    tagId     TEXT NOT NULL,
    createdAt TEXT NOT NULL,
    FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
    FOREIGN KEY (tagId)  REFERENCES tags  (id) ON DELETE CASCADE
  )''',

  'CREATE INDEX IF NOT EXISTS idx_note_tags_note ON note_tags(noteId)',
  'CREATE INDEX IF NOT EXISTS idx_note_tags_tag  ON note_tags(tagId)',
];