/// A single entry in an entity's stage lifecycle history.
/// Created automatically whenever an entity moves to a new stage.
///
/// Together these events form a complete, immutable audit trail of
/// every state transition — you can reconstruct an entity's full
/// lifecycle by querying its events ordered by timestamp.
class TransitionEvent {
  final String id;
  final String entityId;
  /// Stage ID — a built-in stage dbName (e.g. 'review') or a custom stage UUID.
  final String stage;
  final DateTime timestamp;

  TransitionEvent({
    required this.id,
    required this.entityId,
    required this.stage,
    required this.timestamp,
  });

  factory TransitionEvent.fromMap(Map<String, dynamic> map) {
    return TransitionEvent(
      id:        map['id'] as String,
      entityId:  map['entityId'] as String,
      stage:     map['stage'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id':        id,
      'entityId':  entityId,
      'stage':     stage,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}