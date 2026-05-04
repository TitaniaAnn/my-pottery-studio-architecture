import 'dart:convert';

/// A user-configurable workflow pipeline.
///
/// The built-in pipelines are seeded in the DB at migration v26 and
/// cannot be deleted. Users can create additional pipelines with any
/// ordered subset of stage IDs (built-in stage dbNames or custom stage
/// UUIDs).
///
/// Stages are stored as a JSON-encoded string array in the `stages` column
/// rather than as rows in a separate `pipeline_stages` table. This keeps
/// reordering stages a single-row UPDATE rather than a multi-row delete-
/// and-reinsert, and it sidesteps the question of how to migrate stage
/// indices when the user inserts a new stage in the middle of a pipeline.
class Pipeline {
  final String id;
  final String name;
  final String emoji;
  final List<String> stages; // ordered stage IDs
  final bool isBuiltIn;      // built-ins cannot be deleted
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Pipeline({
    required this.id,
    required this.name,
    required this.emoji,
    required this.stages,
    this.isBuiltIn = false,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Pipeline.fromMap(Map<String, dynamic> map) {
    final rawList = jsonDecode(map['stages'] as String) as List<dynamic>;
    return Pipeline(
      id:        map['id'] as String,
      name:      map['name'] as String,
      emoji:     map['emoji'] as String,
      stages:    rawList.cast<String>().toList(),
      isBuiltIn: (map['isBuiltIn'] as int) == 1,
      sortOrder: map['sortOrder'] as int,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toMap() => {
    'id':        id,
    'name':      name,
    'emoji':     emoji,
    'stages':    jsonEncode(stages),
    'isBuiltIn': isBuiltIn ? 1 : 0,
    'sortOrder': sortOrder,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  Pipeline copyWith({
    String? name,
    String? emoji,
    List<String>? stages,
    int? sortOrder,
    DateTime? updatedAt,
  }) =>
      Pipeline(
        id:        id,
        name:      name ?? this.name,
        emoji:     emoji ?? this.emoji,
        stages:    stages ?? this.stages,
        isBuiltIn: isBuiltIn,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}