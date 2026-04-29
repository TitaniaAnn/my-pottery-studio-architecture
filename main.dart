import 'package:flutter/material.dart';

import 'database/database_initializer.dart';
import 'database/database_service.dart';

/// Entry point for the architecture reference.
///
/// This is a minimal app whose only purpose is to demonstrate the
/// startup sequence: database initialization, migration runner, and
/// in-memory registry loading. The UI is intentionally bare — this
/// repo is about the architecture below the UI layer, not the UI
/// itself.
///
/// In a real app, replace [_RootPlaceholder] with your actual home
/// screen. Everything above that line is the architectural setup
/// you'd reuse verbatim.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ─── Architectural setup ────────────────────────────────────────
  // 1. Platform-conditional sqflite initialization (mobile/desktop/web).
  await initDatabase();

  // 2. Open the DB — runs any pending migrations on first access.
  //    Calling .database here forces the open before runApp so that
  //    any migration errors surface synchronously rather than during
  //    the first DAO call.
  await DatabaseService.instance.database;

  // 3. Hydrate the in-memory registries so pipeline/stage lookups
  //    are synchronous throughout the widget tree.
  await DatabaseService.instance.loadPipelineRegistry();
  await DatabaseService.instance.loadStageRegistry();

  runApp(const ArchitectureReferenceApp());
}

class ArchitectureReferenceApp extends StatelessWidget {
  const ArchitectureReferenceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Workflow Architecture Reference',
      home: const _RootPlaceholder(),
    );
  }
}

class _RootPlaceholder extends StatelessWidget {
  const _RootPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workflow Architecture Reference')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This is a reference architecture, not a runnable product.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            Text(
              'See README.md for an overview, ARCHITECTURE.md for the design '
              'walkthrough, and lib/database/ + lib/services/ for the code.',
            ),
            SizedBox(height: 24),
            Text(
              'On startup, the app has already:\n'
              '  • Initialized sqflite for the current platform\n'
              '  • Opened the database and run any pending migrations\n'
              '  • Loaded pipelines and custom stages into in-memory registries',
            ),
          ],
        ),
      ),
    );
  }
}