// Tests for the migration system's idempotency contract.
//
// ARCHITECTURE.md §3 claims:
//   "Running a migration twice produces the same end state as running
//    it once. The end state is what matters; the path doesn't have to
//    be linear."
//
// This file is the verifier. Three claims:
//
//   1. The runner catches the two specific exception strings its catch
//      block recognizes — `'duplicate column name'` and `'already
//      exists'` — without rethrowing, and rethrows everything else.
//      The tests drive [DatabaseService.runMigrations] (the loop behind
//      `_onUpgrade`) with scripts that hit each case: re-running v12's
//      ALTER TABLE ADD COLUMNs, re-running a CREATE TABLE and a CREATE
//      INDEX without IF NOT EXISTS, and a statement that fails for an
//      unrelated reason.
//   2. v36's statements (the most recently published migration) are
//      individually re-runnable on top of an already-current schema
//      with no help from the runner: v36 uses `IF NOT EXISTS`,
//      `IF EXISTS` and a DELETE that's a no-op without duplicates.
//   3. `kSchemaVersion` equals the highest registered migration and
//      every registered version has statements. Gaps below the top are
//      expected (this repo publishes a subset), so the check is on the
//      top end: it catches the "bumped kSchemaVersion to NN but forgot
//      to register vNN" slip, which would silently leave vNN unrun.
//
// Plus focused regression tests for v36's dedup DELETE (one survivor
// per (tableName, rowId) group; `_rowid_`, not `rowid`, because the
// user column `rowId` shadows the implicit name and the DELETE would
// otherwise silently no-op) and for its unique index.
//
// What happens when a migration fails partway is a separate question,
// covered in migration_transaction_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:my_pottery_studio_architecture/database/database_service.dart';
import 'package:my_pottery_studio_architecture/database/migrations/v12.dart';
import 'package:my_pottery_studio_architecture/database/schema_scripts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testDbPath = ':memory:';
    await DatabaseService.resetForTests();
  });

  group('§3 runner catch block', () {
    test("re-adding existing columns is caught as 'duplicate column name'",
        () async {
      final db = await DatabaseService.instance.database;
      // The schema is already at kSchemaVersion, so every column v12
      // adds exists. Re-running v12 through the runner hits the
      // duplicate-column error on each ALTER; the catch must swallow
      // all seven.
      await DatabaseService.runMigrations(db, 11, 12,
          migrations: const {12: v12});

      final columns = (await db.rawQuery('PRAGMA table_info(notes)'))
          .map((r) => r['name'])
          .toList();
      expect(columns.where((c) => c == 'pinned'), hasLength(1));
    });

    test("re-creating existing objects is caught as 'already exists'",
        () async {
      final db = await DatabaseService.instance.database;
      // Deliberately without IF NOT EXISTS, so SQLite raises.
      await DatabaseService.runMigrations(db, 0, 1, migrations: const {
        1: [
          'CREATE TABLE notes (id TEXT PRIMARY KEY)',
          'CREATE INDEX idx_note_tags_note ON note_tags(noteId)',
        ],
      });
    });

    test('any other DatabaseException is rethrown', () async {
      final db = await DatabaseService.instance.database;
      // The catch is selective: an error that doesn't mean "already
      // applied" must abort the upgrade, not be swallowed.
      await expectLater(
        DatabaseService.runMigrations(db, 0, 1, migrations: const {
          1: ['ALTER TABLE no_such_table ADD COLUMN x TEXT'],
        }),
        throwsA(isA<DatabaseException>()),
      );
    });
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

    test('kSchemaVersion matches the highest registered migration',
        () async {
      // Catches a "bumped kSchemaVersion to NN but forgot to register
      // vNN" slip. Gaps in the published version sequence are expected
      // (this repo publishes a representative subset, not the full
      // history), so this checks the top end and that every registered
      // key has statements, not that every version 1..N is present.
      expect(SchemaScripts.migrations.containsKey(DatabaseService.kSchemaVersion),
          isTrue,
          reason: 'kSchemaVersion is ${DatabaseService.kSchemaVersion} but '
              'v${DatabaseService.kSchemaVersion} is not registered — '
              'upgrades would set user_version without running it');
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
      // with the lowest `_rowid_` in each group. SQLite doesn't promise
      // rowids follow insert order in general, but on this fresh,
      // never-deleted-from table they do, so the expected survivor is
      // deterministic here.
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
          reason: 'Lowest _rowid_ wins; on this fresh table that is the '
              'first inserted row');
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
