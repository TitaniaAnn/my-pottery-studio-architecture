// DatabaseService lifecycle: close() must leave the singleton able to
// reopen, not holding a closed handle.

import 'package:flutter_test/flutter_test.dart';
import 'package:my_pottery_studio_architecture/database/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testDbPath = ':memory:';
    await DatabaseService.resetForTests();
  });

  test('close() then database reopens a working connection', () async {
    final first = await DatabaseService.instance.database;
    await DatabaseService.instance.close();
    expect(first.isOpen, isFalse, reason: 'close() must actually close');

    final second = await DatabaseService.instance.database;
    expect(second.isOpen, isTrue,
        reason: 'the cached handle must be dropped, not returned closed');
    // A real query, so a closed handle would throw here.
    final rows = await second.rawQuery('SELECT COUNT(*) AS n FROM notes');
    expect(rows.single['n'], 0);
  });
}
