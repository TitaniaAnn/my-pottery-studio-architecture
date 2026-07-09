# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **reference architecture**, not a runnable product. It publishes a curated subset of the offline-first SQLite + workflow-engine architecture behind My Pottery Studio, in a generic notes-and-tags toy domain. The README and ARCHITECTURE.md are the primary deliverables; the code exists to make their claims verifiable.

`flutter run` is **not wired up** in this cut: `main.dart` hydrates `PipelineRegistry` / `StageRegistry`, which query `pipeline_types` and `custom_stages` tables that no published migration creates. The canonical entry point is `flutter test`. See *Known broken state* below before changing anything.

## Commands

```bash
flutter pub get                                                  # install deps
flutter test                                                     # all tests (uses :memory: sqflite)
flutter test test/migration_idempotency_test.dart                # single file
flutter test --plain-name "v36 statements re-run without error"  # single test by name
flutter analyze                                                  # static analysis
```

Tests run against `:memory:` SQLite via `sqflite_common_ffi`; no Flutter device or emulator is needed.

## Architecture

Nine decisions documented in [ARCHITECTURE.md](ARCHITECTURE.md) — the last two (§8 sync runtime shape, §9 observability) describe production code that is not in this repo. The cross-cutting bits worth knowing before editing:

**Universal-columns convention.** Every user-data table created by a migration has the same five columns: `id TEXT PRIMARY KEY` (UUID, never autoincrement), `userId TEXT` (nullable, ready for a future backend), `createdAt TEXT NOT NULL`, `updatedAt TEXT NOT NULL`, `deletedAt TEXT` (soft-delete). Established in `lib/database/migrations/v01.dart`. Enforced by code review, not by a database constraint — any new table you add must follow it.

**Idempotent migration runner.** `DatabaseService._onUpgrade` ([lib/database/database_service.dart:109](lib/database/database_service.dart#L109)) catches two specific `DatabaseException` substrings — `'duplicate column name'` and `'already exists'` — and treats them as success. This is what makes `ALTER TABLE ADD COLUMN` and `CREATE TABLE` (without `IF NOT EXISTS`) safe to re-run. Migrations don't need their own guards; they get the guard for free from the runner. If you change the runner's catch logic, `migration_idempotency_test.dart` is the contract.

**Schema-version registration contract.** `DatabaseService.kSchemaVersion` must equal the max key in `SchemaScripts.migrations` ([lib/database/schema_scripts.dart](lib/database/schema_scripts.dart)). When you add a `vNN.dart` file, register it in the map AND bump `kSchemaVersion` to `NN`. The test suite catches the "bumped the constant but forgot to register" slip. The published file numbers 1, 11, 12, 26, and 31 preserve the production app's original numbering; production's numbering diverged after v31 (its own v32–v36 are unrelated migrations — pairing tokens, import provenance, FK repair, sync history log), so this repo's v36 is this cut's own number for the tombstone-hardening migration, not production's v36. Gaps in the sequence are expected and the runner tolerates them.

**Soft-delete LWW invariant.** `NotesDao.softDelete` ([lib/services/dao/notes_dao.dart:97](lib/services/dao/notes_dao.dart#L97)) writes `deletedAt` and `updatedAt` from a *single* timestamp variable, not two `DateTime.now()` calls. The two values must be byte-equal: a future sync layer resolves "local soft-deleted, remote edited" races by comparing `updatedAt`, and a delete that doesn't bump `updatedAt` would silently lose to any later peer edit. Any new soft-delete code path must preserve this. Verified by `test/dao_soft_delete_test.dart`.

**v36 `_rowid_` gotcha.** `lib/database/migrations/v36.dart` uses `_rowid_`, not `rowid`, because the `sync_hard_delete_log` table has a user column named `rowId`. SQLite identifiers are case-insensitive, so `rowId` shadows the implicit `rowid` and a `DELETE WHERE rowid NOT IN (...)` would silently no-op. If you write a migration that needs the implicit row identifier on a table with a same-cased user column, use `_rowid_`.

**Cross-platform sqflite via conditional imports.** `lib/database/database_initializer.dart` uses `import 'database_initializer_io.dart' if (dart.library.html) 'database_initializer_web.dart'`. The IO file initializes `sqflite_common_ffi` on Windows/Linux/macOS; mobile uses the platform plugin without setup; web is a no-op stub. There is no `Platform.isXxx` runtime branching in the rest of the codebase.

**Sync-readiness via new tables only.** `v31.dart` added the sync foundation (`sync_trusted_devices`, `sync_hard_delete_log`, `sync_conflicts`) plus a single nullable `syncSourceDevice` column on notes — *zero* changes to the columns of existing user-data tables. This is the central architectural bet of the universal-columns convention paying off, and is the model for any future sync-related schema work.

## Known broken state

This is curated reference code with documented gaps, not a clean checkout — keep the gaps in mind when changing anything in `services/` or `models/`:

1. **`flutter analyze` reports 8 errors.** `lib/services/dao/custom_stages_dao.dart` is truncated mid-expression at line 62-63 (`'${s.name.subst`). The whole project does not currently compile. The truncated method is `CustomStagesDao.toDefinition`, called from `DatabaseService.loadStageRegistry`. If you need the project to compile, finish that method (it converts a `CustomStage` to a `StageDefinition` with a truncated `shortName`).
2. **`pipeline_types` and `custom_stages` tables are queried but never created.** `pipelines_dao.dart` and `custom_stages_dao.dart` query these tables; no migration in `lib/database/migrations/` creates them. They live in the production app's later migrations, which are not in this published cut. `main.dart`'s registry-loading calls would crash at startup against the published schema.
3. **`Note.pipelineId` and `Note.currentStage` aren't in the schema.** The `Note` model declares them; no migration adds them to the `notes` table. `dao_soft_delete_test.dart` works around this by using a raw insert with the actual schema columns instead of `NotesDao.create()`. See the comment block at the top of that test file.

When asked to "make this work" or "fix the build," confirm scope with the user before touching items 2 and 3 — the docs explicitly describe the workflow-engine code as a sketch, and "fixing" it means writing additional migrations that change what the published cut demonstrates.

## Conventions specific to this repo

- New migrations go in `lib/database/migrations/vNN.dart` as `const List<String> vNN = [...]`. Register in `SchemaScripts.migrations` and bump `DatabaseService.kSchemaVersion`. Each statement is its own string — partial-failure recovery depends on the previous statements having committed.
- DAOs live in `lib/services/dao/`, one per table, take a `DatabaseService` in the constructor, return typed model objects, and exclude `WHERE deletedAt IS NULL` rows by default. New DAOs are exposed as `late final` fields on `DatabaseService`.
- New tables in migrations should include the five universal columns unless there's an explicit reason not to (the sync-internal tables in v31 omit them by design — they're infrastructure, not user data).
- Test docstrings name the ARCHITECTURE.md section they verify (`§2`, `§3`, `§8`). When adding a test for a documented architectural claim, follow the same convention so the contract→test mapping stays traceable.
