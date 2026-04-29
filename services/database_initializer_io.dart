import 'dart:io' show Platform;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Initializes the sqflite database factory when running in a desktop/VM
/// environment.
Future<void> initDatabasePlatform() async {
  // The mobile sqflite plugin already configures the database factory.
  // On desktop (windows/linux/macos) we must explicitly initialize it.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
