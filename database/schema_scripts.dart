import 'migrations/v01.dart';
import 'migrations/v11.dart';
import 'migrations/v12.dart';
import 'migrations/v22.dart';
import 'migrations/v26.dart';

/// Registry mapping each schema version to its SQL statements.
///
/// Add a new vNN.dart file in migrations/ and register it here
/// whenever the schema changes. Bump the version in DatabaseService too.
class SchemaScripts {
  static const Map<int, List<String>> migrations = {
    1: v01,
    2: v11,
    3: v12,
    4: v22,
    5: v26,
  };
}
