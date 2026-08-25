import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/schema_manifest.dart';

/// The ledger only works if the manifest stays true, and a list a human has to
/// remember to update is the same class of thing that let six migrations go
/// unapplied in the first place. So the repository checks itself: add a
/// migration without declaring it and these fail.
void main() {
  final dir = Directory('supabase/migrations');

  List<({String version, String name, File file})> migrationsFrom(String from) {
    final out = <({String version, String name, File file})>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.sql')) continue;
      final base = entity.uri.pathSegments.last;
      final match = RegExp(r'^(\d{14})_(.+)\.sql$').firstMatch(base);
      if (match == null) continue;
      final version = match.group(1)!;
      if (version.compareTo(from) < 0) continue;
      out.add((version: version, name: match.group(2)!, file: entity));
    }
    out.sort((a, b) => a.version.compareTo(b.version));
    return out;
  }

  test('the migrations directory is present', () {
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'run this from the repository root',
    );
  });

  test('every migration at or after the ledger is in the manifest', () {
    final onDisk = migrationsFrom(kLedgerVersion).map((m) => m.version).toList();
    final undeclared = onDisk
        .where((v) => !kExpectedMigrations.contains(v))
        .toList();
    expect(
      undeclared,
      isEmpty,
      reason:
          'Add these to kExpectedMigrations in lib/data/services/schema_manifest.dart '
          'so the app can tell when a database has not run them: $undeclared',
    );
  });

  test('the manifest does not claim migrations that do not exist', () {
    final onDisk = migrationsFrom(kLedgerVersion).map((m) => m.version).toSet();
    final phantom = kExpectedMigrations
        .where((v) => v.compareTo(kLedgerVersion) >= 0 && !onDisk.contains(v))
        .toList();
    expect(
      phantom,
      isEmpty,
      reason: 'kExpectedMigrations names files that are not on disk: $phantom',
    );
  });

  test('the manifest is ordered and free of duplicates', () {
    final sorted = [...kExpectedMigrations]..sort();
    expect(kExpectedMigrations, sorted, reason: 'keep it oldest-first');
    expect(
      kExpectedMigrations.toSet(),
      hasLength(kExpectedMigrations.length),
      reason: 'a duplicated version would mask a missing one',
    );
  });

  test('every migration at or after the ledger records itself', () {
    // A migration that does not write its row is invisible to the check, which
    // is worse than not having the check: it reports "up to date" for a
    // database that is not.
    final silent = <String>[];
    for (final m in migrationsFrom(kLedgerVersion)) {
      final sql = m.file.readAsStringSync();
      if (!sql.contains("record_migration(")) {
        silent.add('${m.version}_${m.name}');
        continue;
      }
      if (!sql.contains("'${m.version}'")) {
        silent.add('${m.version}_${m.name} (records the wrong version)');
      }
    }
    expect(
      silent,
      isEmpty,
      reason:
          'End each migration with:\n'
          "  SELECT public.record_migration('<version>', '<name>');\n"
          'Missing or wrong in: $silent',
    );
  });
}
