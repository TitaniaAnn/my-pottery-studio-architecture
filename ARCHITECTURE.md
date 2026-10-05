# Architecture

This document is the long-form companion to the [README](README.md).
The README tells you *what* the architecture is and where each piece
lives. This document tells you *why* — what problem each decision
solves, what alternatives were considered, and where the seams are
that future work would extend.

The ten decisions below are roughly ordered from most foundational
to most product-facing. The earlier ones are the ones the rest depend
on; the later ones are the ones that would be easiest to swap out.

---

## 1. Config tables replace hardcoded enums

### The problem

Apps tend to ship "types" as enums — categories, statuses, stages,
priority levels, anything that looks like a fixed set of choices.
Enums work until they don't: the moment a user wants a category the
app doesn't ship with, an enum is a code change away from solving
their problem, and a code change is something the user can't make.

For My Pottery Studio specifically, the central case is the
production-stage enum — a piece moves through clay prep, forming,
drying, bisque firing, glazing, glaze firing, finishing, sale.
Different artists work differently: a hand-builder skips throwing, a
raku potter has a different firing schedule than a stoneware potter,
a production studio has stages a beginner doesn't. That product
problem is what motivated this architectural pattern in the first
place.

The architectural problem, stated generally: how do you ship a type
that started as an enum so that users can add to it without a code
change?

### The decision

Move the enum into a data table, with a `isBuiltIn` flag separating
the rows the app seeds from the rows the user creates. The seeded IDs
match the strings the old enum used, so existing rows that reference
the enum value resolve to the new row without a data backfill.

[Migration v26](lib/database/migrations/v26.dart) is the published
example. It replaces a hardcoded `NoteCategory` enum with three
values (personal, work, reference): v26 creates a `categories` table
and seeds those three rows with `id` values equal to the enum's
persisted string names. Any row that stored `'work'` now resolves to
`categories.id = 'work'`, with no data migration.

That seeding trick is the bit worth pausing on. It only works if the
enum was persisted as its string name in a TEXT column, not as an
INTEGER holding its `.values` index. If it had been an integer, the
migration would have needed either a `categories.legacyIndex` column
or a row-by-row backfill — both more painful than the actual
migration, which is four SQL statements (one CREATE TABLE plus three
INSERT OR IGNOREs). In the production app the referencing column
exists on the entity table; this toy cut keeps only the `categories`
table and its seeds, so no published migration creates a `category`
column on `notes`. The by-name persistence rule itself is visible in
[`BuiltInStage.dbName`](lib/models/built_in_stage.dart).

### Same pattern, larger scale (sketched, not in this cut)

The production app uses the same pattern at workflow-engine scale:
a `pipeline_types` table for the production processes themselves, a
`custom_stages` table for user-created stages, and `pipelineId` /
`currentStage` columns on the entity table so each row knows which
pipeline it's flowing through and where in that pipeline it currently
sits.

This published cut includes the *code* side of that
larger-scale version — [Pipeline](lib/models/pipeline.dart),
[CustomStage](lib/models/custom_stage.dart),
[StageDefinition](lib/models/stage_definition.dart) (a unified handle
for either a built-in stage referenced by string ID or a user-created
one referenced by UUID),
[TransitionEvent](lib/models/transition_event.dart),
[`PipelinesDao`](lib/services/dao/pipelines_dao.dart),
[`CustomStagesDao`](lib/services/dao/custom_stages_dao.dart),
[`PipelineRegistry`](lib/services/pipeline_registry.dart),
[`StageRegistry`](lib/services/stage_registry.dart) — but it does
*not* include the migrations that would create the `pipeline_types`
and `custom_stages` tables, or the migration that would add
`pipelineId` / `currentStage` to notes. Those migrations live in the
production app and are deliberately not republished here.

The consequence is that the workflow-engine code reads as a sketch:
the shapes show how the categories pattern scales — registry
hydrated at startup, built-ins protected from deletion via a SQL
clause, custom rows held alongside built-ins under a unified
`StageDefinition` interface — but you can't actually run them
end-to-end against this cut's schema. The runnable demonstration of
the underlying pattern is v26.

Production has since taken the pattern one step further than this
cut shows. The built-in stages here still come from a Dart enum
([`BuiltInStage`](lib/models/built_in_stage.dart)); in production
that enum is gone. Built-in stages are now *data contributed by
code*: a small core pack (`concept`, `finished`, `sold`, `died`)
plus one stage pack per compiled craft module (§10), composed into
`StageRegistry` at startup. Terminal semantics went the same way.
SQL that used to say `NOT IN ('finished','sold','died')` now builds
its placeholder list from the registry's `isTerminal` flags, so a
module that defines its own terminal stage gets correct filtering
without a core edit. The stage ids stayed byte-identical through
the change, because they're the persisted keys in user rows.

### Why not the alternatives

A more "proper" object-oriented design would have made each enum
value a subclass of an abstract base class, with behavior defined as
methods. That works fine when the value set is known at compile time.
It does not work when users define their own values.

A workflow library (Temporal, Camunda, etc.) would have been the
enterprise answer for the workflow-engine version of this. They're
enormous, server-bound, and assume an orchestrator that doesn't exist
in a mobile app's process model. The whole point of offline-first is
that the workflow runs in the user's hand, not on a server.

A finite state machine library would have been overkill. The actual
runtime logic is small enough that a custom implementation costs less
to maintain than a third-party dependency we'd outgrow on the first
feature request that didn't fit its abstractions.

### Where the seams are

For categories specifically, the seam is at growth: a flat table is
fine for the dozen rows a user might realistically create, but a
nested-category feature would need either a `parentId` column or a
separate hierarchy table.

For the workflow-engine sketch, the schema supports linear pipelines
(`Pipeline.stages` is a JSON-encoded ordered list of stage IDs).
Branching pipelines — where a piece can move to one of several next
stages depending on condition — are representable with a small
migration (a `transitions` table linking stage pairs), but no UI or
runtime logic exists for them. If you wanted to add branching, the
migration is the easy part; the work is in the runtime that decides
which branch to take.

---

## 2. Offline-first SQLite architecture

### The problem

Ceramic studios have unreliable internet. Real ceramic studios are
often in basements, garages, outbuildings, or shared community spaces
with one weak Wi-Fi router two rooms away. The app needs to work
offline by default and treat connectivity as an enhancement, not a
requirement.

This is a different problem from "cache the network responses." It
means the source of truth is local. Every read, write, and query
happens against a local SQLite database. There is no remote server
the local DB is mirroring; the remote (when it eventually exists) is
mirroring the local.

The architectural problem is: how do you design a schema today so
that adding a remote backend later doesn't require migrating any
existing tables?

### The decision

Every user-data table created in this architecture has the same five
columns, established in [v01](lib/database/migrations/v01.dart):

```
id        TEXT PRIMARY KEY    — UUID, not auto-increment
userId    TEXT                — nullable, ready for a future backend
createdAt TEXT NOT NULL       — ISO 8601 timestamp, UTC
updatedAt TEXT NOT NULL       — ISO 8601 timestamp, UTC, bumped on every write
deletedAt TEXT                — nullable; soft-delete pattern
```
These five columns are not optional. They are the universal-columns
convention, and every migration that creates a new user-data table
includes them all. The convention is enforced by code review rather
than by a database constraint, which is a deliberate trade-off: it
keeps the schema flat and inspectable, at the cost of no compile-time
guarantee that a new table follows the pattern.

Each column does specific work:

- **UUID primary keys** mean no ID collisions when two devices both
  insert rows offline and then sync. Auto-increment integers would
  collide on every merge.
- **Nullable userId** means a single-user device today, multi-user
  later, with no migration. The column exists; it just isn't populated
  yet.
- **createdAt and updatedAt** are what a sync layer uses to detect
  changes. Without timestamps, sync can't tell which version is newer.
  They're written in UTC (`DateTime.now().toUtc()`, so the stored
  string ends in `Z`). A local time with no offset names a different
  instant on a peer in another time zone, or on the same device
  either side of a DST change, and last-writer-wins would compare the
  wrong instants. The one exception in this cut is v26's seed rows,
  which use SQLite's `datetime('now')`: also UTC, but in SQLite's
  space-separated format with no `Z`.
- **Soft-delete via deletedAt** means deletions can be replicated to
  peer devices. Hard-deleted rows just disappear — the peer has no way
  to learn the row was deleted, only that it's no longer present,
  which is indistinguishable from "we haven't synced yet." A subtle
  invariant rides along: when soft-delete fires, `updatedAt` must
  move to the same value as `deletedAt`. If it doesn't, last-writer-
  wins resolution would let any later edit on a peer beat the local
  delete, silently revoking it. This is verified in
  [`test/dao_soft_delete_test.dart`](test/dao_soft_delete_test.dart).

### Why not the alternatives

A document store (Firebase, Realm, Hive) would have made offline-first
easier in some ways — those tools have sync built in. They were
ruled out for two reasons. First, this app needs SQL queries
(joins, aggregates, complex filters) that document stores either don't
support or support poorly. Second, those tools are vendor lock-in;
SQLite is a public-domain file format that will outlive any startup.

A pure in-memory store with periodic JSON dumps to disk would have
been simpler initially but would have hit a wall at the first complex
query. SQLite is on the device anyway (every Flutter app ships with
sqflite); using it for what it's good at is the path of least
resistance.

### Where the seams are

[Migration v31](lib/database/migrations/v31.dart) is where this
foundation paid off. Adding the schema groundwork for sync required
zero changes to existing user-data tables — every row already had
the metadata sync needs (UUID, timestamps, soft-delete state).
v31 ships as new tables only: a registry of paired peer devices,
a tombstone log for hard-deletes on tables that don't have
`deletedAt`, and a conflict staging area for cases where local and
remote both edited the same row.

The actual sync runtime — peer discovery, the network transport,
the conflict-resolution logic, the photo reconciliation pipeline —
is not in this repo. It has since shipped in the product as a fully
local peer-to-peer engine (its shape is described at the end of §8),
and the schema published here is exactly the contract it runs
against. The separation is still deliberate: schema design and sync
runtime have different stability and review demands, and a working
sync engine is the kind of thing whose value depends on shipping
inside a coherent product, not on being readable as a reference.

---

## 3. Idempotent versioned migrations

### The problem

Schema evolution is one of the most failure-prone parts of any
database-backed app. Users skip versions (they don't open the app for
six months, then upgrade through five releases at once). Migrations
fail partway through and leave the database in a weird state.
Developers add a migration locally, ship it, and discover the
production database doesn't quite match what they assumed.

The naive migration runner crashes on any of these. The case study
claims this runner doesn't.

### The decision

The migration runner in
[`database_service.dart`](lib/database/database_service.dart) (the
`_onUpgrade` method) wraps every `db.execute()` call in a try/catch
that recognizes two specific `DatabaseException` messages as success:

- `'duplicate column name'` — emitted when an `ALTER TABLE ADD COLUMN`
  runs against a column that already exists.
- `'already exists'` — emitted when a `CREATE TABLE` or `CREATE INDEX`
  runs without `IF NOT EXISTS` against an object that's already there.

Both errors mean "the schema change was already applied," which is
the desired end state. The migration is treated as successful.

This is what makes the system idempotent in the strict sense: running
a migration twice produces the same end state as running it once. The
end state is what matters; the path doesn't have to be linear.

In practice, this covers two failure modes:

1. **Skipped versions.** A user upgrades through five versions at
   once. The runner iterates from `oldVersion + 1` to `newVersion`,
   running every migration in sequence. None of them assume the
   immediate previous version's state.
2. **State drift.** A user's database has a column the migration is
   trying to add, because of a long-resolved bug in an earlier
   release. The migration runs, hits the duplicate-column error,
   continues.

A third case, the partial migration, is handled by sqflite rather
than by the catch, and an earlier version of this document got it
wrong. It said that when a migration's third statement fails, the
first two "have already committed" and get re-run harmlessly next
launch. They don't commit. sqflite runs the entire `onUpgrade` call
inside one transaction, spanning every version from `oldVersion + 1`
to `newVersion`, and sets `user_version` inside that same
transaction. One failing statement rolls back the whole upgrade,
including earlier versions in the same launch, and the next open
starts again from the old version with nothing half-applied.
[`test/migration_transaction_test.dart`](test/migration_transaction_test.dart)
pins this down against the sqflite version this repo resolves
(sqflite 2.4.2+1, sqflite_common 2.5.6+1). One consequence, which
the postscript below runs into: transaction-hostile statements like
`PRAGMA foreign_keys` can't be used inside a migration.

### Why not the alternatives

`IF NOT EXISTS` clauses on every CREATE statement and "check if
column exists before ALTER" guards on every ADD COLUMN would have
worked, but they require remembering to write the guard on every
single migration forever. Forgetting once is a bug. Putting the guard
in the runner means every migration gets it for free.

A migration framework (sqflite_migration, drift, etc.) would have
provided more structure. The cost is a dependency that has to keep
working across Flutter versions, and an abstraction that's harder to
reason about than 30 lines of plain Dart. The runner here is small
enough to read in one sitting and modify when the requirements
change.

A "delete and recreate the database" approach is what some apps do
on schema mismatch. That's catastrophic for an offline-first app
because the local database *is* the user's data. There's no remote
to restore from.

### Where the seams are

The runner in this cut catches two specific exception strings. If
SQLite changes the wording of either error message in a future
version, the runner will incorrectly rethrow. When this document was
first written, the note here said "the right long-term fix is
matching on a richer error type if sqflite ever exposes one" — and
the production runner has since done exactly that for the case
sqflite covers: the duplicate-column check now goes through
sqflite's typed `isDuplicateColumnError()` helper. There is no typed
helper for `'already exists'`, so that one is still a string match,
now pinned in a comment to the sqflite_common version it was tested
against so a dependency bump and the string check get reviewed
together. Half the fragility retired, half documented — which is
about how these seams usually close.

The production runner also gained a diagnostic obligation this cut's
runner doesn't carry: it logs the version trail (`migrating schema
vX → vY`, and on failure the exact migration and statement index)
through the local logging layer described in §9. A rethrow here
aborts startup, and the log is the only artifact that survives to
explain why.

And the runner is no longer the only migration lane. Once the app
split into a craft-agnostic core plus per-craft modules (§10),
global numbering stopped being safe: two builds compiling different
modules would both call their schema "v46" while meaning different
things. Core keeps the numbered chain described here. Each module
now carries its own version, tracked in a `module_schema` table
(production v45) and applied by a second, much smaller runner that
reuses this one's idempotency tolerance verbatim. §10 has the
details; the point for this section is that the two-string catch
turned out to be reusable infrastructure, not a one-off.

### Verified by

[`test/migration_idempotency_test.dart`](test/migration_idempotency_test.dart)
exercises the contract directly. It drives the runner's catch block
with statements that hit each recognized error (re-running v12's
`ADD COLUMN`s, re-creating an existing table and index) and with one
that fails for an unrelated reason, which must be rethrown. It
re-runs every v36 statement on top of an already-current schema and
asserts that no exception escapes. And it asserts that
`DatabaseService.kSchemaVersion` ([database_service.dart](lib/database/database_service.dart))
equals the highest version registered in `SchemaScripts.migrations`
([schema_scripts.dart](lib/database/schema_scripts.dart)), and that
every registered version has at least one statement. That catches
the "bumped the constant to NN but forgot to register vNN" slip,
which would silently leave the new migration unrun on upgrade. It
doesn't check that every version below the top is registered: gaps
are expected, because this repo publishes a subset.

### A production postscript: the foreign keys were decorative

The hardest migration the production app has shipped since this cut
was published is a lesson about SQLite defaults, and it belongs in
this section even though the migration itself (pottery-domain table
rebuilds) is not republished here.

SQLite ships with foreign-key enforcement **off**, per connection.
Every `ON DELETE CASCADE` in a schema is decorative until someone
runs `PRAGMA foreign_keys = ON`. The production app ran that way
for thirty-three schema versions. When the pragma was finally
flipped, it surfaced a dormant corruption: an early table rebuild
(rename the parent to `pieces_old`, create the new table, copy rows,
drop the old one) had triggered SQLite's rename-tracking, which
rewrote the *child* tables' FK clauses to follow the rename — so
four tables spent years declaring `REFERENCES pieces_old(id)`
against a table that no longer existed. With enforcement off,
silent. With enforcement on, every INSERT into those tables fails
with "no such table."

The repair (production v34) rebuilds each affected child with the
same rename → create → `INSERT INTO … SELECT` → drop dance, FK
pointed at the live parent, orphaned rows filtered out. The
filtering is itself a lesson: the first attempt tried `PRAGMA
foreign_keys = OFF` at the top of the script, but sqflite wraps
`onUpgrade` in a transaction and SQLite silently no-ops that pragma
inside one. A follow-up (production v35) fixed tables whose inline
`REFERENCES` had no `ON DELETE` clause at all — which defaults to
RESTRICT, so the moment enforcement went live, "delete this row"
became a constraint failure on any row with children.

Four transferable rules fell out: enforcement is a per-connection
pragma, so it belongs in the database's `onConfigure` hook, not in a
migration; flipping it on a mature schema is a migration-sized event,
not a one-line change; a table-rebuild migration must account for the
children, not just the parent; and `PRAGMA foreign_keys` cannot be
toggled inside a transaction, so a migration runner that wraps
scripts in one (as sqflite's does) constrains what your repair
scripts can do.

---

## 4. The DAO pattern

### The problem

A medium-sized app accumulates SQL. By the time you have fifteen
tables and a dozen queries per table, you're looking at hundreds of
strings of raw SQL scattered across UI code, view models, and ad-hoc
service classes. This makes refactoring slow (you have to find every
caller), reviews hard (a bad query in a UI file goes unnoticed), and
testing brittle (every test has to mock the database from scratch).

The architectural problem is: where does the SQL live, and who is
allowed to write it?

### The decision

Database access is split across domain-specific
[DAOs](lib/services/dao/), one per table. Application code never sees
raw SQL; it calls typed methods on a DAO, which owns the SQL for its
domain. Each DAO follows the same pattern:

- Constructor takes a `DatabaseService` reference.
- Reads return typed model objects, not raw maps.
- Soft-delete is the default; hard `DELETE` is reserved for cleanup
  jobs that aren't part of the application code path.
- Reads exclude soft-deleted rows by default (`WHERE deletedAt IS
  NULL`).

The
[DatabaseService](lib/database/database_service.dart) exposes each
DAO as a `late final` field. Application code reads
`databaseService.notes.create(...)` rather than
`databaseService.createNote(...)` — the DAO is the explicit subject
of every database operation, not an implementation detail.

This sounds like a small distinction. It matters because every method
on a DAO can be reviewed in the context of all the other methods on
that DAO. SQL bugs cluster — if you have a query that misses
`deletedAt IS NULL`, you probably have several. Putting them all in
one file means a code review on that file catches the pattern;
scattering them across UI files means each one has to be caught
individually.

### Why not the alternatives

A repository pattern (interface + multiple implementations) would
have added abstraction the app doesn't currently need. There's only
one implementation: SQLite. Adding the interface would let us swap
backends in tests, but the cost of running tests against an in-memory
SQLite is so low (sqflite supports `:memory:` natively) that the
abstraction earns nothing.

An ORM (drift, floor) would have made simple CRUD trivial and
complex queries painful. The complex queries — joins, aggregates,
custom filters — are where the actual interesting work happens, and
ORMs typically make those harder, not easier. Hand-written SQL keeps
the hard cases simple at the cost of the easy cases being slightly
more verbose.

### Where the seams are

The DAOs in this repo are typed concretely against the
`DatabaseService`. Splitting them behind an interface would be
straightforward (`abstract class NotesDao` with `class
SqliteNotesDao implements NotesDao`) if a non-SQLite backend ever
needed to plug in. There is no current pressure for this.

---

## 5. In-memory registries for synchronous lookup

### The problem

Some data is read constantly and changes rarely. The list of
pipelines and the set of stages each pipeline contains are read
every time a piece is rendered — multiple times per screen, dozens
of times per second during scrolling. Loading them from the database
every time would be expensive. Loading them through `FutureBuilder`
would clutter the widget tree and introduce loading flickers on every
read.

The architectural problem is: how do you make rarely-changing data
synchronously available to the UI without coupling the UI to the
database?

### The decision

[`PipelineRegistry`](lib/services/pipeline_registry.dart) and
[`StageRegistry`](lib/services/stage_registry.dart) are in-memory
singletons that hold the full list of pipelines and stages. They are
populated once at app startup, after the database is open
(`DatabaseService.instance.loadPipelineRegistry()` and
`loadStageRegistry()` in `main.dart`), and exposed as synchronous
getters thereafter. `StageRegistry` additionally pre-loads the
built-in stages from the [`BuiltInStage`](lib/models/built_in_stage.dart)
enum at construction time, so even before any DB load the built-in
stages are available — `loadCustom()` only adds the user-created
ones to the unified view. (In production the enum has been replaced
by stage packs that compiled modules contribute; see §1 and §10.
The registry's shape didn't change, only where its built-ins come
from.)

The registries deliberately don't auto-refresh. When application code
creates, updates, or deletes a pipeline, it's the caller's
responsibility to call `loadPipelineRegistry()` again to refresh the
cache. This means the registry's loading semantics are explicit — a
reader can tell from the call sites exactly when the cache is
populated and refreshed, rather than having to reason about implicit
invalidation.

The cost is one bug class: if a caller forgets to refresh after a
mutation, the UI will show stale data until the next launch. The
benefit is no surprises — reads are always synchronous, always cheap,
and never racy.

### A note on this published cut

These registries are part of the workflow-engine sketch from §1. The
loaders themselves (`load`, `loadCustom`, the singleton accessors,
the null-tolerant `get(String? id)` lookup) are the architecturally
interesting part and are fully present. What's missing is the
underlying tables: `loadPipelineRegistry()` calls `pipelines.getAll()`
which queries `pipeline_types`, and `loadStageRegistry()` calls
`customStages.getAll()` which queries `custom_stages`. Neither table
is created by any migration in this published cut, so the startup
calls in `main.dart` would crash on a real run. The pattern is what's
on display; the wiring would be completed by the migrations referenced
in §1 above.

### Why not the alternatives

A `ChangeNotifier` listening to the DAO would have provided automatic
invalidation. The cost is hidden behavior — a write somewhere in the
app triggers a refresh somewhere else, with no visible coupling.
Debugging "why is my list out of date" or "why did this re-render"
becomes harder.

A streaming query (sqflite_async, drift's streams) would have
provided always-fresh data. The cost is async-everywhere — every
read becomes a stream subscription, which is a heavy pattern for data
that changes once a week.

Loading on every read with a thin in-memory cache would have worked
but is harder to reason about than a registry that's explicitly
populated and explicitly refreshed.

### Where the seams are

The "explicit refresh" model assumes a single-process app. The
registries hold mutable in-memory state; if multiple processes ever
share the same database file, each process has its own registry and
its own view of the world.

Concretely: built-in stages are compiled into the binary (an enum
here, module stage packs in production) and are identical across
processes — that part is fine. Custom stages and
pipelines are DB-backed, so a write from process A would leave
process B's cache stale until B calls `loadCustom()` or `load()`
again. The same staleness applies to any settings layer that caches
DB values in memory.

The fix isn't a registry-API change; the registries already expose
the right reload methods. The fix is a process-to-process
notification mechanism — polling the DB on a timer, watching the
SQLite file for changes, or a named-pipe IPC channel between windows
— that triggers a reload in the other process when a mutation
happens.

Flutter on Windows currently spawns a separate OS process per app
instance, so there's no shared Dart memory anyway, which is why
this hasn't come up. SQLite itself handles concurrent file access
safely via file locking; the architectural gap is at the cache
layer, not the database layer.

Composing built-ins from several packs opened a second seam that
production has already closed. Stage ids are one global namespace,
and `get(id)` returns the first match, so two craft modules that
both shipped a `drying` stage would silently render one craft's
label on the other's pieces. That can't be repaired after the fact,
because the ids are persisted in user rows. The composed list is
now asserted unique at the first lookup, so a colliding pack fails
in debug and test builds rather than in someone's data.

---

## 6. Cross-platform sqflite

### The problem

Flutter targets six platforms — iOS, Android, Windows, macOS, Linux,
web — and SQLite has a different installation story on each. Mobile
ships with the OS-level SQLite via `sqflite`. Desktop needs the FFI
variant `sqflite_common_ffi`. Web doesn't have SQLite at all and
needs a wasm-compiled version through `sqflite_common_ffi_web`.

A naive cross-platform app either picks one platform and breaks the
others, or branches at runtime with `if (Platform.isWindows) ...`
checks scattered through the code.

### The decision

[`database_initializer.dart`](lib/database/database_initializer.dart)
uses Dart's conditional imports to route mobile/desktop and web to
different implementation files at compile time:

```dart
import 'database_initializer_io.dart'
if (dart.library.html) 'database_initializer_web.dart';
```
The IO version handles desktop FFI initialization; the web version is
a no-op. The main file's `initDatabase()` is a single async call that
the rest of the app makes once, at startup, with no awareness of
which platform it's running on.

This isn't a clever trick — it's the standard Flutter pattern for
platform-conditional code. It earns a place in this document because
the case study claims "all data stored locally via sqflite" without
mentioning that this requires three different storage backends to
work. Publishing the initialization files makes the multi-platform
claim verifiable.

### Why not the alternatives

A runtime `Platform.isXxx` check would have worked but couples every
caller to platform awareness. The conditional import means platform
code is fully isolated.

Picking one platform and skipping the others was the alternative for
many apps' first version. It works until users on the unsupported
platforms complain. Doing the cross-platform work upfront — even
when it's just a no-op stub for web — is cheaper than retrofitting
later.

### Where the seams are

The web version is a no-op because the production app doesn't
currently target web. If web support became a priority, the web
initializer would need to actually configure
`sqflite_common_ffi_web`, and there'd be additional work to handle
file paths (web has no filesystem) and sync (web users would expect
multi-device sync to "just work" in a way mobile users don't). None
of that work exists in this repo because none of it has been done in
the product.

---

## 7. Local-only backup and restore

### The problem

Users of an offline-first app are responsible for their own data
durability. There is no cloud the app is mirroring; if the device
breaks, the data is gone. Some form of backup is non-negotiable.

The cheap answer is "add cloud backup." The right answer for an app
positioned around user data sovereignty is to let users back up to
wherever they want and never see the file.

### The decision

[`LocalBackupService`](lib/services/local_backup_service.dart) does
exactly two things: export the raw SQLite database file, and restore
it from a user-picked file. The implementation is platform-aware in
the same way as the database initializer, but for a different
reason — the OS conventions for "share a file" differ:

- **Mobile (iOS/Android):** OS share sheet via `share_plus`. The user
  picks Files, AirDrop, email, iCloud Drive, etc. The app never knows
  where the file ends up.
- **Desktop (Windows/macOS/Linux):** folder picker via `file_picker`.
  The app writes the backup to the chosen folder.

Either way, the exported file is a checkpointed snapshot, not a raw
copy of the live file. If the database is in WAL mode, recent commits
can still be sitting in the `-wal` sidecar, and copying the main file
alone would silently leave them out. Export runs `PRAGMA
wal_checkpoint(TRUNCATE)` first, which moves those pages into the
main file (and is a no-op outside WAL mode), then copies. `VACUUM
INTO` would also work, but needs SQLite 3.27+, which older Android
system builds don't have.

Restore is uniform across platforms: file picker, copy to a temp file
beside the live database, validate the copy, then swap it in.

The atomic-rename pattern is the architecturally interesting bit. The
file is copied to `database.db.tmp` first, checked, and only then
renamed over the live file. If anything fails before the rename, the
original is untouched. Rename is atomic on every supported OS — the
file system either knows about the new name or doesn't, never both.

Both of the steps around that rename were added after this cut was
first published, mirroring hardenings the production app made:

- **Validate before swap.** A corrupt backup, or a backup taken by
  a *newer* app version, used to replace the live database and only
  fail at the next open, which from the user's perspective bricked
  the app. The temp copy is now validated through a read-only
  connection before anything touches the live file: the SQLite header
  magic, a `PRAGMA quick_check`, and a `PRAGMA user_version` that must
  be less than or equal to the app's `kSchemaVersion`. Older backups
  are fine (the migration runner in §3 upgrades them on next open);
  newer ones are rejected with a message instead of a crash. The
  version gate is the same philosophy the sync engine applies on the
  wire (§8): data files only move forward through the migration
  runner, never backward.
- **Close before delete, sidecars included.** The connection is
  closed with `DatabaseService.reset()` *before* the old file is
  deleted. On Windows the other order fails: the open SQLite handle
  locks the `.db` file, and the delete fails with "being used by
  another process." The live file's `-wal`, `-shm` and `-journal`
  sidecars are deleted with it, because a stale `-wal` beside the
  restored file would be replayed into it on the next open, and a
  stale `-journal` would be treated as a hot journal and rolled back
  into it.

[`test/local_backup_test.dart`](test/local_backup_test.dart) covers
the rejections (a non-SQLite file, a too-new `user_version`), a
successful restore that clears stale sidecars, and an export taken
while the newest row exists only in the WAL.

### Why not the alternatives

Cloud backup (Firebase, S3, etc.) is the obvious alternative and was
deliberately ruled out. The product is positioned around the idea
that the user's data is theirs — backups go where the user puts them,
and the app has no opinion. This isn't just a feature decision; it's
a privacy decision. There is no API call leaving the device unless
the user makes it.

App-managed iCloud/Drive sync would have hit similar concerns plus
the additional cost of debugging cloud sync edge cases on a
solo-developed product.

A custom backup format (JSON dump, SQL exports) would have made
backups platform-portable but added a transformation step that could
fail. The raw `.db` file is portable to any other device running the
same app version, which is the only portability the user actually
needs.

### Where the seams are

Backups don't currently include media files attached to notes (in
the production app: photos of pieces; in this cut: any external file
a note references). The `.db` file stores file paths that point at
the originating device's filesystem; restoring on a different device
would leave those references broken. This is still a known
limitation of *backup*. The sync engine, by contrast, has since
solved it for the device-to-device case — and the way it did so is
an honest footnote on schema-first design. The v31 sync foundation
added a `syncSourceDevice` column as the hook a future
media-reconciliation runtime was expected to read. The runtime that
actually shipped doesn't use it: each sync delta carries a photo
manifest, and the receiving device lazily pulls any file that has a
database row but no file on disk, keyed on the path's existence
rather than on provenance. The column sits in the schema, nullable
and unread. That's the accepted cost of designing schema ahead of
runtime: some anticipatory columns turn out unnecessary, and at 36
bytes of nullable TEXT, being wrong was nearly free.

---

## 8. Sync-ready schema from day one

### The problem

Most apps add cloud sync as an afterthought, and the retrofit is
painful. The existing schema typically uses integer primary keys
(which collide on merge), lacks change-tracking timestamps, and
hard-deletes rows (so peers can't learn about deletions). Adding
sync requires migrating every existing table.

The architectural problem is: what does it cost, today, to design a
schema that won't need that retrofit later?

### The decision

The universal-columns convention from
[v01](lib/database/migrations/v01.dart) — UUID primary keys, ISO
8601 timestamps, soft-delete via `deletedAt` — was designed with
future cloud sync in mind. None of these columns are needed for the
single-device case. They cost almost nothing in storage (a UUID is
36 bytes; a timestamp is 24). They cost nothing in code complexity
(every model already has them). And they completely eliminate the
schema-migration cost when sync arrives.

[Migration v31](lib/database/migrations/v31.dart) is where the bet
paid off. Adding the schema groundwork for cloud sync required zero
changes to existing user-data tables — every row already had the
metadata sync needs. v31 ships as new tables only:

- A `sync_trusted_devices` registry, treating peer devices as
  durable database rows rather than ephemeral connection state.
- A `sync_hard_delete_log` tombstone table, for the (rare) tables
  that hard-delete rows. Most user-data tables soft-delete via
  `deletedAt` and can be synced by reading that column directly;
  these tombstones cover the join tables that don't.
- A `sync_conflicts` staging area for cases where local and remote
  both edited the same row since the last sync. Rather than
  silently auto-resolving (which is always wrong some of the time),
  the conflict is staged for manual resolution on next sync.

The `syncSourceDevice` column added to the notes table is the only
existing-table change in v31, and it's nullable — old rows leave it
null and don't break. (In the production app the same column is
added to the tables that hold media references; in this cut, notes
stand in for that role.)

[Migration v36](lib/database/migrations/v36.dart) is the second
piece of evidence in the same file. v31 created
`sync_hard_delete_log` with `id TEXT PRIMARY KEY` and a non-unique
index on `(tableName, rowId)`. Both the DAO write path and the sync
inbound path generate a fresh random `id` per insert, so an `INSERT
OR IGNORE` on the random PK never trips and duplicates accumulate.
v36 dedupes the table, drops the v31 index, and replaces it with a
UNIQUE one — the kind of change that, on any other architecture,
might require a backfill across user-data tables. Here it doesn't,
because the user-data tables aren't affected: the sync schema's
contract with the rest of the database is one-way (sync reads,
user-data writes, never the inverse). Tightening one end of that
contract is local to the sync schema. The second-payoff story
matters more than the technical fix: it's the same pattern as v31,
the second time, and it stays cheap for the same reason.

(A numbering note: every migration published here carries its
production number, v36 included. Production's v32 added the pairing
token, v33 import provenance, v34–v35 the foreign-key repair
described in §3, and v36 is this exact tombstone hardening, with
identical SQL. An earlier revision of this document said otherwise;
it was wrong. Production has since moved on to v45.)

Production's own recent schema work keeps making the same point.
Its v32 gave the device registry an authentication credential — one
nullable `ALTER TABLE ADD COLUMN`. Its v44 answered a diagnosability
problem: the only persisted sync state was a per-device
"last synced at" watermark, so "sync has been failing for a week"
was invisible — the status screen could only describe the current
moment. The fix is a `sync_log` table recording every sync attempt
(success or failure, with row/photo/skip/conflict counts), pruned to
the newest 50 rows on insert so it can never grow unbounded. Its
`deviceId` is deliberately *not* a foreign key, so history survives
unpairing the peer. Once again: new table, zero changes to user-data
tables.

### Why not the alternatives

The alternative is the retrofit path most apps end up on: ship with
auto-increment integers and `DELETE` statements, then later spend
weeks migrating every table when sync becomes a requirement. The
cost of doing it right upfront is the difference between two columns
and a migration that touches every table in the app.

CRDT-based data structures (Y.js, Automerge) would have made sync
easier in some ways but at the cost of a much heavier abstraction
than this app needs. CRDTs are designed for collaborative editing —
multiple users editing the same document simultaneously. The use case
here is a single user with multiple devices, which is much closer to
the traditional client-server model with last-writer-wins as a
reasonable default.

### The runtime that shipped against this contract

When this document was first written, this section ended with "the
sync runtime is the seam the next major write-up will fill." The
runtime has since shipped in the product. Its code is still not
published here — the schema remains the reference — but the shape
it took is worth recording, because it is a direct test of whether
the contract above was actually sufficient.

The topology is fully local peer-to-peer: no cloud, no coordinator.
Every device is simultaneously server and client — each runs an
embedded HTTP server on an ephemeral port and discovers peers over
mDNS on the local network. Pairing is a user-mediated PIN handshake:
the receiving device displays a short-lived PIN, the initiating user
types it, and a successful match mints a shared token that lands on
the `sync_trusted_devices` row (the production v32 column). Every
data endpoint thereafter requires that token as a bearer credential
— the device registry isn't just bookkeeping; it's the auth store.

The merge is last-writer-wins on `updatedAt`, with three
refinements the schema anticipated and one it didn't:

- **A per-peer watermark, not a global clock.** "What do I send
  you" is answered by the `lastSyncedAt` column on the trusted-device
  row — each peer relationship carries its own cursor, and
  `updatedAt` is compared per row only after the watermark has
  scoped the delta.
- **Clock-skew tolerance.** Two devices' clocks are never exactly
  aligned; timestamp differences under one second are treated as
  equal and skipped rather than resolved.
- **Soft-delete races resolve deterministically.** Because
  soft-delete bumps `updatedAt` to the same instant as `deletedAt`
  (the invariant from §2), "local deleted, remote edited later" has
  a defined winner in both directions — including resurrecting a
  row when the remote edit post-dates the local delete. Tombstones
  from `sync_hard_delete_log` are replayed with a re-creation guard:
  a local row created *after* the tombstone's `deletedAt` is a
  legitimate re-creation and survives.
- **The part the schema didn't decide:** conflict staging turned
  out to be a *mode*, not a mandate. The shipped default is
  automatic newer-wins; `sync_conflicts` and its side-by-side
  manual-resolution UI are an opt-in setting. The table is the
  contract; whether the runtime routes through it belongs to the
  user.

Two guard rails round it out. The first is a schema-version gate,
and it's a range rather than an equality check. Each device reports
its current version and a floor (`kSchemaVersionMin`, currently 37),
and two peers sync only when each sits inside the other's
`[min, current]` window. An earlier strict-equality check broke sync
on every additive migration, even though additive migrations are
exactly what the universal-columns convention makes safe. There is
still no translation on the wire; the floor only moves when a
migration lands that an older peer genuinely can't read, and the
migration runner (§3) remains the only component allowed to move
data between schema shapes. The second guard rail: photo files
travel outside the row delta entirely, as a manifest plus lazy
authenticated pulls (§7).

The modularization in §10 forced one more rule onto the merger.
Two builds can now report the same core schema version while owning
different tables, because a multi-craft build compiles modules a
single-craft build doesn't, and module composition isn't part of
the handshake. Before the fix, the first unknown table in a delta
threw *inside* the merge transaction and rolled back every other
table with it, so a single woodworking row meant a pottery-only
peer silently synced nothing, every round. The merger now checks
which tables exist locally, skips unknown ones (counting their rows
as skips so the sync summary shows them), and applies the same
check to tombstones. The list of tables a device *sends* is no
longer hardcoded either: it's composed from core's specs plus each
compiled module's declared tables, sorted into the same dependency
tiers the old hardcoded list used, and a golden test pins the
order.

So the contract held, with one honest amendment: the original
sentence here — any runtime "has to read from `updatedAt`, write to
`sync_conflicts` on unresolvable collisions, and respect the device
pairing in `sync_trusted_devices`" — describes the shipped engine
accurately, provided you read the second clause as conditional on
the user choosing manual resolution, and the third as having grown
teeth (pairing is now authentication, not just registration).

---

## 9. Privacy-first observability

*This layer shipped in the production app after this cut was
published. Like the sync runtime in §8, its code is not republished
here; it's documented because the architecture story is incomplete
without it, and because its constraints are the same ones §7
established.*

### The problem

An offline-first, no-account app has an observability problem shaped
by its own positioning. There is no server, so there are no server
logs. There is no telemetry, so there are no crash dashboards. In a
release build, an uncaught Flutter error simply vanishes — when a
user reports "it crashed while upgrading," there is nothing to look
at, and the failure most likely to produce that report is the one
§3 cares about most: a migration abort during startup.

The obvious fix — always-on crash reporting — contradicts the
privacy contract the rest of the architecture keeps: *nothing leaves
the device without an explicit user action* (§7). The architectural
problem is: how do you get diagnosable failures without breaking
that contract?

### The decision

Three layers, each inert until something goes wrong or the user
acts.

**A local diagnostic logger.** A singleton logger writes to an
in-memory ring buffer (the last ~400 entries) and, on native
platforms, to a size-capped rotating file pair (256 KB × 2 — a hard
~512 KB disk bound that still covers several sessions). Web gets
the memory-only variant through the same conditional-import seam as
§6. The design decisions are policy, not plumbing: timestamps are
UTC so entries are unambiguous across DST changes and comparable
with a peer device's diagnostics; `debug`-level entries reach the
console and the ring but never the disk (developer noise is not
diagnostics); writes are serialized so concurrent log calls can't
interleave lines; and the file sink is contractually non-throwing —
a broken logger must never take down the code being logged. The
logger works before it's initialized: early entries buffer in the
ring and flush to disk once the sink attaches, so the startup
window — the most failure-prone stretch of the whole app — is never
unlogged. Getting logs *off* the device is an explicit user action:
a "share diagnostics" flow hands the log files to the OS share
sheet, the same posture as §7's backups.

**Opt-in crash reporting, double-gated.** Remote crash reporting
(Sentry) exists but is gated twice. The build-time gate: the DSN
arrives as a compile-time define, and when it's absent the feature
is *compiled out* — the settings toggle isn't rendered and no
reporting code runs, which is the strongest available meaning of
"off." The runtime gate: a settings toggle that defaults to off and
must stay that way (the default is documented in code as a privacy
promise). What an opted-in crash sends is minimized to error type,
stack trace, app version, device model, and OS version. No user
identity, no session tracking, no screenshots — and no breadcrumbs:
the framework auto-collects UI and navigation crumbs that could
embed user content, so they are dropped wholesale (count zeroed
*and* per-crumb discard) rather than trusting a scrubber to catch
everything.

**A guarded startup path.** The logger initializes first, before
anything that can fail. Global handlers route uncaught framework and
async errors into the persistent log. The risky init sequence —
settings, then crash reporting, then the database open (which is
where §3's migration runner executes), then the registries and sync
— is wrapped in a single guard, deliberately ordered so crash
reporting is live *before* the riskiest step. On failure the app
doesn't die silently: it renders a zero-dependency error screen (no
theme service, no database reads — nothing that could itself fail)
with a copyable dump of the recent log, which includes the migration
version trail from §3. One subtlety: the guard's catch block
forwards the error to crash reporting explicitly, because a *caught*
error never reaches the global handlers.

### Why not the alternatives

Always-on "anonymous" analytics is the industry default and was
never really on the table — "anonymous" is a claim the user can't
verify, and this architecture prefers guarantees the user can
verify (data is local; you can watch the network). Dropping all
breadcrumbs instead of scrubbing them is the same instinct applied
at a smaller scale: deletion is verifiable, redaction is a promise.

Firebase Crashlytics would have been the conventional choice for
the crash-reporting slice. It ties the app to a vendor SDK that
initializes at startup and can't meaningfully be compiled out; the
DSN-gate approach means a build without the define contains no
reporting pathway at all.

A logging framework package would have provided levels, sinks, and
rotation off the shelf. But the interesting parts of this logger
are the local decisions — UTC, debug-never-persisted, non-throwing
sink, the ~512 KB bound — and a framework mostly adds surface area
around them.

### Where the seams are

Redaction is convention, not enforcement. The logging contract says
"log identifiers, counts, and error details — never user content,"
but nothing at runtime scrubs a call site that violates it. The
protection is review discipline, the same trade-off the
universal-columns convention makes in §2. A lint rule or a typed
message wrapper would harden it if the call-site count grows.

Dropping every breadcrumb means an opted-in crash report arrives
with no navigation context — sometimes the crash is only
reproducible if you know the screen path that led there. That's a
deliberate purchase of privacy at the cost of debuggability, and
the local log (which the user can choose to share alongside a
report) is the escape hatch.

And the retention window is tiny by design. Two 256 KB files are
enough to explain last night's crash, useless for "has this been
slowly degrading for a month." If long-horizon diagnostics are ever
needed, the bound is a constant — but raising it should be a
decision, not drift.

---

## 10. Maker modules: the craft as a plugin

*Like §8's runtime and §9, this shipped in the production app after
this cut was published, and its code is not republished. This cut
predates the split: its `lib/` is laid out the way production's was
before it.*

### The problem

My Pottery Studio was a pottery app all the way down. Kiln logs,
glaze recipes, and clay reclaim lived beside sales, clients, and
commissions, and nothing in the code distinguished them. But a
woodworker, a jeweller, or a glassblower needs nearly all of the
second group and none of the first. Two products wanted to come out
of the same codebase: the branded pottery app (already live, with
real user data that must not move), and a multi-craft app where the
user switches crafts on and off.

The architectural problem: how do you carve a craft out of an app
that was built as that craft, without migrating a single existing
user's data, and without the carve-out quietly growing back?

### The decision

Split the app into a **core** and **maker modules**. Core holds
everything any maker business needs: pieces and the pipeline engine
from §1, sales, clients, commissions, materials, photos, sync,
backup, settings, captions, the paywall. A module holds what makes a
craft different: its stage vocabulary, its default pipelines, its
own tables, and the screens and dashboard cards that sit on them.
Pottery became the first module. The business features stayed core
rather than becoming a "base business module", because no build
would ever exclude them, so modularizing them would buy only
indirection.

A module is one abstract class, `MakerModule`, where every member
has an empty default, so a new module compiles from its first line.
It declares data contributions (synced tables with their dependency
tier, a stage pack, pipeline seeds, its own migrations, material
consumption sources) and UI contributions (drawer entries, quick
actions, dashboard sections, piece-detail and piece-form sections,
settings rows). An entrypoint's config lists the modules to compile
in, and a composition root hands them to core's registries. Core
never imports a module.

Three rules make it hold.

**Compiled versus enabled.** Data-shaped contributions come from
every *compiled* module; UI-shaped ones come from *enabled* modules
only. Turning pottery off in the multi-craft app hides its drawer
entries and dashboard cards, but its tables keep syncing and its
stages keep resolving display names. A piece sitting at
`bisque_firing` still renders correctly after the toggle, because
the stage pack never stopped loading. Hiding is reversible;
forgetting data isn't, so the toggle is only ever allowed to hide.

**Two migration lanes.** The numbered chain from §3 is frozen as
history for the tables it already created, and keeps going for
craft-agnostic core changes only. Module tables migrate in their
own lane: a `module_schema` table records each compiled module's
version, and a small runner applies anything newer on every open.
Pottery sits at module version 0, since the legacy chain already
created its tables, so nothing was re-stated and there was no risk
window. A module added to a two-year-old install, or a pottery
backup restored into the multi-craft app, just migrates itself from
0 on next launch. `PRAGMA user_version` keeps meaning "core schema"
in every build, which is what keeps §7's backup version gate and
§8's sync handshake honest.

**The boundary is a test, not a convention.** A source-scanning
test fails the build if any core file imports a module, if any core
file so much as *names* a pottery type, or if one module imports
another. The universal-columns convention in §2 is enforced by
review and that's been fine; a dependency rule erodes one
convenient import at a time, so this one got a machine.

The data decisions all followed one principle: move code, never
rows. Pottery's columns on the `pieces` table (finished weight,
reclaim state, surface area) stayed exactly where they were. Moving
them to a satellite table would have rewritten every user's busiest
table inside a migration and changed how pieces merge in sync,
across devices that upgrade at different times. New modules follow
a different rule, keying their own tables by piece id. A planned
`Piece.extras` map for craft data on the core row was dropped before
it was built, because no module ended up needing it. The database
file is still named `pottery_studio.db` in every build, because
renaming it would orphan every existing install.

The proof was a second module. A skeletal woodworking module (one
stage pack, one pipeline, one table arriving through a real module
migration, one dashboard card) was added with zero edits to core
and one line in the multi-craft entrypoint. A test pins that claim
so a later change can't weaken it quietly.

### Why not the alternatives

Separate packages (a melos workspace with `studio_core` and
`studio_pottery`) were the textbook answer. They'd have bought
compiler-enforced boundaries at the cost of a package-per-module
build setup on a solo-maintained app. Folders plus a boundary test
get the same rule today, and they keep extraction a mechanical
`git mv` for whenever packages earn their keep.

Forking the app per craft would have been fastest for the second
product and the worst for every product after it. Every sync fix
from §8 would need porting N times.

A clean, consolidated fresh-install schema per build (so a
woodworking-only install never sees an empty `glaze_recipes` table)
would be tidier. It would also be a second creation path that has
to be proven equivalent to the one every existing install went
through. Fresh installs of every build still run the full legacy
chain, empty pottery tables included. Invisible clutter was the
cheaper risk.

### Where the seams are

Cross-composition sync is safe but lossy. §8's unknown-table skip
stops a multi-craft peer from breaking a pottery-only peer, but the
woodworking rows still don't arrive there. Passing unknown tables
through as opaque storage would fix that, and it's much more complex
than the problem currently warrants.

The deepest remaining coupling isn't a code question. Core's
`MaterialType` enum has ceramic members (`clay`, `reclaimClay`,
`commercialGlaze`), and the free tier's limit counts exactly those.
Generalizing the enum means deciding what "five free materials"
means in a build with no clay: five of anything, five per module,
or a per-module limit policy. Each answer prices the free tier
differently, so it's a monetization decision wearing a refactor's
clothes. It also needs a migration that keeps reading the old
persisted values.

Two cosmetic switches stay hardcoded on purpose: the piece-type
icon map and the firing-stage colours in the pipeline widget. An
unknown value falls through to a neutral default, so another craft
gets something bland rather than something wrong.

And the move itself had a cost worth recording. Relocating 203
files under `lib/core/` was meant to be logic-free, and almost was.
Four `return await` calls inside `try` blocks lost their `await`
along the way, so failures escaped the `catch` that was supposed to
turn them into result objects: a failed backup export threw instead
of reporting, and a peer's 401 could throw out of the sync call. The
analyzer's `unawaited_return_in_try_block` lint caught it, and the
restored lines now carry comments saying why the `await` matters. A
"pure move" is only pure if something checks.

---

## A note on what's missing

This document is structured around ten architectural decisions, but
real architecture isn't really decomposable into a list. The
decisions interact. The DAO pattern only works because the migration
runner is reliable. The registries only work because the schema is
queryable. The sync foundation only works because the universal
columns were established in v01. The observability layer earns its
keep at exactly the moments the others fail — its startup guard
exists to catch the migration runner's rethrow. And the module split
in §10 leaned on almost all of them at once: the registries became
its composition points, the migration runner's idempotency net
became its second lane, and sync had to learn to tolerate tables it
had never seen.

If you read this whole document and the code, what you should come
away with is not "here are ten clever things" but "here is a
coherent way of thinking about offline-first data architecture, where
each piece is shaped by the others." The ten headings are
pedagogical scaffolding; the architecture is the relationships
between them.

The relationships are also where this repo is most honest. The full
app is at schema v45 with new versions shipping on an ongoing basis;
six representative versions are published here, each under its
production number (v01, v11, v12, v26, v31, v36). The production
schema covers many tables across several domains and two craft
modules; this cut runs four (`notes`, `tags`, `note_tags`,
`categories`) and adds three more in the v31 sync foundation
(`sync_trusted_devices`, `sync_hard_delete_log`, `sync_conflicts`).
The workflow-engine tables that the sketched `Pipeline` /
`CustomStage` code would query (`pipeline_types`, `custom_stages`,
plus `pipelineId` / `currentStage` columns on notes) are not in this
cut — the runnable demonstration of their underlying pattern is
v26's categories migration. The sync runtime, the observability
layer, and the module system have shipped in the product; they are
described in §8, §9, and §10, but none of their code is here. What's
published is enough to demonstrate the patterns and verify the case
study's claims. It is not enough to clone-and-ship a competing
product, and that's deliberate.

---

[Back to README](README.md)