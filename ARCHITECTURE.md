# Architecture

This document is the long-form companion to the [README](README.md).
The README tells you *what* the architecture is and where each piece
lives. This document tells you *why* — what problem each decision
solves, what alternatives were considered, and where the seams are
that future work would extend.

The eight decisions below are roughly ordered from most foundational
to most product-facing. The earlier ones are the ones the rest depend
on; the later ones are the ones that would be easiest to swap out.

---

## 1. Configurable workflow engine

### The problem

The product this architecture serves is studio management for ceramic
artists. The central abstraction is a *piece* — a physical object that
moves through a multi-stage production lifecycle (clay preparation,
forming, drying, bisque firing, glazing, glaze firing, finishing,
sale). Different artists work different ways: a hand-builder skips the
throwing stage, a raku potter has a different firing schedule than a
stoneware potter, a production studio has stages a beginner doesn't.

The naive approach — a hardcoded enum of pottery stages — was the
first version of the app, and it was wrong on contact with users. Some
artists wanted stages we hadn't included; some wanted to skip stages
we'd assumed were universal; some wanted entirely different production
processes for different kinds of work.

The architectural problem is: how do you build a state machine where
the states themselves are user-defined?

### The decision

Pipelines, stages, and transitions are stored as data, not code. A
[Pipeline](lib/models/pipeline.dart) is a row in the database with a
JSON-encoded list of stage IDs in their canonical order. A
[StageDefinition](lib/models/stage_definition.dart) is the unified
representation of either a built-in stage (referenced by a stable
string ID like `'review'`) or a user-created
[CustomStage](lib/models/custom_stage.dart) (referenced by UUID).

[Migration v26](lib/database/migrations/v26.dart) is the migration
where this pivot happened. Before v26, pipelines were a hardcoded
enum; v26 introduced the `pipeline_types` table and seeded the
built-in pipelines with IDs that matched the existing enum string
values. Existing pieces continued to resolve to the correct pipeline
without any data migration — every `pieces.type` value already
referenced a pipeline ID that now existed in the new table.

That seeding trick — making old enum values into new primary keys —
is the bit worth pausing on. It meant the migration shipped without a
single row of data backfill. The existing schema's design decisions
(string-typed enum columns rather than integer-typed) made this
possible. It would not have worked with `int` enum columns indexed
into the old enum's `.values` list.

### Why not the alternatives

A more "proper" object-oriented design would have made each pipeline
type a subclass of an abstract `Pipeline` class, with the stages
defined as methods or constants. That works fine when pipelines are
known at compile time. It does not work when users define their own.

A workflow library (Temporal, Camunda, etc.) would have been the
enterprise answer. They're enormous, server-bound, and assume a
pipeline orchestrator that doesn't exist in a mobile app's process
model. The whole point of offline-first is that the workflow runs in
the user's hand, not on a server.

A finite state machine library would have been overkill. The actual
runtime logic is small enough that a custom implementation costs less
to maintain than a third-party dependency that we'd outgrow on the
first feature request that didn't fit its abstractions.

### Where the seams are

The architecture supports linear pipelines today. Branching pipelines
(where a piece can go to one of several next stages depending on
condition) are representable in the schema — `stages` is a list, but
nothing prevents extending it to a graph — but no UI or runtime logic
exists for them yet. If you wanted to add branching, the migration
would be small (a `transitions` table linking stage pairs); the work
is in the runtime that decides which branch to take.

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
createdAt TEXT NOT NULL       — ISO 8601 timestamp
updatedAt TEXT NOT NULL       — ISO 8601 timestamp, bumped on every write
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
is not in this repo. The schema is shaped to support a peer-to-peer
model rather than a client-server one, but the runtime that uses
the schema lives in the product. That separation is deliberate:
schema design and sync runtime have different stability and review
demands, and a working sync engine is the kind of thing whose value
depends on shipping inside a coherent product, not on being readable
as a reference.

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

In practice, this protects against three failure modes:

1. **Skipped versions.** A user upgrades through five versions at
   once. The runner iterates from `oldVersion + 1` to `newVersion`,
   running every migration in sequence. None of them assume the
   immediate previous version's state.
2. **Partial migrations.** A migration script has multiple statements;
   the third statement fails. The first two have already committed.
   On the next launch, the runner re-runs the same migration; the
   first two statements raise idempotency errors (caught), the third
   gets another shot.
3. **State drift.** A user's database has a column the migration is
   trying to add, because of a long-resolved bug in an earlier
   release. The migration runs, hits the duplicate-column error,
   continues.

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

The runner currently catches two specific exception strings. If
SQLite changes the wording of either error message in a future
version, the runner will incorrectly rethrow. This is a fragility
worth knowing about. Production has not been bitten by it yet, but
the right long-term fix is matching on a richer error type if sqflite
ever exposes one.

### Verified by

[`test/migration_idempotency_test.dart`](test/migration_idempotency_test.dart)
exercises the contract directly: it re-runs every v36 statement on
top of an already-current schema and asserts that no exception
escapes. It also asserts that every version registered in
`SchemaScripts.migrations` ([schema_scripts.dart](lib/database/schema_scripts.dart))
has at least one statement and that no registered version exceeds
`DatabaseService.kSchemaVersion` ([database_service.dart](lib/database/database_service.dart))
— catching the "bumped the constant but forgot to register vN"
slip that would silently leave the new migration unrun on upgrade.

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

## 5. Reactive registries with synchronous lookup

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
getters thereafter.

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

Concretely: built-in stages are compiled from a static enum and are
identical across processes — that part is fine. Custom stages and
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
  The app copies the `.db` file to the chosen folder.

Restore is uniform: file picker, validate the extension, copy to a
temp file, atomic rename over the live database, call
`DatabaseService.reset()` to drop the cached connection.

The atomic-rename pattern is the architecturally interesting bit. The
file is copied to `database.db.tmp` first, then the original is
deleted, then the temp is renamed. If the copy fails partway, the
original is untouched. Rename is atomic on every supported OS — the
file system either knows about the new name or doesn't, never both.

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

Backups don't currently include media files (photos attached to
notes/pieces). The `.db` file references file paths that exist on
the originating device's filesystem; restoring on a different device
would leave broken photo references. This is a known limitation —
the v31 sync foundation includes a `syncSourceDevice` column on
photo tables specifically to handle this, but the runtime that
uses it is not yet built.

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

The `syncSourceDevice` column added to photo tables is the only
existing-table change in v31, and it's nullable — old rows leave it
null and don't break.

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

### Where the seams are

The schema is sync-ready and a runtime exists in the product, but
neither the runtime nor a sanitized reference version is published
here. What's in this repo is the *contract* the runtime works
against — the shape of the data, the soft-delete and timestamp
conventions, the device registry and conflict staging tables. Any
runtime that respects this contract is sync-compatible with any
other.

This is the seam that the next major architectural write-up will
fill. The shape of the fill is constrained by the existing schema —
any sync runtime has to read from `updatedAt`, write to
`sync_conflicts` on unresolvable collisions, and respect the device
pairing in `sync_trusted_devices` — but the choice of *how* to do
those things is the next interesting design space, and one this
repo deliberately leaves open for now.

---

## A note on what's missing

This document is structured around eight architectural decisions, but
real architecture isn't really decomposable into a list. The
decisions interact. The DAO pattern only works because the migration
runner is reliable. The registries only work because the schema is
queryable. The sync foundation only works because the universal
columns were established in v01.

If you read this whole document and the code, what you should come
away with is not "here are eight clever things" but "here is a
coherent way of thinking about offline-first data architecture, where
each piece is shaped by the others." The eight headings are
pedagogical scaffolding; the architecture is the relationships
between them.

The relationships are also where this repo is most honest. The full 
app is at v31+ schema versions; only five are published here. The 
production schema covers thirty-three tables across eight domains; 
the public repo demonstrates the patterns with three. The sync runtime 
exists in some form on the develop branch; none of it is here. What's 
published is enough to demonstrate the patterns and verify the case 
study's claims. It is not enough to clone-and-ship a competing product, 
and that's deliberate.

---

[Back to README](README.md)