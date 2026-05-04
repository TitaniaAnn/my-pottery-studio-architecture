/// A note moving through a configurable workflow pipeline.
///
/// This is the entity the workflow engine operates on — every piece of
/// state that has a lifecycle ends up modeled like this. In your own
/// app, replace [Note] with whatever your domain calls it: Order,
/// Ticket, Project, Manuscript, Piece. The shape stays the same.
///
/// ─── The universal-columns convention ────────────────────────────
/// Every user-owned table in this architecture has the same baseline
/// columns, established in migration v01:
///
///   id        — UUID primary key (no auto-increment, no merge collisions)
///   userId    — nullable, so adding a backend later requires no migration
///   createdAt — ISO 8601, never null
///   updatedAt — ISO 8601, never null, bumped on every copyWith
///   deletedAt — ISO 8601, null until soft-delete
///
/// These five columns make the table sync-ready, audit-friendly, and
/// safe to soft-delete without losing history.
///
/// ─── Workflow integration ────────────────────────────────────────
/// Two columns connect a Note to the workflow engine:
///
///   pipelineId   — which Pipeline the note is moving through
///   currentStage — the note's current stage ID (built-in dbName or
///                  custom stage UUID)
///
/// Stage transitions are recorded as TransitionEvents, so the full
/// lifecycle history is queryable independently of currentStage.
class Note {
  final String id;
  final String title;
  final String body;

  /// The pipeline this note is moving through.
  /// References Pipeline.id.
  final String pipelineId;

  /// Current stage ID — a built-in stage dbName (e.g. 'draft') or a
  /// custom stage UUID. The stage must be present in the referenced
  /// pipeline's stages list.
  final String currentStage;

  // ── Universal columns ────────────────────────────────────────────
  final String? userId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  const Note({
    required this.id,
    required this.title,
    this.body = '',
    required this.pipelineId,
    required this.currentStage,
    this.userId,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id:           map['id'] as String,
      title:        map['title'] as String,
      body:         map['body'] as String? ?? '',
      pipelineId:   map['pipelineId'] as String,
      currentStage: map['currentStage'] as String,
      userId:       map['userId'] as String?,
      createdAt:    DateTime.parse(map['createdAt'] as String),
      updatedAt:    DateTime.parse(map['updatedAt'] as String),
      deletedAt:    map['deletedAt'] != null
          ? DateTime.parse(map['deletedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id':           id,
      'title':        title,
      'body':         body,
      'pipelineId':   pipelineId,
      'currentStage': currentStage,
      'userId':       userId,
      'createdAt':    createdAt.toIso8601String(),
      'updatedAt':    updatedAt.toIso8601String(),
      'deletedAt':    deletedAt?.toIso8601String(),
    };
  }

  Note copyWith({
    String? title,
    String? body,
    String? pipelineId,
    String? currentStage,
    DateTime? deletedAt,
  }) {
    return Note(
      id:           id,
      title:        title        ?? this.title,
      body:         body         ?? this.body,
      pipelineId:   pipelineId   ?? this.pipelineId,
      currentStage: currentStage ?? this.currentStage,
      userId:       userId,
      createdAt:    createdAt,
      updatedAt:    DateTime.now(),
      deletedAt:    deletedAt    ?? this.deletedAt,
    );
  }
}