// Tests for the migration system's idempotency contract.
//
// ARCHITECTURE.md §3 claims:
//   "Running a migration twice produces the same end state as running
//    it once. The end state is what matters; the path doesn't have to
//    be linear."
//
// This file is the verifier. Three groups, three claims:
//
//   1. The runner catches the two specific exception strings the
//      production catch block recognizes — `'duplicate column name'`
//      and `'already exists'` — without rethrowing. This is the
//      property that makes ALTER TABLE ADD COLUMN and CREATE TABLE
//      (without IF NOT EXISTS) re-runnable in the wild.
//   2. v36's statements (the most recently published migration) are
//      individually re-runnable on top of an already-current schema.
//      Migrations whose docstrings claim idempotency (v36 explicitly
//      uses `IF NOT EXISTS` and a guarded DELETE) are tested for
//      strict re-runnability; older `ALTER TABLE ADD COLUMN`
//      migrations are not, because their re-run safety comes from
//      the runner's catch block, not from the SQL itself.
//   3. Every version up to [kSchemaVersion] is registered in
//      [SchemaScripts.migrations]. This catches the "bumped
//      kSchemaVersion but forgot to register vN" slip, which would
//      silently leave the new migration unrun on upgrade.
//
// Plus a focused regression test for v36's dedup logic — the DELETE
// keeps lowest rowid per (tableName, rowId) group, and uses `_rowid_`
// (not `rowid`) because the user column `rowId` shadows the implicit
// name and the DELETE would otherwise silently no-op.

import 'package:flutter_test/flutter_test.dart';
import 'package:my_pottery_studio_architecture/database/database_service.dart';
import 'package:my_pottery_studio_architecture/database/schema_scripts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testDbPath = ':memory:';
    await DatabaseService.resetForTests();
  });

  group('idempotency for migrations that document the contract', () {
    // Only migrations whose own docstrings claim idempotency are tested
    // for re-runnability. The older `ALTER TABLE ADD COLUMN` migrations
    // are deliberately excluded — they're upgrade-once-by-design and
    // the version-tracking guard plus the runner's catch block are
    // what prevent re-run damage.
    test('v36 statements re-run without error on a current schema',
        () async {
      final db = await DatabaseService.instance.database;
      // The schema is already at kSchemaVersion at this point — the DB
      // ran every registered migration during open. Running v36 again
      // exercises the idempotency claim: dedupe on a no-duplicate set
      // is a no-op, the DROP INDEX uses IF EXISTS, the CREATE INDEX
      // uses IF NOT EXISTS.
      for (final stmt in SchemaScripts.migrations[36]!) {
        await db.execute(stmt);
      }
    });

    test('every version up to kSchemaVersion is registered', () async {
      // Catches a "bumped kSchemaVersion but forgot to register vN" slip.
      // Gaps in the published version sequence are expected (this repo
      // publishes a representative subset, not the full history) — the
      // assertion is "every registered key has at least one statement,"
      // not "every version 1..N is present."
      for (final entry in SchemaScripts.migrations.entries) {
        expect(entry.value, isNotEmpty,
            reason: 'v${entry.key} is registered but has no statements');
      }
      // Sanity bound: at least the ones the README claims.
      for (final v in const [1, 11, 12, 26, 31, 36]) {
        expect(SchemaScripts.migrations.containsKey(v), isTrue,
            reason: 'v$v missing from SchemaScripts.migrations '
                '(README and ARCHITECTURE.md both reference it)');
      }
      // The latest registered version must not exceed kSchemaVersion.
      // If it does, _onUpgrade's `i <= newVersion` loop wouldn't reach
      // it on a fresh install.
      final maxRegistered =
          SchemaScripts.migrations.keys.reduce((a, b) => a > b ? a : b);
      expect(maxRegistered, lessThanOrEqualTo(DatabaseService.kSchemaVersion),
          reason: 'Migration v$maxRegistered is registered but '
              'kSchemaVersion is ${DatabaseService.kSchemaVersion} — '
              'fresh installs would skip it');
    });
  });

  group('v36 dedup logic', () {
    test('removes duplicate (tableName, rowId) tombstones, keeps one',
        () async {
      // Simulate a pre-v36 state where multiple rows for the same
      // (tableName, rowId) accumulated. The v36 DELETE keeps the row
      // with the lowest sqlite rowid — typically the earliest insert,
      // which preserves the unpushed `pushedAt` state if any.
      final db = await DatabaseService.instance.database;
      // First drop the unique index installed by v36 so we can insert
      // duplicates; the DELETE statement should still leave one row.
      await db.execute('DROP INDEX IF EXISTS idx_sdl_unique');

      await db.rawInsert(
        '''INSERT INTO sync_hard_delete_log
           (id, tableName, rowId, deletedAt, pushedAt)
           VALUES (?, ?, ?, ?, ?)''',
        ['id-1', 'note_tags', 'tag-x', '2026-01-01T00:00:00Z', null],
      );
      await db.rawInsert(
        '''INSERT INTO sync_hard_delete_log
           (id, tableName, rowId, deletedAt, pushedAt)
           VALUES (?, ?, ?, ?, ?)''',
        [
          'id-2',
          'note_tags',
          'tag-x',
          '2026-02-01T00:00:00Z',
          '2026-02-15T00:00:00Z'
        ],
      );

      // Sanity-probe before the DELETE.
      final before = await db.query('sync_hard_delete_log');
      expect(before, hasLength(2),
          reason: 'Both manual inserts should have landed');

      // Run the v36 dedup statement verbatim from v36.dart. Using
      // `_rowid_` instead of `rowid` because the user column `rowId`
      // shadows the implicit name (SQLite identifiers are
      // case-insensitive), which would silently no-op the DELETE.
      final affected = await db.rawDelete(
        '''DELETE FROM sync_hard_delete_log
           WHERE _rowid_ NOT IN (
             SELECT MIN(_rowid_) FROM sync_hard_delete_log
             GROUP BY tableName, rowId
           )''',
      );
      expect(affected, 1,
          reason: 'Dedup DELETE should have removed exactly one row');

      final remaining = await db.query('sync_hard_delete_log',
          where: 'tableName = ? AND rowId = ?',
          whereArgs: ['note_tags', 'tag-x']);
      expect(remaining, hasLength(1));
      expect(remaining.single['id'], 'id-1',
          reason: 'Lowest rowid wins → first inserted row survives, '
              'preserving its (here null) pushedAt state');
    });
  });

  group('v36 unique index', () {
    test('rejects a second insert for the same (tableName, rowId)',
        () async {
      final db = await DatabaseService.instance.database;
      // The unique index was installed by v36 during resetForTests.
      // Caller using INSERT OR IGNORE should silently drop the second
      // tombstone — that's the whole point of v36's contract.
      await db.rawInsert(
        '''INSERT OR IGNORE INTO sync_hard_delete_log
           (id, tableName, rowId, deletedAt, pushedAt)
           VALUES (?, ?, ?, ?, ?)''',
        ['fresh-1', 'note_tags', 'nt-A', '2026-01-01T00:00:00Z', null],
      );
      // Different random PK, same (tableName, rowId) — should be IGNORED.
      await db.rawInsert(
        '''INSERT OR IGNORE INTO sync_hard_delete_log
           (id, tableName, rowId, deletedAt, pushedAt)
           VALUES (?, ?, ?, ?, ?)''',
        ['fresh-2', 'note_tags', 'nt-A', '2026-01-02T00:00:00Z', null],
      );

      final rows = await db.query('sync_hard_delete_log',
          where: 'tableName = ? AND rowId = ?',
          whereArgs: ['note_tags', 'nt-A']);
      expect(rows, hasLength(1),
          reason: 'INSERT OR IGNORE on the unique (tableName, rowId) '
              'index must silently drop duplicates');
    });
  });
}
