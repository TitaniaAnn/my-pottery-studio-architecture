/// All built-in pipeline stages available to every user.
///
/// IMPORTANT: Do NOT use `.index` to persist stages to the database.
/// Use `stage.dbName` to write and `BuiltInStageExtension.fromDb()` to read.
/// This makes the enum safe to reorder or extend without corrupting existing data.
enum BuiltInStage {
  draft,
  inProgress,
  review,
  approved,
  archived,
}

extension BuiltInStageExtension on BuiltInStage {
  /// The string stored in the database. Never changes, even if the enum is reordered.
  String get dbName => switch (this) {
    BuiltInStage.draft      => 'draft',
    BuiltInStage.inProgress => 'in_progress',
    BuiltInStage.review     => 'review',
    BuiltInStage.approved   => 'approved',
    BuiltInStage.archived   => 'archived',
  };

  /// Parses a string from the database back into a [BuiltInStage].
  /// Falls back to [BuiltInStage.draft] if the value is unrecognised
  /// (guards against future schema surprises).
  static BuiltInStage fromDb(String value) => switch (value) {
    'draft'       => BuiltInStage.draft,
    'in_progress' => BuiltInStage.inProgress,
    'review'      => BuiltInStage.review,
    'approved'    => BuiltInStage.approved,
    'archived'    => BuiltInStage.archived,
    _             => BuiltInStage.draft,
  };

  String get displayName => switch (this) {
    BuiltInStage.draft      => 'Draft',
    BuiltInStage.inProgress => 'In Progress',
    BuiltInStage.review     => 'Under Review',
    BuiltInStage.approved   => 'Approved',
    BuiltInStage.archived   => 'Archived',
  };

  String get emoji => switch (this) {
    BuiltInStage.draft      => '📝',
    BuiltInStage.inProgress => '🚧',
    BuiltInStage.review     => '👀',
    BuiltInStage.approved   => '✅',
    BuiltInStage.archived   => '📦',
  };
}

extension BuiltInStageBooleans on BuiltInStage {
  bool get isTerminal => this == BuiltInStage.approved || this == BuiltInStage.archived;
}