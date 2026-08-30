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

/// Versions the app requires, mapped to their names.
///
/// The name is carried because the version cannot be reported on its own: a
/// 14-digit timestamp matches the PII scrubber's phone-number pattern, so a
/// warning listing versions arrives as `[<scrubbed:phone>]` — it tells you
/// something is missing and not which thing. The name is digit-free, survives
/// intact, and is what you would search the migrations directory for anyway.
///
/// Add a migration here when you add it to supabase/migrations — the manifest
/// test fails until you do.
const Map<String, String> kExpectedMigrations = <String, String>{
  '20260826100000': 'schema_migrations_ledger',
  '20260827222451': 'complete_identity_mentions_music_rollout',
  '20260828120000': 'open_tribe_creation_with_age_floor',
  '20260828201411': 'revoke_client_truncate_defaults',
  '20260828230000': 'device_sessions_and_security_events',
  '20260829090000': 'idempotent_tribe_creation',
  '20260829180000': 'login_risk_scoring_and_security_alerts',
  '20260829200000': 'enforce_blocks_on_replies_and_existing_dms',
  '20260830090000': 'tribe_category_taxonomy',
  '20260830120000': 'media_quarantine_and_security_checkup',
  '20260831090000': 'tribe_rules_versioning',
  '20260901090000': 'granular_tribe_permissions',
  '20260902090000': 'fix_permission_grants_read_only',
  '20260903090000': 'auth_login_guard_hook',
  '20260904090000': 'login_record_via_jwt_hook',
};
