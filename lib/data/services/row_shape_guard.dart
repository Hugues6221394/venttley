import '../../core/logger.dart';

/// Catches an unapplied migration before a person has to notice it.
///
/// PostgREST hands back a plain map. Select a table or view that predates a
/// column and the key is simply absent, so `row['whatever']` is null — which is
/// indistinguishable from a real null. Every consumer then does the reasonable
/// thing with nothing: a letter avatar instead of a face, a group with no
/// picture, an invite that reads as disabled, a member count stuck at its old
/// literal. Nothing anywhere says a migration is missing, and the gap presents
/// as a product decision until somebody complains about the symptom.
///
/// That has happened four times on this codebase: the profile banner offset,
/// a banner URL whose object was gone, the inbox peer photo, and then five more
/// inbox columns hiding behind the same silence.
///
/// So the row mappers declare what they expect, and the first row that does not
/// carry it says so, once, naming the migration to run.
///
/// Deliberately *not* an exception. A missing column degrades a screen; it must
/// not take the app down, and on an app people open when they are struggling
/// that trade is not close.
void expectColumns(
  String source,
  Map<String, dynamic> row,
  Map<String, String> columnsToMigration,
) {
  if (_reported.contains(source)) return;
  final missing = columnsToMigration.keys
      .where((column) => !row.containsKey(column))
      .toList();
  // Only latch once we have actually looked at a row, so an empty result set
  // does not burn the one report we get.
  _reported.add(source);
  if (missing.isEmpty) return;

  final migrations = <String>{
    for (final column in missing) _slug(columnsToMigration[column]!),
  }.toList()..sort();
  // Lists, not a joined string: the PII scrubber replaces any value over 120
  // characters with a length placeholder, and the first version of this
  // warning duly reported `<scrubbed:length=122>` — a diagnostic that told you
  // only that something was wrong. Each element is short, so each survives.
  log.warn(
    'db.missing_columns',
    props: {
      'source': source,
      'count': missing.length,
      'columns': missing,
      'migrations': migrations,
    },
  );
}

/// A migration's name without its timestamp.
///
/// The scrubber treats a run of seven or more digits as a phone number, so
/// `20260719000932_group_chat_membership_and_settings` reached the log as
/// `<scrubbed:phone>_group_chat_membership_and_settings` — losing precisely the
/// part you need to find the file. Loosening that pattern to save a filename
/// would be a bad trade on an app that handles real phone numbers, so the slug
/// goes instead: it identifies the migration on its own, and carries no digits
/// to trip over.
String _slug(String migration) => migration.replaceFirst(RegExp(r'^\d+_'), '');

final Set<String> _reported = <String>{};

/// Test seam: forget what has already been reported.
void resetColumnExpectations() => _reported.clear();
