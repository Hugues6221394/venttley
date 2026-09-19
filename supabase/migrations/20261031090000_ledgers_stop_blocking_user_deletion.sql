-- A staff account that has generated an impact report cannot be deleted.
--
-- 20261026090000 added private.impact_report_snapshots with
--
--   generated_by  UUID REFERENCES public.users(user_id) ON DELETE SET NULL
--
-- and an immutability trigger that raises when generated_by changes:
--
--   IF ... NEW.generated_by IS DISTINCT FROM OLD.generated_by ... THEN
--     RAISE EXCEPTION 'immutable_report_snapshot';
--
-- Those two cannot both be satisfied. Deleting the account fires the SET NULL,
-- the SET NULL is an UPDATE, and the guard refuses it, so the delete fails.
-- This is the same defect 20261011090000 removed from audit_log.actor_id and
-- the security_events device columns, reintroduced on a new table.
--
-- It is latent rather than active: no snapshots exist yet, so nothing is
-- blocked today. The first staff member to generate a report and later leave
-- makes it real, and offboarding is a bad moment to discover it.
--
-- Measured, not inferred. Against a local database at this migration's parent:
--
--   INSERT INTO private.impact_report_snapshots (..., generated_by) VALUES (..., <staff>);
--   SELECT set_config('venttly.purging_account','on',true);
--   UPDATE private.impact_report_snapshots SET generated_by = NULL WHERE ...;
--   ERROR:  immutable_report_snapshot
--
-- Note the purge flag in that transcript. security_events solves the same
-- problem a different way: its guard makes a narrow exception for
-- `venttly.purging_account = 'on'`, which admin_delete_user sets for the
-- duration of the delete, so a member's own login history is erased with their
-- account. That is deliberate -- it is their personal data and erasure is the
-- point of a deletion request -- and 0026 asserts it. The impact guard has no
-- such exception, so the flag changes nothing there.
--
-- WHY DROP THE FOREIGN KEY RATHER THAN ADD THE EXCEPTION
--
-- Because the two columns mean opposite things. security_events.user_id is the
-- deleted member's own data, and should go. impact_report_snapshots.
-- generated_by is a *staff* member's name on a published artefact, and should
-- stay -- 20261011090000 made exactly this argument for audit_log.actor_id:
-- "Keeping the raw UUID means the ledger still answers 'who did this' after the
-- account is gone, which is the entire purpose of an audit trail." A report
-- whose author becomes NULL the moment they leave is not evidence of anything.
--
-- Immutability is untouched. The guard still refuses every direct UPDATE and
-- DELETE; only the cascade that was fighting it is removed.

BEGIN;

ALTER TABLE private.impact_report_snapshots
    DROP CONSTRAINT IF EXISTS impact_report_snapshots_generated_by_fkey;

COMMENT ON COLUMN private.impact_report_snapshots.generated_by IS
  'Which staff account generated the snapshot. Deliberately not a foreign key: '
  'the snapshot is immutable, so ON DELETE SET NULL would be an UPDATE its own '
  'guard refuses -- which made any staff account that had generated a report '
  'undeletable. The id is retained after the account is gone, because a '
  'published report whose provenance vanishes when its author leaves is not '
  'evidence. Same reasoning as audit_log.actor_id (20261011090000).';

SELECT public.record_migration(
  '20261031090000', 'ledgers_stop_blocking_user_deletion'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
