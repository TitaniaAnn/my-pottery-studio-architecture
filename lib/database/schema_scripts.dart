import 'migrations/v01.dart';
import 'migrations/v11.dart';
import 'migrations/v12.dart';
import 'migrations/v26.dart';
import 'migrations/v31.dart';
import 'migrations/v36.dart';

/// Registry mapping each schema version to its SQL statements.
///
/// Add a new vNN.dart file in migrations/ and register it here whenever
/// the schema changes. Bump [DatabaseService.kSchemaVersion] too.
///
/// ─── Note on this repository ──────────────────────────────────────
/// This is the architecture-reference fork of My Pottery Studio. The
/// production app is at v36+ schema versions, with new versions
/// shipping on an ongoing basis. Six representative versions are
/// published here, with their original numbers preserved so that
/// later migrations' references to earlier ones (v31's reliance on
/// v01's universal-columns convention, v36's hardening of v31's
/// sync_hard_delete_log) remain coherent. The published migrations
/// use a generic notes/tags toy domain rather than the real
/// ceramic-production schema.
class SchemaScripts {
  static const Map<int, List<String>> migrations = {
    1:  v01,
    11: v11,
    12: v12,
    26: v26,
    31: v31,
    36: v36,
  };
}
