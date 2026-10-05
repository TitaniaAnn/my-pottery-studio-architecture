import 'package:uuid/uuid.dart';

import '../../database/database_service.dart';
import '../../models/custom_stage.dart';
import '../../models/stage_definition.dart';

/// CRUD for user-created pipeline stages.
///
/// Custom stages are referenced by UUID rather than by the dbName string
/// pattern used for built-in stages, so the same pipeline can mix
/// built-in and custom stages freely without the registry needing to
/// know which kind it's resolving.
class CustomStagesDao {
  final DatabaseService _db;
  CustomStagesDao(this._db);

  Future<List<CustomStage>> getAll() async {
    final db = await _db.database;
    final rows = await db.query(
      'custom_stages',
      orderBy: 'sortOrder ASC, name ASC',
    );
    return rows.map(CustomStage.fromMap).toList();
  }

  Future<CustomStage> create({
    required String name,
    required String emoji,
  }) async {
    final db = await _db.database;
    final now = DateTime.now().toUtc();
    final stage = CustomStage(
      id:        const Uuid().v4(),
      name:      name,
      emoji:     emoji,
      sortOrder: 100,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('custom_stages', stage.toMap());
    return stage;
  }

  Future<void> update(CustomStage stage) async {
    final db = await _db.database;
    await db.update(
      'custom_stages',
      stage.toMap(),
      where: 'id = ?',
      whereArgs: [stage.id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete('custom_stages', where: 'id = ?', whereArgs: [id]);
  }

  /// Converts a [CustomStage] to a [StageDefinition] for the registry.
  /// User-entered names can be any length, so shortName is truncated
  /// to keep custom stages as compact as the built-ins, whose display
  /// names are all short enough to double as their short labels.
  static StageDefinition toDefinition(CustomStage s) {
    final short = s.name.length > 12 ? '${s.name.substring(0, 11)}…' : s.name;
    return StageDefinition(
      id:        s.id,
      name:      s.name,
      shortName: short,
      emoji:     s.emoji,
      isBuiltIn: false,
    );
  }
}
