/// Migrations this build expects the database to have run.
///
/// Only versions from the ledger's own migration forward. Everything older
/// predates the ledger and cannot be known — this database has had files
/// applied by hand and out of order, so claiming anything about history would
/// be a guess recorded as a fact. Those are covered by the db.missing_columns
/// guard instead, which reports what a read path actually failed to receive.
///
/// Kept in sync with supabase/migrations by a test, not by discipline: the one
/// thing this list cannot afford is to drift quietly, which is the exact
/// failure it exists to catch.
library;

/// The version of the migration that created the ledger. A database whose
/// ledger is empty has not run it, and nothing newer can be reported until it
/// has.
const String kLedgerVersion = '20260826100000';

/// Versions the app requires, newest last. Add a migration here when you add it
/// to supabase/migrations — the manifest test fails until you do.
const List<String> kExpectedMigrations = <String>[
  '20260826100000', // schema_migrations_ledger
];
