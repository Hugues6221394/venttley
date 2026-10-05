-- The ledger catches up with eight migrations that forgot to sign it.
--
-- 20261065090000 through 20261072090000 shipped and were applied without
-- calling record_migration(), so the database ran them and has no record of
-- having done so. That is only ever advisory — SchemaLedgerCheck logs a gap
-- and never refuses to start, which is the right trade on an app people open
-- when they are struggling — but an advisory check that cries wolf about eight
-- migrations that did in fact run is worse than no check: the next real gap
-- arrives in a warning nobody reads any more.
--
-- The call is idempotent (ON CONFLICT DO NOTHING), and those files now sign
-- themselves too, so a database built from scratch records each exactly once
-- and this migration does nothing. It exists for the databases where they have
-- already run.

SELECT public.record_migration('20261065090000', 'broadcast_visibility');
SELECT public.record_migration('20261066090000', 'media_review_preserves_deletion');
SELECT public.record_migration('20261067090000', 'access_review_ledger');
SELECT public.record_migration('20261068090000', 'staff_invitation_ledger');
SELECT public.record_migration('20261069090000', 'staff_invitation_setup_repair');
SELECT public.record_migration('20261070090000', 'staff_promotion_approvals');
SELECT public.record_migration('20261071090000', 'broadcast_approvals');
SELECT public.record_migration('20261072090000', 'governance_notifications');

SELECT public.record_migration('20261075090000', 'the_ledger_catches_up');

NOTIFY pgrst, 'reload schema';
