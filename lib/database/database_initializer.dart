// Initializes the SQLite database layer for platforms that require explicit
// setup (e.g., desktop/VM using `sqflite_common_ffi`).
//
// On web, this is a no-op.

import 'package:flutter/foundation.dart' show kIsWeb;

import 'database_initializer_io.dart'
    if (dart.library.html) 'database_initializer_web.dart';

/// Call this early in `main()` before using `sqflite` APIs.
Future<void> initDatabase() async {
  if (kIsWeb) return;
  await initDatabasePlatform();
}
