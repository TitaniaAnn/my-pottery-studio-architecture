import 'migrations/v01.dart';
import 'migrations/v11.dart';
import 'migrations/v12.dart';
import 'migrations/v26.dart';
import 'migrations/v31.dart';

/// Registry mapping each schema version to its SQL statements.
///
/// Add a new vNN.dart file in migrations/ and register it here whenever
/// the schema changes. Bump the version in DatabaseService too.
///
/// ─── Note on this repository ──────────────────────────────────────
/// This is the architecture-reference fork of My Pottery Studio. The
/// production app is currently at schema v31+, with new versions
/// shipping on an ongoing basis. Five representative versions are
/// published here, with their original version numbers preserved so
/// that v31's references to v01's universal-columns convention remain
/// coherent. The published migrations use a generic notes/tags toy
/// domain rather than the real ceramic-production schema.
class SchemaScripts {
  static const Map<int, List<String>> migrations = {
    1:  v01,
    11: v11,
    12: v12,
    26: v26,
    31: v31,
  };
}