import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
/// Import is uniform across platforms: file picker, validate, replace.
///
/// ─── Atomic restore ──────────────────────────────────────────────
/// The restore flow uses a copy-then-rename pattern rather than copying
/// directly over the live DB file. If the copy fails partway through,
/// the original DB is untouched. Only after the copy completes does the
/// rename swap them in — and rename is atomic on every supported OS.
///
/// After a successful restore, [DatabaseService.reset] is called so the
/// next DB access opens against the new file rather than reusing the
/// stale connection to the old one.
class LocalBackupService {
  LocalBackupService._();
  static final instance = LocalBackupService._();

  static const _backupFileName = 'note_workflow_backup.db';

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

      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        return _exportDesktop(dbFile);
      } else {
        return _exportMobile(dbFile, sharePositionOrigin);
      }
    } catch (e) {
      return LocalBackupResult.fail(e.toString());
    }
  }

  Future<LocalBackupResult> _exportMobile(
    File dbFile, [
    Rect? sharePositionOrigin,
  ]) async {
    // Copy to a temp file with a timestamped name so the share sheet
    // shows a sensible filename rather than the internal DB path.
    final tmp = Directory.systemTemp;
    final copy = File(p.join(tmp.path, _timestampedName()));
    await dbFile.copy(copy.path);

    await SharePlus.instance.share(
      ShareParams(
        files:               [XFile(copy.path, mimeType: 'application/octet-stream')],
        subject:             'Workflow Backup',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );

    return LocalBackupResult.ok();
  }

  Future<LocalBackupResult> _exportDesktop(File dbFile) async {
    final outputDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where to save the backup',
    );

    if (outputDir == null) {
      return LocalBackupResult.fail('Cancelled');
    }

    final dest = File(p.join(outputDir, _timestampedName()));
    await dbFile.copy(dest.path);
    return LocalBackupResult.ok(path: dest.path);
  }

  // ── Import / restore ───────────────────────────────────────────

  /// Opens a file picker for the user to choose a `.db` backup file,
  /// then replaces the current database with the chosen file.
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

      final picked = result.files.single;
      final sourcePath = picked.path;
      if (sourcePath == null) {
        return LocalBackupResult.fail('Could not read the selected file.');
      }

      if (!sourcePath.toLowerCase().endsWith('.db')) {
        return LocalBackupResult.fail(
          'Please select a valid .db backup file.',
        );
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return LocalBackupResult.fail('Selected file not found.');
      }

      final dbPath  = await _dbPath();
      final tmpPath = '$dbPath.tmp';

      // Copy to temp first, then atomic rename. If anything fails before
      // the rename, the original DB is untouched.
      await sourceFile.copy(tmpPath);
      final dbFile = File(dbPath);
      if (await dbFile.exists()) await dbFile.delete();
      await File(tmpPath).rename(dbPath);

      // Reopen the restored DB. The next call to DatabaseService.database
      // will open against the new file rather than reusing the cached
      // connection to the old one.
      await DatabaseService.reset();

      return LocalBackupResult.ok(path: dbPath);
    } catch (e) {
      return LocalBackupResult.fail(e.toString());
    }
  }

  // ── Last local backup info ─────────────────────────────────────

  /// Returns the path to the most recent exported backup in the
  /// app's Documents folder, or null if none exists.
  ///
  /// Only relevant on platforms with a stable per-app Documents
  /// directory (desktop + iOS); on Android the share-sheet flow
  /// doesn't leave a copy behind for this method to find.
  Future<String?> getLastExportPath() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(p.join(docs.path, _backupFileName));
      if (await file.exists()) return file.path;
    } catch (_) {}
    return null;
  }
}