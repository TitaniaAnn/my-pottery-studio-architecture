import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database_service.dart';
import '../../models/pipeline.dart';

/// CRUD for user-configurable workflow pipelines.
///
/// This is the data access layer for the workflow engine itself —
/// reads and writes the [Pipeline] rows that define what stages exist
/// and in what order. The in-memory cache lives in [PipelineRegistry];
/// this DAO is what that registry talks to.
///
/// Built-in pipelines are seeded in migration v26 and are protected
/// from deletion at the SQL level via the `isBuiltIn = 0` clause in
/// [delete]. Built-ins can be reordered and renamed, but never removed.
class PipelinesDao {
  final DatabaseService _db;
  PipelinesDao(this._db);

  Future<Database> get _database async => await _db.database;

  Future<List<Pipeline>> getAll() async {
    final db = await _database;
    final rows = await db.query(
      'pipeline_types',
      orderBy: 'sortOrder ASC, name ASC',
    );
    return rows.map(Pipeline.fromMap).toList();
  }

  Future<Pipeline?> getById(String id) async {
    final db = await _database;
    final rows = await db.query(
      'pipeline_types',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Pipeline.fromMap(rows.first);
  }

  Future<Pipeline> save(Pipeline pipeline) async {
    final db = await _database;
    await db.insert(
      'pipeline_types',
      pipeline.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return pipeline;
  }

  Future<Pipeline> create({
    required String name,
    required String emoji,
    required List<String> stages,
  }) async {
    final now = DateTime.now();
    final pipeline = Pipeline(
      id:        const Uuid().v4(),
      name:      name,
      emoji:     emoji,
      stages:    stages,
      isBuiltIn: false,
      sortOrder: 100, // custom pipelines sort after built-ins
      createdAt: now,
      updatedAt: now,
    );
    return save(pipeline);
  }

  Future<void> update(Pipeline pipeline) async {
    final db = await _database;
    await db.update(
      'pipeline_types',
      pipeline.copyWith(updatedAt: DateTime.now()).toMap(),
      where: 'id = ?',
      whereArgs: [pipeline.id],
    );
  }

  /// Deletes a custom pipeline. Entities using it retain their
  /// pipelineId string and will fall back gracefully via the registry
  /// (which returns a sensible default when given an unknown ID).
  ///
  /// Built-in pipelines cannot be deleted — the WHERE clause filters
  /// them out at the SQL level rather than relying on application-side
  /// validation that could be bypassed.
  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete(
      'pipeline_types',
      where: 'id = ? AND isBuiltIn = 0',
      whereArgs: [id],
    );
  }

  /// Bulk reorder, executed in a single transaction so the DB is never
  /// observable in a half-reordered state. Used by the drag-and-drop
  /// reorder UI which needs to update every affected row at once.
  Future<void> updateSortOrders(List<Pipeline> ordered) async {
    final db = await _database;
    await db.transaction((txn) async {
      for (var i = 0; i < ordered.length; i++) {
        await txn.update(
          'pipeline_types',
          {
            'sortOrder': i,
            'updatedAt': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [ordered[i].id],
        );
      }
    });
  }
}