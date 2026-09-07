-- Filing an appeal made a member's account undeletable. That is my bug, from
-- 20261004090000.
--
-- moderation_case_events.actor_id is a FK to users with ON DELETE SET NULL,
-- and case_events_append_only() refuses every UPDATE on the table. Deleting a
-- user therefore fires a cascade UPDATE that its own trigger rejects, so the
-- DELETE fails. submit_appeal() writes a case event with the appellant as the
-- actor, which means the act of contesting a decision quietly removed the
-- member's ability to have their account deleted — a deletion request would
-- fail with "moderation_case_events rows are immutable (op: UPDATE)" and no
-- indication why.
--
-- The FK is the part to remove, not the immutability. History that a cascade
-- can rewrite is not append-only, and the column does not need referential
-- integrity to do its job. Keeping the raw UUID is the correct behaviour for a
-- ledger: it records who acted, whether or not that account still exists.
-- (For staff actions the row also carries actor_role; member-filed events such
-- as an appeal leave it null, so the retained id is what makes those readable
-- after deletion, not the role.)
--
-- The same defect exists on public.audit_log.actor_id (FK with ON DELETE SET
-- NULL, plus audit_log_immutable()), and it predates this branch — both come
-- from 0022_admin_foundation.sql. Its effect is narrower but sharper: any
-- staff account that has taken a single audited action cannot be deleted,
-- which blocks the staff-offboarding item in the README's P2 list. Verified
-- both by construction. That one is NOT changed here: audit_log is the
-- privileged ledger, several access-review and retention questions hang off
-- it, and it should be a deliberate decision rather than a side effect of
-- fixing my own table.

ALTER TABLE public.moderation_case_events
    DROP CONSTRAINT IF EXISTS moderation_case_events_actor_id_fkey;

COMMENT ON COLUMN public.moderation_case_events.actor_id IS
  'Who acted. Deliberately not a foreign key: this table is append-only, so a cascade must never be able to rewrite it. The id is retained after the account is deleted, which is what a ledger requires.';

SELECT public.record_migration(
  '20261010090000', 'append_only_history_blocks_deletion'
);

NOTIFY pgrst, 'reload schema';
