// DAO soft-delete tests: verify the LWW invariant the sync foundation
// quietly depends on.
//
// ARCHITECTURE.md §2 establishes the universal-columns convention
// (UUID, createdAt, updatedAt, deletedAt) and §8 leans on `updatedAt`
// for last-writer-wins conflict resolution. The invariant that's
// silently load-bearing for both: when a row is soft-deleted,
// `updatedAt` must move to the same value as `deletedAt`. If
// `updatedAt` stays at its pre-delete value, a peer's later edit
// would resolve as newer than the local delete on the next sync,
// silently revoking the deletion.
//
// Two small tests cover the contract:
//
//   1. softDelete(id) writes deletedAt and updatedAt from the SAME
//      timestamp. Two separate `DateTime.now()` calls would produce
//      values that differ by microseconds — close enough that a peer
//      would still pick the right side most of the time, but the
//      invariant the architecture claims is strict equality.
//   2. The pre-delete updatedAt is replaced, not preserved.
//   3. Both are written in UTC — the stored string ends in `Z`. A
//      local time with no offset names a different instant on a peer
//      in another time zone (or on the same device across a DST
//      change), so comparing them would pick the wrong winner.
//
// Plus one model-level check that Note.toMap stores UTC even when
// handed a local DateTime, since every other writer goes through it.
//
// The test bypasses NotesDao.create — the Note model carries
// pipelineId/currentStage that the published v01+v12 notes schema
// doesn't yet have columns for, and create() would fail with
// "no such column" on the insert. softDelete only touches
// id/deletedAt/updatedAt, so a raw insert with the schema's actual
// columns is enough to exercise it.

import 'package:flutter_test/flutter_test.dart';
import 'package:my_pottery_studio_architecture/database/database_service.dart';
import 'package:my_pottery_studio_architecture/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _id = 'note-under-test';

Future<void> _insertRawNote(
  String id,
  DateTime created,
) async {
  final db = await DatabaseService.instance.database;
  await db.insert('notes', {
    'id':           id,
    'title':        'Test note',
    'body':         '',
    'userId':       null,
    'createdAt':    created.toUtc().toIso8601String(),
    'updatedAt':    created.toUtc().toIso8601String(),
    'deletedAt':    null,
    // v12 columns — NOT NULL with defaults, but spell them out so the
    // test doesn't depend on default-application order.
    'status':       'active',
    'pinned':       0,
    'wordCount':    0,
    'sortOrder':    0,
  });
}

void main() {
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testDbPath = ':memory:';
    await DatabaseService.resetForTests();
  });

  group('NotesDao.softDelete', () {
    test('writes deletedAt and updatedAt from the same timestamp',
        () async {
      final created = DateTime(2026, 1, 1);
      await _insertRawNote(_id, created);

      await DatabaseService.instance.notes.softDelete(_id);

      final db = await DatabaseService.instance.database;
      final row = (await db.query('notes',
              where: 'id = ?', whereArgs: [_id]))
          .single;

      expect(row['deletedAt'], isNotNull,
          reason: 'softDelete must populate deletedAt');
      expect(row['updatedAt'], row['deletedAt'],
          reason: 'updatedAt must equal deletedAt — last-writer-wins '
              'sync resolves "local soft-deleted, remote edited" '
              'races by comparing updatedAt, and a delete that fails '
              'to bump updatedAt would lose to any later edit on '
              'the peer.');
    });

    test('replaces the pre-delete updatedAt rather than preserving it',
        () async {
      final created = DateTime(2026, 1, 1);
      await _insertRawNote(_id, created);

      await DatabaseService.instance.notes.softDelete(_id);

      final db = await DatabaseService.instance.database;
      final row = (await db.query('notes',
              where: 'id = ?', whereArgs: [_id]))
          .single;

      expect(row['updatedAt'], isNot(created.toUtc().toIso8601String()),
          reason: 'updatedAt at delete time must be the delete '
              'timestamp, not the original creation timestamp — '
              'otherwise the row would look stale to any peer '
              'that has the row at its original updatedAt');
    });

    test('writes UTC timestamps, still equal to each other', () async {
      await _insertRawNote(_id, DateTime.utc(2026, 1, 1));

      await DatabaseService.instance.notes.softDelete(_id);

      final db = await DatabaseService.instance.database;
      final row = (await db.query('notes',
              where: 'id = ?', whereArgs: [_id]))
          .single;
      final deletedAt = row['deletedAt'] as String;
      final updatedAt = row['updatedAt'] as String;

      expect(deletedAt, endsWith('Z'),
          reason: 'LWW compares updatedAt across devices; a timestamp '
              'without an offset is ambiguous across time zones and DST');
      expect(updatedAt, endsWith('Z'));
      expect(updatedAt, deletedAt,
          reason: 'switching to UTC must not break the single-timestamp '
              'invariant');
      expect(DateTime.parse(deletedAt).isUtc, isTrue);
    });
  });

  group('Note.toMap', () {
    test('stores UTC even when given local DateTimes', () {
      final local = DateTime(2026, 3, 29, 1, 30); // a DST edge in many zones
      final map = Note(
        id:           'n',
        title:        't',
        pipelineId:   'p',
        currentStage: 'draft',
        createdAt:    local,
        updatedAt:    local,
        deletedAt:    local,
      ).toMap();

      for (final key in ['createdAt', 'updatedAt', 'deletedAt']) {
        final value = map[key] as String;
        expect(value, endsWith('Z'), reason: '$key must be stored in UTC');
        expect(DateTime.parse(value).isAtSameMomentAs(local), isTrue,
            reason: '$key must be the same instant, just expressed in UTC');
      }
    });
  });
}
