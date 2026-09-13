-- Appeals against decisions that have no moderation case.
--
-- 0024 covers case-backed appeals. Everything here is the other two kinds, and
-- the reason they need their own file is that the case is where all the
-- integrity came from. Take the case away and the checks that read it stop
-- protecting anything while continuing to pass:
--
--   * Independence was `v_case.decided_by = v_actor`. With no case that is
--     NULL, the comparison is NULL, the IF does not fire, and the moderator who
--     suspended someone could review their own appeal — producing a record that
--     says the decision was independently confirmed. That is worse than having
--     no appeal, because it launders the original decision.
--   * moderation_case_events.case_id is NOT NULL and the insert was
--     unconditional, so deciding a non-case appeal aborted on a constraint
--     violation.
--
-- Neither could be reached before, because nothing could create a non-case
-- appeal. Both are asserted here against real roles rather than as the owner:
-- a SECURITY DEFINER function tested as postgres proves nothing about what a
-- member or a moderator can actually do.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(31);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ddd10000-0000-4000-8000-000000000001','avmoda','avmoda','x',
        'avmoda','avmoda','avmoda','super_admin','active',1990),
       ('ddd10000-0000-4000-8000-000000000002','avmodb','avmodb','x',
        'avmodb','avmodb','avmodb','super_admin','active',1990),
       ('ddd10000-0000-4000-8000-000000000003','avmember','avmember','x',
        'avmember','avmember','avmember','normal','active',1995),
       ('ddd10000-0000-4000-8000-000000000004','avother','avother','x',
        'avother','avother','avother','normal','active',1995);

SET session_replication_role = origin;

-- ===========================================================================
-- An account suspension
-- ===========================================================================

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
SELECT public.admin_suspend_user_ladder('ddd10000-0000-4000-8000-000000000003',
  'Repeated targeting after a warning.');
RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.notifications
    WHERE user_id = 'ddd10000-0000-4000-8000-000000000003'
      AND kind = 'moderation_action'),
  1, 'a suspension tells the member'
);

SELECT notification_id AS notice FROM public.notifications
 WHERE user_id = 'ddd10000-0000-4000-8000-000000000003'
   AND kind = 'moderation_action' \gset

SELECT is(
  (SELECT payload->>'appealable' FROM public.notifications WHERE notification_id = :'notice'),
  'true', 'and says it can be appealed'
);

SELECT ok(
  (SELECT payload->>'case_id' IS NULL FROM public.notifications WHERE notification_id = :'notice'),
  'a suspension carries no case id — the shape that had no appeal route at all'
);

-- The reference that makes independence enforceable. Without it the appeal has
-- nothing to compare the reviewer against.
SELECT ok(
  (SELECT (payload->>'decision_ref')::uuid IN (SELECT audit_id FROM public.audit_log)
     FROM public.notifications WHERE notification_id = :'notice'),
  'the notice points at the audit entry for the decision'
);

-- Staff identity must not reach the member. The reference is an id into a
-- table they cannot read; the pseudonym of the moderator is not in the payload.
SELECT ok(
  (SELECT payload::text NOT LIKE '%avmoda%'
     FROM public.notifications WHERE notification_id = :'notice'),
  'and does not name the moderator who took it'
);

-- ---------------------------------------------------------------------------
-- Filing
-- ---------------------------------------------------------------------------

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  format('SELECT public.submit_account_appeal(%L, %L)', :'notice', 'Not mine but I have the id.'),
  '%only appeal a decision about you%',
  'a notice id in someone else''s hands is not a way to act on it'
);
RESET role;

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);

SELECT lives_ok(
  format('SELECT public.submit_account_appeal(%L, %L)', :'notice',
         'I stopped as soon as I was asked. Please read the thread in order.'),
  'the member can appeal their own suspension'
);

SELECT throws_like(
  format('SELECT public.submit_account_appeal(%L, %L)', :'notice', 'Adding more detail.'),
  '%already have an appeal open%',
  'but only one at a time'
);
RESET role;

SELECT appeal_id AS acct_appeal FROM public.moderation_appeals
 WHERE enforcement_notification_id = :'notice' \gset

SELECT is(
  (SELECT original_decider_id FROM public.moderation_appeals WHERE appeal_id = :'acct_appeal'),
  'ddd10000-0000-4000-8000-000000000001'::uuid,
  'the appeal records who took the decision, resolved from the audit log'
);

-- A partial index, so col_is_unique cannot see it: the uniqueness only holds
-- where status = 'open', which is the point — a withdrawn appeal must leave
-- the slot free.
SELECT ok(
  (SELECT count(*) = 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'moderation_appeals'
      AND indexname = 'appeals_one_open_per_notice'
      AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%status = ''open''%'),
  'one open appeal per notice is enforced by an index, not only by the function'
);

-- ---------------------------------------------------------------------------
-- Independence — the check that silently passed for everyone
-- ---------------------------------------------------------------------------

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  format('SELECT public.admin_decide_appeal(%L, %L, %L)', :'acct_appeal', 'upheld',
         'I stand by my own decision.'),
  '%you took the decision being appealed%',
  'the moderator who suspended somebody cannot review the appeal against it'
);
RESET role;

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  format('SELECT public.admin_decide_appeal(%L, %L, %L)', :'acct_appeal', 'overturned',
         'I find in my own favour.'),
  '%forbidden%',
  'and the appellant cannot review it either'
);
RESET role;

-- ---------------------------------------------------------------------------
-- Deciding it, by somebody else
-- ---------------------------------------------------------------------------

SELECT is(
  (SELECT account_status FROM public.users WHERE user_id = 'ddd10000-0000-4000-8000-000000000003'),
  'suspended', 'the member is suspended before the appeal is heard'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
SELECT lives_ok(
  format('SELECT public.admin_decide_appeal(%L, %L, %L)', :'acct_appeal', 'overturned',
         'The order of messages does not support the finding.'),
  'a second moderator can decide it — and the NOT NULL case_id no longer aborts this'
);
RESET role;

-- Overturning has to undo the thing, or the record says the member won and
-- they are still locked out.
SELECT is(
  (SELECT account_status FROM public.users WHERE user_id = 'ddd10000-0000-4000-8000-000000000003'),
  'active', 'overturning an account appeal actually reinstates the account'
);

SELECT is(
  (SELECT count(*)::int FROM public.notifications
    WHERE user_id = 'ddd10000-0000-4000-8000-000000000003'
      AND payload->>'action' = 'appeal_overturned'),
  1, 'and the member is told the outcome'
);

SELECT is(
  (SELECT payload->>'appealable' FROM public.notifications
    WHERE user_id = 'ddd10000-0000-4000-8000-000000000003'
      AND payload->>'action' = 'appeal_overturned'),
  'false', 'an outcome is final at this tier'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  format('SELECT public.submit_account_appeal(%L, %L)', :'notice', 'Trying again.'),
  '%already been through appeal%',
  'and cannot be reopened by filing again'
);
RESET role;

-- ===========================================================================
-- A refused verification
-- ===========================================================================

INSERT INTO public.verification_requests (request_id, user_id, status, category)
VALUES ('ddd20000-0000-4000-8000-000000000001',
        'ddd10000-0000-4000-8000-000000000004', 'pending', 'creator');

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
SELECT public.admin_review_verification('ddd20000-0000-4000-8000-000000000001', false,
  'The links do not establish the claim.');
RESET role;

-- 20261014090000 rewrote this function for the new workflow and did not carry
-- the notice across, so a refused applicant was told nothing at all.
SELECT is(
  (SELECT count(*)::int FROM public.notifications
    WHERE user_id = 'ddd10000-0000-4000-8000-000000000004'
      AND payload->>'action' = 'verification_denied'),
  1, 'a refused applicant is told'
);

SELECT is(
  (SELECT payload->>'verification_request_id' FROM public.notifications
    WHERE user_id = 'ddd10000-0000-4000-8000-000000000004'
      AND payload->>'action' = 'verification_denied'),
  'ddd20000-0000-4000-8000-000000000001',
  'and the notice carries the request, so there is something to appeal against'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  'SELECT public.submit_verification_appeal(''ddd20000-0000-4000-8000-000000000001'', ''Not my application.'')',
  '%only the applicant%',
  'somebody else cannot appeal your verification refusal'
);
RESET role;

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
SELECT lives_ok(
  'SELECT public.submit_verification_appeal(''ddd20000-0000-4000-8000-000000000001'', ''The organisation page confirms the role; I can add a letterhead.'')',
  'the applicant can appeal it'
);
RESET role;

SELECT appeal_id AS ver_appeal FROM public.moderation_appeals
 WHERE verification_request_id = 'ddd20000-0000-4000-8000-000000000001' \gset

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  format('SELECT public.admin_decide_appeal(%L, %L, %L)', :'ver_appeal', 'upheld', 'Still no.'),
  '%you took the decision being appealed%',
  'the reviewer who refused it cannot hear the appeal against it'
);
RESET role;

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
SELECT lives_ok(
  format('SELECT public.admin_decide_appeal(%L, %L, %L)', :'ver_appeal', 'overturned',
         'The evidence was not weighed; this deserves a fresh review.'),
  'somebody else can'
);
RESET role;

-- Overturning says the refusal was wrong, not that the evidence has been
-- accepted. Auto-approving would hand out a badge nobody reviewed.
SELECT is(
  (SELECT status FROM public.verification_requests
    WHERE request_id = 'ddd20000-0000-4000-8000-000000000001'),
  'pending', 'an overturned verification appeal reopens the application'
);

SELECT ok(
  (SELECT NOT is_verified FROM public.users
    WHERE user_id = 'ddd10000-0000-4000-8000-000000000004'),
  'and does not grant the badge on the way past'
);

-- ===========================================================================
-- The queue has to describe what it is asking a moderator to review
-- ===========================================================================

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);

SELECT results_eq(
  format($q$SELECT subject_kind FROM public.admin_appeal_queue(NULL, 100)
             WHERE appeal_id IN (%L, %L) ORDER BY subject_kind$q$,
         :'acct_appeal', :'ver_appeal'),
  ARRAY['account', 'verification'],
  'the queue says which kind of decision each appeal is about'
);

-- Both are asserted after the appeals were decided, because that is when the
-- source rows move on: an overturned verification appeal sets the request back
-- to pending and clears reviewed_at, so a queue reading through to the live row
-- would report the appeal as being about a pending application with no date.
SELECT ok(
  (SELECT bool_and(original_decision IS NOT NULL AND decided_at IS NOT NULL)
     FROM public.admin_appeal_queue(NULL, 100)
    WHERE appeal_id IN (:'acct_appeal', :'ver_appeal')),
  'and describes the decision and its date rather than showing blanks'
);

SELECT is(
  (SELECT original_decision FROM public.admin_appeal_queue(NULL, 100)
    WHERE appeal_id = :'ver_appeal'),
  'verification_denied',
  'an overturned verification appeal still reads as being about the refusal'
);

SELECT is(
  (SELECT original_decider FROM public.admin_appeal_queue(NULL, 100)
    WHERE appeal_id = :'acct_appeal'),
  'ddd10000-0000-4000-8000-000000000001'::uuid,
  'the console can see who decided, so it can hide the controls it must'
);

RESET role;

-- A subject is still exactly one of three. Relaxing the constraint to add a
-- third kind is the easy way to end up with an appeal against nothing.
SELECT throws_ok(
  $q$INSERT INTO public.moderation_appeals (appellant_id, statement)
     VALUES ('ddd10000-0000-4000-8000-000000000003', 'against nothing at all')$q$,
  '23514',
  NULL,
  'an appeal must still be about exactly one decision'
);

SELECT * FROM finish();
ROLLBACK;
