import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../database/database_service.dart';

/// Result of a local backup or restore operation.
///
/// Uses a tagged-success pattern (success bool + optional payload + optional
/// error) rather than throwing exceptions because backup/restore failures
/// are expected user-facing scenarios, not programmer errors. UI code
/// should branch on [success] and surface [error] messages directly.
class LocalBackupResult {
  final bool    success;
  final String? savedPath; // null on mobile (shared via share sheet)
  final String? error;

  const LocalBackupResult._({required this.success, this.savedPath, this.error});

  factory LocalBackupResult.ok({String? path}) =>
      LocalBackupResult._(success: true, savedPath: path);

  factory LocalBackupResult.fail(String error) =>
      LocalBackupResult._(success: false, error: error);
}

/// Handles backup and restore of the SQLite database to and from local
/// device storage — without any cloud dependency.
///
/// ─── Why local-only ──────────────────────────────────────────────
/// Cloud backup is convenient but introduces auth, privacy, and uptime
/// concerns that this architecture explicitly avoids. The user's
/// database is theirs; backups go where the user puts them — Files,
/// iCloud Drive, Google Drive, a USB stick, an email to themselves —
/// and the app never sees any of it.
///
/// ─── Platform branching ──────────────────────────────────────────
/// The export flow differs by platform because the OS conventions do:
///
///   * Mobile  (iOS/Android): OS share sheet via [share_plus]. The user
///                            picks Files, AirDrop, email, etc. The app
///                            never knows where the file ended up.
///   * Desktop (Win/macOS/Linux): folder-picker via [file_picker]. The
///                            app copies the .db file to the chosen
///                            folder and reports the path back.
///
/// Either way the exported file is a checkpointed snapshot: if the live
/// database is in WAL mode, recent writes can still be sitting in the
/// `-wal` sidecar, and copying the main file alone would leave them
/// out. See [snapshotDatabaseTo].
///
/// Import is uniform across platforms: file picker, validate, replace.
///
/// ─── Validate before swap ────────────────────────────────────────
/// The picked file is copied to a temp path next to the live database
/// and checked there, before the live file is touched:
///
///   1. The 16-byte SQLite header magic (`SQLite format 3\0`), so a
///      renamed photo or a truncated download is rejected cheaply.
///   2. `PRAGMA quick_check` through a read-only connection, so a
///      corrupt database is rejected instead of bricking the next open.
///   3. `PRAGMA user_version` ≤ [DatabaseService.kSchemaVersion]. An
///      older backup is fine (the migration runner upgrades it on the
///      next open); a backup from a newer app version is rejected,
///      because this build has no way to migrate a schema backwards.
///
/// ─── Atomic restore ──────────────────────────────────────────────
/// Once the temp copy passes, the swap is close → delete → rename:
///
///   * [DatabaseService.reset] closes the open connection first. On
///     Windows an open SQLite handle locks the file, so deleting before
///     closing fails.
///   * The live file and its `-wal`, `-shm` and `-journal` sidecars are
///     deleted. A stale `-wal` left beside the restored file would be
///     replayed into it on the next open; a stale `-journal` would be
///     treated as a hot journal and "rolled back" into it.
///   * The temp copy is renamed into place. Rename is atomic on every
///     supported OS, and if anything fails before it the original
///     database is untouched.
///
/// The next DB access reopens against the restored file.
class LocalBackupService {
  LocalBackupService._();
  static final instance = LocalBackupService._();

  /// The first 16 bytes of every SQLite 3 database file.
  static const _sqliteHeader = 'SQLite format 3\u0000';

  /// Sidecar files SQLite may keep beside a database file.
  static const _sidecarSuffixes = ['-wal', '-shm', '-journal'];

  Future<String> _dbPath() async {
    final db = await DatabaseService.instance.database;
    return db.path;
  }

  String _timestampedName() {
    final ts = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    return 'note_workflow_$ts.db';
  }

  // ── Export ─────────────────────────────────────────────────────

  /// Exports the database file.
  ///
  /// On mobile, opens the OS share sheet so the user can save anywhere.
  /// On desktop, shows a folder-picker and copies the file there.
  ///
  /// [sharePositionOrigin] is needed on iPad to anchor the share sheet
  /// to the originating UI element; pass null on other platforms.
  Future<LocalBackupResult> exportBackup([Rect? sharePositionOrigin]) async {
    try {
      final dbPath = await _dbPath();
      final dbFile = File(dbPath);
      if (!await dbFile.exists()) {
        return LocalBackupResult.fail('Database file not found.');
      }

      // `return await`, not `return`: a bare returned future inside a
      // try completes the caller's future directly, so a picker or
      // share failure would escape the catch below as a raw throw
      // instead of becoming a LocalBackupResult.fail.
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        return await _exportDesktop();
      } else {
        return await _exportMobile(sharePositionOrigin);
      }
    } catch (e) {
      return LocalBackupResult.fail(e.toString());
    }
  }

  Future<LocalBackupResult> _exportMobile([
    Rect? sharePositionOrigin,
  ]) async {
    // Snapshot to a temp file with a timestamped name so the share
    // sheet shows a sensible filename rather than the internal DB path.
    final tmp = Directory.systemTemp;
    final copy = File(p.join(tmp.path, _timestampedName()));
    await snapshotDatabaseTo(copy.path);

    await SharePlus.instance.share(
      ShareParams(
        files:               [XFile(copy.path, mimeType: 'application/octet-stream')],
        subject:             'Workflow Backup',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );

    return LocalBackupResult.ok();
  }

  Future<LocalBackupResult> _exportDesktop() async {
    final outputDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where to save the backup',
    );

    if (outputDir == null) {
      return LocalBackupResult.fail('Cancelled');
    }

    final dest = File(p.join(outputDir, _timestampedName()));
    await snapshotDatabaseTo(dest.path);
    return LocalBackupResult.ok(path: dest.path);
  }

  /// Writes a self-contained copy of the live database to [destPath].
  ///
  /// `PRAGMA wal_checkpoint(TRUNCATE)` first moves any committed pages
  /// from the `-wal` sidecar into the main file, so the copy has every
  /// write. When the database isn't in WAL mode the pragma is a no-op
  /// and the main file already holds everything.
  ///
  /// `VACUUM INTO` would also produce a complete copy, but it needs
  /// SQLite 3.27+, which older Android system SQLite builds don't ship.
  /// A checkpoint works on every version sqflite runs against.
  @visibleForTesting
  Future<void> snapshotDatabaseTo(String destPath) async {
    final db = await DatabaseService.instance.database;
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await File(db.path).copy(destPath);
  }

  // ── Import / restore ───────────────────────────────────────────

  /// Opens a file picker for the user to choose a `.db` backup file,
  /// then replaces the current database with the chosen file via
  /// [restoreFromFile].
  ///
  /// WARNING: This overwrites all local data. Callers should confirm
  /// with the user before invoking this method.
  Future<LocalBackupResult> importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle:   'Select a workflow backup (.db)',
        type:          FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return LocalBackupResult.fail('Cancelled');
      }

      final sourcePath = result.files.single.path;
      if (sourcePath == null) {
        return LocalBackupResult.fail('Could not read the selected file.');
      }

      return await restoreFromFile(sourcePath);
    } catch (e) {
      return LocalBackupResult.fail(e.toString());
    }
  }

  /// Validates [sourcePath] and, if it passes, swaps it in as the live
  /// database. See the class docs for the validation and swap steps.
  @visibleForTesting
  Future<LocalBackupResult> restoreFromFile(String sourcePath) async {
    String? tmpPath;
    try {
      if (!sourcePath.toLowerCase().endsWith('.db')) {
        return LocalBackupResult.fail(
          'Please select a valid .db backup file.',
        );
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return LocalBackupResult.fail('Selected file not found.');
      }

      final dbPath = await _dbPath();
      tmpPath = '$dbPath.tmp';

      // 1. Copy to a temp path and validate the copy. Nothing has
      //    touched the live database yet.
      await _deleteWithSidecars(tmpPath);
      await sourceFile.copy(tmpPath);
      final problem = await _validate(tmpPath);
      if (problem != null) {
        await _deleteWithSidecars(tmpPath);
        return LocalBackupResult.fail(problem);
      }
      // Validating a WAL-mode backup can leave -wal/-shm files beside
      // the temp copy; they'd be orphaned by the rename below.
      await _deleteSidecars(tmpPath);

      // 2. Close before delete, or Windows refuses the delete.
      await DatabaseService.reset();

      // 3. Remove the live file and every sidecar, then rename the
      //    validated copy into place.
      await _deleteWithSidecars(dbPath);
      await File(tmpPath).rename(dbPath);

      return LocalBackupResult.ok(path: dbPath);
    } catch (e) {
      if (tmpPath != null) {
        try {
          await _deleteWithSidecars(tmpPath);
        } catch (_) {}
      }
      return LocalBackupResult.fail(e.toString());
    }
  }

  /// Returns a user-facing reason [path] can't be restored, or null if
  /// it's a readable SQLite database this app version can open.
  Future<String?> _validate(String path) async {
    // Header magic: cheap, and catches files that aren't SQLite at all.
    final raf = await File(path).open();
    final List<int> header;
    try {
      header = await raf.read(_sqliteHeader.length);
    } finally {
      await raf.close();
    }
    if (String.fromCharCodes(header) != _sqliteHeader) {
      return 'That file is not a database backup.';
    }

    // quick_check + user_version through a read-only connection, so
    // validation can't modify the file it's judging. singleInstance is
    // off so this never shares a handle with anything else.
    Database? check;
    try {
      check = await openDatabase(path, readOnly: true, singleInstance: false);
      final result = await check.rawQuery('PRAGMA quick_check');
      final verdict = result.isEmpty ? null : result.first.values.first;
      if (verdict != 'ok') {
        return 'The backup file is damaged and cannot be restored.';
      }
      final version = Sqflite.firstIntValue(
            await check.rawQuery('PRAGMA user_version'),
          ) ??
          0;
      if (version > DatabaseService.kSchemaVersion) {
        return 'This backup was made by a newer version of the app '
            '(schema v$version; this version supports up to '
            'v${DatabaseService.kSchemaVersion}). Update the app, then '
            'restore again.';
      }
      return null;
    } on DatabaseException {
      return 'The backup file is damaged and cannot be restored.';
    } finally {
      await check?.close();
    }
  }

  /// Deletes [path] and any SQLite sidecar files beside it.
  Future<void> _deleteWithSidecars(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
    await _deleteSidecars(path);
  }

  /// Deletes only the SQLite sidecar files beside [path].
  Future<void> _deleteSidecars(String path) async {
    for (final suffix in _sidecarSuffixes) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  }
}
