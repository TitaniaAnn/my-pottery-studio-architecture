import '../models/stage_definition.dart';
import '../models/built_in_stage.dart';

/// In-memory registry of all pipeline stages — built-in + custom.
///
/// Built-in stages are pre-loaded from the [BuiltInStage] enum when the
/// registry is first accessed. Custom stages are loaded from the DB after
/// the app starts; call [loadCustom] to refresh after any create/delete.
///
/// The unified registry means consumers (like UI code rendering a stage
/// name) never need to know whether a stage is built-in or custom —
/// they look up by ID and get back a [StageDefinition] either way.
class StageRegistry {
  StageRegistry._();
  static final instance = StageRegistry._();

  static final List<StageDefinition> _builtIn = _buildBuiltIn();
  List<StageDefinition> _custom = const [];

  static List<StageDefinition> _buildBuiltIn() =>
      BuiltInStage.values.map((s) {
        return StageDefinition(
          id:        s.dbName,
          name:      s.displayName,
          shortName: s.displayName, // Built-in stages use displayName as short
          emoji:     s.emoji,
          isBuiltIn: true,
          isDone:    s.isTerminal,
        );
      }).toList();

  /// Refreshes the custom-stage portion of the registry.
  /// Call once after the DB is open, and again after any create/delete
  /// in [CustomStagesDao].
  void loadCustom(List<StageDefinition> stages) {
    _custom = List.unmodifiable(stages);
  }

  /// All stages: built-in first, then custom in sort order.
  List<StageDefinition> get all => [..._builtIn, ..._custom];

  /// User-created custom stages only.
  List<StageDefinition> get custom => _custom;

  /// Looks up a stage by its [id]. Returns null if not found.
  ///
  /// Callers should handle null gracefully — a stage might be missing
  /// because a user deleted a custom stage that was referenced by a
  /// pipeline definition. The pipeline keeps the dangling ID; the
  /// registry returns null; the UI shows a "deleted stage" placeholder.
  StageDefinition? get(String? id) {
    if (id == null) return null;
    try {
      return all.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }
}