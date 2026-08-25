import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logger.dart';
import 'schema_manifest.dart';

/// Asks the database which migrations it has run, and reports the gap.
///
/// The point is to know *before* a person notices a symptom. Every defect this
/// week — letter avatars instead of faces, groups with no picture, music that
/// did nothing, a background only its owner could see — was an unapplied
/// migration presenting as a product decision, and each was found by someone
/// hitting it rather than by anything in the system saying so.
///
/// Advisory only, and deliberately so. A database behind the build degrades
/// features; refusing to start would turn a cosmetic gap into an outage, and on
/// an app people open when they are struggling that trade is not close.
class SchemaLedgerCheck {
  const SchemaLedgerCheck(this._client);

  final SupabaseClient _client;

  /// Versions the build wants that the database does not have.
  ///
  /// Empty when the database is current, when the ledger has not been created
  /// yet (nothing can be concluded), or when the check could not run.
  Future<List<String>> missingMigrations() async {
    final List<dynamic> rows;
    try {
      rows = await _client.from('schema_migrations').select('version');
    } on PostgrestException catch (e) {
      // The ledger migration itself has not run — the one gap this check cannot
      // report on, so say it plainly rather than implying the database is fine.
      //
      // Two codes, because the answer depends on who notices first. PostgREST
      // resolves the table against its own schema cache and answers PGRST205
      // before Postgres is ever asked; 42P01 is what comes back when the query
      // does reach the server. Only PGRST205 was observed on device — matching
      // 42P01 alone reported this as an unexplained failure.
      if (e.code == 'PGRST205' ||
          e.code == '42P01' ||
          e.message.contains('does not exist')) {
        log.warn(
          'schema.ledger_absent',
          props: {'migration': 'schema_migrations_ledger'},
        );
      } else {
        log.warn('schema.ledger_unreadable', props: {'code': e.code});
      }
      return const [];
    } catch (e) {
      log.warn(
        'schema.ledger_unreadable',
        props: {'reason': e.runtimeType.toString()},
      );
      return const [];
    }

    final applied = <String>{
      for (final row in rows.cast<Map<String, dynamic>>())
        if (row['version'] case final String v) v,
    };
    // Nothing older than the ledger can be judged: those migrations predate it
    // and left no trace, so their absence from the table means nothing.
    return [
      for (final version in kExpectedMigrations)
        if (version.compareTo(kLedgerVersion) >= 0 &&
            !applied.contains(version))
          version,
    ];
  }

  /// Runs the check and logs the result. Fire-and-forget at startup.
  Future<void> report() async {
    final missing = await missingMigrations();
    if (missing.isEmpty) return;
    // A list, not a joined string: the PII scrubber replaces any single value
    // over 120 characters with a length placeholder, which is how an earlier
    // diagnostic managed to report that something was wrong without saying
    // what.
    log.warn(
      'schema.migrations_missing',
      props: {'count': missing.length, 'versions': missing},
    );
  }
}
