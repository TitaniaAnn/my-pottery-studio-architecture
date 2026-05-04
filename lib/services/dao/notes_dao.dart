import 'package:uuid/uuid.dart';

import '../../database/database_service.dart';
import '../../models/note.dart';

/// CRUD for notes — the entity that flows through configurable
/// workflow pipelines.
///
/// This DAO demonstrates the standard pattern every domain DAO in this
/// architecture follows:
///   * Constructor takes a DatabaseService reference
///   * All methods open the DB lazily via `_db.database`
///   * Soft-delete via deletedAt rather than hard DELETE
///   * Reads exclude soft-deleted rows by default
///
/// In your own app, replace [Note] with whatever your domain calls the
/// entity that has a workflow: Order, Ticket, Project, Manuscript.
class NotesDao {
  final DatabaseService _db;
  NotesDao(this._db);

  Future<Note> create({
    required String title,
    required String pipelineId,
    required String currentStage,
    String body = '',
  }) async {
    final db = await _db.database;
    final now = DateTime.now();
    final note = Note(
      id:           const Uuid().v4(),
      title:        title,
      body:         body,
      pipelineId:   pipelineId,
      currentStage: currentStage,
      createdAt:    now,
      updatedAt:    now,
    );
    await db.insert('notes', note.toMap());
    return note;
  }

  Future<Note?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      'notes',
      where: 'id = ? AND deletedAt IS NULL',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Note.fromMap(rows.first);
  }

  Future<List<Note>> getAll() async {
    final db = await _db.database;
    final rows = await db.query(
      'notes',
      where: 'deletedAt IS NULL',
      orderBy: 'updatedAt DESC',
    );
    return rows.map(Note.fromMap).toList();
  }

  /// Returns notes filtered by current stage. Useful for stage-grouped
  /// views ("show me everything in review").
  Future<List<Note>> getByStage(String stage) async {
    final db = await _db.database;
    final rows = await db.query(
      'notes',
      where: 'currentStage = ? AND deletedAt IS NULL',
      whereArgs: [stage],
      orderBy: 'updatedAt DESC',
    );
    return rows.map(Note.fromMap).toList();
  }

  Future<void> update(Note note) async {
    final db = await _db.database;
    await db.update(
      'notes',
      note.toMap(),
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  /// Soft-delete: sets deletedAt rather than removing the row.
  /// Hard DELETE is never called from application code; rows are only
  /// physically removed by background cleanup jobs (not implemented in
  /// this reference architecture).
  ///
  /// `updatedAt` and `deletedAt` are written from a single timestamp,
  /// not two separate `DateTime.now()` calls. They have to be equal:
  /// last-writer-wins sync resolves a "local soft-deleted, remote
  /// edited" race by comparing `updatedAt`s, and a delete that fails
  /// to bump `updatedAt` would lose to any later edit on the peer.
  Future<void> softDelete(String id) async {
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'notes',
      {
        'deletedAt': now,
        'updatedAt': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}