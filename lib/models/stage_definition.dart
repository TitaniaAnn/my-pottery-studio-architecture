/// A unified representation of a pipeline stage — either a built-in
/// stage (referenced by its dbName) or a user-created custom stage
/// (referenced by its UUID).
///
/// Pipelines reference stages only by their string ID, so consumers
/// of a pipeline don't need to know whether a given stage is built-in
/// or custom — both kinds resolve to a StageDefinition the same way.
class StageDefinition {
  final String id;        // DB key: built-in dbName (e.g. 'throwing') or UUID
  final String name;      // Human-readable, e.g. 'Bisque Firing'
  final String shortName; // Short label, e.g. 'Bisque'
  final String emoji;
  final bool isBuiltIn;
  final bool isDead;      // true only for 'died'
  final bool isDone;      // true for 'finished' and 'sold'

  const StageDefinition({
    required this.id,
    required this.name,
    required this.shortName,
    required this.emoji,
    this.isBuiltIn = false,
    this.isDead = false,
    this.isDone = false,
  });

  bool get isTerminal => isDead || isDone;
}
