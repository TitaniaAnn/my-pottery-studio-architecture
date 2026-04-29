import '../models/pipeline.dart';

/// In-memory cache of all [Pipeline] rows.
///
/// Loaded once at app startup (after the DB is open) so that pipeline
/// info is available synchronously throughout the widget tree without
/// FutureBuilders or async lookups in every render path.
///
/// The synchronous-availability guarantee is what makes this a registry
/// rather than a service: by the time any UI code runs, this is already
/// populated, and lookups are O(n) over a small in-memory list rather
/// than database round-trips.
///
/// Call [load] after any create/update/delete operation to keep the
/// cache consistent. The DAOs don't update this cache themselves —
/// the calling code is responsible for triggering a reload, which
/// keeps the registry's loading semantics explicit.
class PipelineRegistry {
  PipelineRegistry._();
  static final instance = PipelineRegistry._();

  List<Pipeline> _all = [];

  /// Initialises or refreshes the cache from a freshly-loaded list.
  /// Call this once after DatabaseService opens, and again after any
  /// create/update/delete via [PipelinesDao].
  void load(List<Pipeline> pipelines) {
    _all = List.unmodifiable(pipelines);
  }

  /// All pipelines in sort order.
  List<Pipeline> get all => _all;

  /// Look up a pipeline by its [id]. Returns null if not found —
  /// callers should handle gracefully (e.g. by falling back to a
  /// default pipeline or showing a "pipeline deleted" placeholder).
  Pipeline? get(String? id) {
    if (id == null) return null;
    try {
      return _all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Convenience: stage IDs for [id], falling back to empty list if
  /// the pipeline doesn't exist.
  List<String> stagesFor(String? id) => get(id)?.stages ?? [];
}