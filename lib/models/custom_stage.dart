/// A user-created pipeline stage type.
class CustomStage {
  final String id;
  final String name;
  final String emoji;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  const CustomStage({
    required this.id,
    required this.name,
    required this.emoji,
    this.sortOrder = 100,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CustomStage.fromMap(Map<String, dynamic> map) => CustomStage(
        id:        map['id'] as String,
        name:      map['name'] as String,
        emoji:     map['emoji'] as String,
        sortOrder: map['sortOrder'] as int,
        createdAt: DateTime.parse(map['createdAt'] as String),
        updatedAt: DateTime.parse(map['updatedAt'] as String),
      );

  Map<String, dynamic> toMap() => {
        'id':        id,
        'name':      name,
        'emoji':     emoji,
        'sortOrder': sortOrder,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  CustomStage copyWith({String? name, String? emoji, int? sortOrder}) =>
      CustomStage(
        id:        id,
        name:      name ?? this.name,
        emoji:     emoji ?? this.emoji,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}
