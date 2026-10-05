// Restore validation and the WAL-safe export snapshot — the claims in
// LocalBackupService's class docs and ARCHITECTURE.md §7.
//
// These use a file-backed database in a temp directory (restore swaps
// files, which :memory: can't model) and call the @visibleForTesting
// seams directly, since the public entry points open a file picker or
// share sheet.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_pottery_studio_architecture/database/database_service.dart';
import 'package:my_pottery_studio_architecture/services/local_backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Directory _dir;
late String _livePath;

Future<void> _insertNote(String id) async {
  final db = await DatabaseService.instance.database;
  final now = DateTime.now().toUtc().toIso8601String();
  await db.insert('notes', {
    'id': id,
    'title': id,
    'createdAt': now,
    'updatedAt': now,
  });
}

Future<List<String>> _noteIds() async {
  final db = await DatabaseService.instance.database;
  final rows = await db.query('notes', columns: ['id'], orderBy: 'id');
  return rows.map((r) => r['id'] as String).toList();
}

void main() {
  final backup = LocalBackupService.instance;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseService.resetForTests();
    _dir = await Directory.systemTemp.createTemp('backup_test_');
    _livePath = p.join(_dir.path, 'live.db');
    DatabaseService.testDbPath = _livePath;
    await _insertNote('live-row');
  });

  tearDown(() async {
    await DatabaseService.resetForTests();
    await _dir.delete(recursive: true);
  });

  group('§7 restore validation', () {
    test('rejects a file that is not SQLite and leaves the live DB alone',
        () async {
      final bogus = File(p.join(_dir.path, 'holiday-photo.db'))
        ..writeAsStringSync('definitely not a database');

      final result = await backup.restoreFromFile(bogus.path);

      expect(result.success, isFalse);
      expect(result.error, contains('not a database'));
      expect(await _noteIds(), ['live-row']);
      expect(File('$_livePath.tmp').existsSync(), isFalse,
          reason: 'the rejected temp copy must be cleaned up');
    });

    test('rejects a backup whose user_version is newer than this build',
        () async {
      final newerPath = p.join(_dir.path, 'from-the-future.db');
      final newer = await openDatabase(
        newerPath,
        version: DatabaseService.kSchemaVersion + 1,
        onCreate: (db, _) => db.execute('CREATE TABLE notes (id TEXT)'),
      );
      await newer.close();

      final result = await backup.restoreFromFile(newerPath);

      expect(result.success, isFalse);
      expect(result.error, contains('newer version'));
      expect(await _noteIds(), ['live-row']);
    });

    test('restores a valid backup and clears stale sidecars', () async {
      final backupPath = p.join(_dir.path, 'snapshot.db');
      await backup.snapshotDatabaseTo(backupPath);
      await _insertNote('written-after-backup');

      // Stale sidecars from the old database must not survive the swap.
      File('$_livePath-journal').writeAsStringSync('stale');
      File('$_livePath-wal').writeAsStringSync('stale');

      final result = await backup.restoreFromFile(backupPath);

      expect(result.success, isTrue, reason: result.error);
      expect(File('$_livePath-journal').existsSync(), isFalse);
      expect(File('$_livePath-wal').existsSync(), isFalse);
      expect(await _noteIds(), ['live-row'],
          reason: 'the restored file is the snapshot, without the later row');
    });
  });

  group('§7 export snapshot', () {
    test('includes writes still sitting in the WAL', () async {
      final db = await DatabaseService.instance.database;
      await db.rawQuery('PRAGMA journal_mode=WAL');
      await _insertNote('only-in-wal');
      expect(File('$_livePath-wal').lengthSync(), greaterThan(0),
          reason: 'precondition: the new row is in the -wal sidecar');

      final copyPath = p.join(_dir.path, 'export.db');
      await backup.snapshotDatabaseTo(copyPath);

      // Open the copy on its own, with no -wal beside it.
      expect(File('$copyPath-wal').existsSync(), isFalse);
      final copy = await openDatabase(copyPath, readOnly: true,
          singleInstance: false);
      final ids = (await copy.query('notes', columns: ['id'], orderBy: 'id'))
          .map((r) => r['id'])
          .toList();
      await copy.close();
      expect(ids, ['live-row', 'only-in-wal']);
    });
  });
}
