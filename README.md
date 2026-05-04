# Pottery Studio Architecture

A reference implementation of the offline-first, configurable-workflow
architecture behind [My Pottery Studio][mps] — a Flutter app for
ceramic artists that ships in private beta with the App Store and
Google Play submission in progress.

This repository is **not** the full app. It is a curated subset of the
architectural pieces that make My Pottery Studio interesting, extracted
into a generic notes-and-tags toy domain so the patterns can be read
without the ceramic-specific business logic getting in the way.

## What's here
```
lib/
├── database/          # Migration system + SQLite initialization
│   ├── database_service.dart           ← idempotent migration runner
│   ├── database_initializer*.dart      ← platform-conditional sqflite setup
│   ├── schema_scripts.dart             ← version → SQL registry
│   └── migrations/
│       ├── v01.dart                    ← initial schema, base columns
│       ├── v11.dart                    ← multi-table feature add
│       ├── v12.dart                    ← bulk ALTER TABLE pattern
│       ├── v26.dart                    ← config table replacing enum
│       ├── v31.dart                    ← sync foundation
│       └── v36.dart                    ← self-healing tombstone dedup
├── models/            # Domain models with the universal-columns pattern
└── services/          # DAOs + in-memory registries + local backup
└── dao/
├── notes_dao.dart              ← simple CRUD pattern
├── pipelines_dao.dart          ← workflow engine data layer
└── custom_stages_dao.dart      ← user-config CRUD pattern

test/                  # Verifies the contract claims in ARCHITECTURE.md
├── migration_idempotency_test.dart  ← §3 idempotency, v36 dedup, registration
└── dao_soft_delete_test.dart        ← §2 / §8 LWW invariant
```
About 26 source files. Substantial enough to demonstrate real
architecture; small enough to read in fifteen minutes.

## What this demonstrates

The architectural decisions documented in detail in
[ARCHITECTURE.md][arch], with the file in this repo where each one
is implemented:

1. **Configurable workflow engine** — pipelines, stages, and transitions
   stored as data rather than hardcoded enums, so users define their own
   production processes. *([pipeline.dart][pipeline], [v26.dart][v26])*

2. **Offline-first SQLite architecture** — every table designed from day
   one for future cloud sync via UUID primary keys and ISO 8601
   timestamps, so adding a backend later requires no migration to
   existing tables. *([v01.dart][v01], [database_service.dart][dbsvc])*

3. **Idempotent versioned migrations** — schema evolves through
   numbered SQL scripts where re-running a migration is always a no-op,
   so users who skip versions still upgrade safely.
   *([database_service.dart][dbsvc] — see the `_onUpgrade` method)*

4. **DAO pattern** — database access split across domain-specific DAOs,
   each owning the SQL for one table. Application code never sees raw
   SQL. *([dao/][dao])*

5. **Reactive registries with synchronous lookup** — pipelines and
   stages are loaded once at app startup into in-memory registries, so
   widget tree code never needs FutureBuilders for stable configuration.
   *([pipeline_registry.dart][pipereg], [stage_registry.dart][stagereg])*

6. **Cross-platform sqflite** — conditional imports route mobile,
   desktop, and web to the right SQLite backend without runtime checks.
   *([database_initializer.dart][init])*

7. **Local-only backup and restore** — atomic copy-then-rename restore
   with no cloud dependency. The user's data goes wherever they put it.
   *([local_backup_service.dart][backup])*

8. **Sync-ready schema from day one** — the universal-columns
   convention (UUID, timestamps, soft-delete) was designed so that
   adding sync later required no migration to existing tables. v31
   demonstrates the bet paying off: sync infrastructure ships as new
   tables only — a paired-device registry, a hard-delete tombstone
   log, and a conflict staging area — with every existing user-data
   table untouched. v36 is the second piece of evidence: tightening
   the tombstone log's uniqueness constraint after real use exposed
   that random PKs were defeating its `INSERT OR IGNORE`, again
   without touching any user-data table.
   *([v01.dart][v01] for the convention, [v31.dart][v31] for the
   first payoff, [v36.dart][v36] for the second)*

For a deeper walkthrough of why each decision was made, see
[ARCHITECTURE.md][arch].

## What's not here

This is a reference architecture. It is deliberately missing:

- **The UI layer.** No screens, widgets, or theming. Those exist in the
  full app and are not architecturally interesting in isolation.
- **Domain-specific code.** Glazes, kilns, sales, clients, commissions,
  inventory — all the things that make My Pottery Studio a *product*
  rather than a *pattern* — are not here.
- **The full migration history.** The production app is at schema v36+
  with new versions shipping on an ongoing basis. Six representative
  versions are published here, with their original numbers preserved so
  that v31's references to v01's universal-columns convention and v36's
  hardening of v31's `sync_hard_delete_log` remain coherent.
- **Authentication, monetization, sync runtime.** No auth flows, no
  in-app purchases. The schema groundwork that makes peer-to-peer
  sync possible is here (v31); the runtime that uses it lives in the
  product. That separation is deliberate — the schema is the contract
  any runtime would respect, and publishing the schema lets the
  contract be evaluated independently of any specific implementation.

If you're looking for any of those things, you're looking for a
different repo.

## Running the code

```bash
flutter pub get
flutter test          # the contract claims, verified
flutter run
```

The app launches to a placeholder screen. Its only purpose is to
demonstrate that the architecture compiles and the startup sequence
runs. The interesting code is in `lib/database/` and `lib/services/`,
not on screen.

The test suite verifies the architectural claims that ARCHITECTURE.md
makes — idempotent migrations, self-healing tombstone dedup, and the
last-writer-wins invariant that soft-delete depends on. Reading those
tests is a faster path into the codebase than reading the source
top-down.

## Why this exists

I'm a senior full-stack engineer and a practicing ceramic artist. My
Pottery Studio is the intersection — software I'm building because the
existing tools don't model how makers actually work. The architecture
in this repo is the answer to the problem "how do you build an
offline-first mobile app whose central abstraction is a user-configurable
state machine, in a way that's safe to ship and easy to evolve?"

The full product is private. This subset is public so the patterns are
verifiable. If you've read the [My Pottery Studio case study][mps] and
want to see whether the architectural claims hold up against actual
code, this is where to look.

## License

MIT — see [LICENSE](LICENSE).

The MIT license covers the architectural patterns and code in this
repository. The "My Pottery Studio" name, branding, and product
identity are not licensed for reuse.

## About

Built by [Cynthia Brown][site]. More work at:

- [cynthia-brown.com][site] — portfolio
- [mypotterystudio.com][mps] — the product this architecture powers
- [programmingpotter.com][pp] — ceramic work and writing
- [github.com/TitaniaAnn][gh] — other code

[mps]: https://mypotterystudio.com
[site]: https://cynthia-brown.com
[pp]: https://programmingpotter.com
[gh]: https://github.com/TitaniaAnn
[arch]: ARCHITECTURE.md
[pipeline]: lib/models/pipeline.dart
[v01]: lib/database/migrations/v01.dart
[v26]: lib/database/migrations/v26.dart
[v31]: lib/database/migrations/v31.dart
[v36]: lib/database/migrations/v36.dart
[dbsvc]: lib/database/database_service.dart
[dao]: lib/services/dao/
[pipereg]: lib/services/pipeline_registry.dart
[stagereg]: lib/services/stage_registry.dart
[init]: lib/database/database_initializer.dart
[backup]: lib/services/local_backup_service.dart