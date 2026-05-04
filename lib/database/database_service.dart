import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import 'schema_scripts.dart';
import '../services/dao/notes_dao.dart';
import '../services/dao/pipelines_dao.dart';
import '../services/dao/custom_stages_dao.dart';
import '../services/pipeline_registry.dart';
import '../services/stage_registry.dart';

/// Singleton service that owns all SQLite reads and writes.
/// Access via [DatabaseService.instance].
///
/// ─── Architecture ────────────────────────────────────────────────
/// This class has three responsibilities:
///
///   1. Open and version the SQLite database
///   2. Run versioned schema migrations on open or upgrade
///   3. Expose typed DAOs for each domain table
///
/// The DAOs are the public API for application code. Callers never
/// touch the [Database] object directly — they go through DAOs, which
/// own the SQL for their domain. This keeps SQL out of UI/state code
/// and makes every query reviewable in one place per table.
///
/// ─── Idempotent migrations ───────────────────────────────────────
/// The migration runner in [_onUpgrade] catches two specific
/// [DatabaseException] messages — `'duplicate column name'` and
/// `'already exists'` — and treats them as success. This means:
///
///   * ALTER TABLE ADD COLUMN on a column that's already present is
///     a no-op rather than a crash.
///   * CREATE TABLE / CREATE INDEX (without IF NOT EXISTS) on an
///     existing object is a no-op rather than a crash.
///
/// This is what makes "skipped a version, then upgraded again later"
/// safe. The end state is what matters; the path doesn't have to be
/// linear.
class DatabaseService {
  // ── Singleton setup ────────────────────────────────────────────

  /// Current schema version. Bump this when adding a new vNN.dart
  /// migration file and registering it in [SchemaScripts.migrations].
  ///
  /// Exposed as a constant so tests can iterate `for (var v = 1; v <=
  /// kSchemaVersion; v++)` to assert every version is registered, which
  /// catches the "bumped the version but forgot to register vN" slip.
  static const int kSchemaVersion = 36;

  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  /// Allows tests to override the database location (e.g. use ':memory:').
  @visibleForTesting
  static String? testDbPath;

  /// Resets the singleton (closes the open DB handle and clears it).
  ///
  /// Used after restoring from a backup, in tests, or any scenario
  /// where the DB file may have changed under the hood. The next call
  /// to [database] will reopen against the new file.
  static Future<void> reset() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  /// Resets the singleton for integration/test scenarios.
  @visibleForTesting
  static Future<void> resetForTests() => reset();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('note_workflow.db');
    return _database!;
  }

  // ── Database initialization ────────────────────────────────────

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = testDbPath ?? join(dbPath, filePath);

    return await openDatabase(
      path,
      version: kSchemaVersion,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  /// Creates all tables on a fresh install.
  /// Implemented by running every migration from version 0 up.
  Future _createDB(Database db, int version) async {
    await _onUpgrade(db, 0, version);
  }

  /// Migrates an existing install to the latest schema version.
  ///
  /// Iterates from `oldVersion + 1` to `newVersion`, executing each
  /// registered migration's SQL statements in sequence. Migrations
  /// without entries in [SchemaScripts.migrations] are skipped — the
  /// loop tolerates gaps in the version sequence.
  ///
  /// The try/catch around [db.execute] is what makes the whole system
  /// idempotent. See the class-level docs for the full explanation.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    for (int i = oldVersion + 1; i <= newVersion; i++) {
      if (SchemaScripts.migrations.containsKey(i)) {
        for (String script in SchemaScripts.migrations[i]!) {
          try {
            await db.execute(script);
          } on DatabaseException catch (e) {
            // Ignore idempotency errors — these mean the schema change
            // was already applied, which is the desired end state:
            //   • "duplicate column name" — ALTER TABLE ADD COLUMN on
            //     an existing column (e.g. v22 on installs that got
            //     the column via v12)
            //   • "already exists" — CREATE TABLE / CREATE INDEX
            //     without IF NOT EXISTS on an object that was already
            //     created
            final msg = e.toString();
            final isIdempotent = msg.contains('duplicate column name') ||
                msg.contains('already exists');
            if (!isIdempotent) rethrow;
          }
        }
      }
    }
  }

  // ── DAO accessors ──────────────────────────────────────────────

  late final NotesDao notes;
  late final PipelinesDao pipelines;
  late final CustomStagesDao customStages;

  DatabaseService._init() {
    notes        = NotesDao(this);
    pipelines    = PipelinesDao(this);
    customStages = CustomStagesDao(this);
  }

  // ── Registry loaders ───────────────────────────────────────────

  /// Loads all pipelines into the in-memory [PipelineRegistry].
  /// Call once after the DB is open (e.g. in main.dart before runApp),
  /// and again after any pipeline create/update/delete.
  Future<void> loadPipelineRegistry() async {
    final all = await pipelines.getAll();
    PipelineRegistry.instance.load(all);
  }

  /// Loads custom stages into the [StageRegistry].
  /// Call once after the DB is open, and again after any custom stage
  /// create/update/delete.
  Future<void> loadStageRegistry() async {
    final all = await customStages.getAll();
    StageRegistry.instance.loadCustom(
      all.map(CustomStagesDao.toDefinition).toList(),
    );
  }

  // ── Lifecycle ──────────────────────────────────────────────────

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}