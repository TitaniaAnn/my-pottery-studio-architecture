// What survives a migration that fails partway through?
//
// ARCHITECTURE.md §3 says sqflite wraps `onUpgrade` in a transaction.
// This file pins that down for the sqflite version this repo resolves,
// because the answer decides what the runner's idempotency catch is
// actually for: if earlier statements committed on their own, the catch
// would be what lets a half-applied migration finish on the next launch.
// If they roll back, a failed upgrade leaves no partial state at all.
//
// The test uses a file-backed database (not `:memory:`) so it can close
// and reopen the same file and look at what really persisted.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('migration_txn_');
    path = p.join(dir.path, 'upgrade.db');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('§3: a failed upgrade rolls back every statement, not just the failing one',
      () async {
    // A v1 database with one table.
    final v1 = await openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute('CREATE TABLE notes (id TEXT PRIMARY KEY)');
    });
    await v1.close();

    // Upgrade to v3. v2's statement succeeds; v3's first statement
    // succeeds and its second fails. Each statement runs as its own
    // execute() call, exactly like DatabaseService's runner.
    final scripts = {
      2: ['ALTER TABLE notes ADD COLUMN fromV2 TEXT'],
      3: [
        'ALTER TABLE notes ADD COLUMN fromV3 TEXT',
        'ALTER TABLE no_such_table ADD COLUMN boom TEXT',
      ],
    };
    await expectLater(
      openDatabase(path, version: 3, onUpgrade: (db, from, to) async {
        for (var v = from + 1; v <= to; v++) {
          for (final s in scripts[v] ?? const <String>[]) {
            await db.execute(s);
          }
        }
      }),
      throwsA(isA<DatabaseException>()),
    );

    // Reopen without a version so no callbacks run, and inspect.
    final after = await openDatabase(path);
    final columns = (await after.rawQuery('PRAGMA table_info(notes)'))
        .map((r) => r['name'])
        .toList();
    final userVersion = await after.getVersion();
    await after.close();

    expect(columns, ['id'],
        reason: 'neither fromV2 (an earlier version in the same upgrade) '
            'nor fromV3 (an earlier statement in the failing version) '
            'should persist: sqflite runs the whole onUpgrade in one '
            'transaction');
    expect(userVersion, 1,
        reason: 'user_version is set inside the same transaction, so the '
            'next open retries the upgrade from v1');
  });
}
