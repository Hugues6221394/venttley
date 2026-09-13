BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(28);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ee110000-0000-4000-8000-000000000001','verapplicant','v','x',
        'verapplicant','verapplicant','verapplicant','normal','active',1995),
       ('ee110000-0000-4000-8000-000000000002','verreviewer','v','x',
        'verreviewer','verreviewer','verreviewer','super_admin','active',1990),
       ('ee110000-0000-4000-8000-000000000003','verbystander','v','x',
        'verbystander','verbystander','verbystander','normal','active',1995);

SET session_replication_role = origin;

CREATE TEMP TABLE ver_probe(request_id UUID) ON COMMIT DROP;
GRANT SELECT, INSERT ON ver_probe TO authenticated;

-- ---------------------------------------------------------------------------
-- Applying
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"ee110000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT status FROM public.my_verification_state()),
  'not_applied',
  'an account that has never applied reports not_applied rather than nothing'
);

-- The per-element link rules live in the RPC because a CHECK constraint
-- cannot hold a subquery. That makes this the only thing enforcing them.
SELECT throws_ok(
  $$SELECT public.request_verification('c','creator',ARRAY['javascript:alert(1)'],NULL)$$,
  'P0001', 'invalid_link',
  'a link that is not an http(s) address is refused'
);

SELECT lives_ok(
  $$INSERT INTO ver_probe SELECT public.request_verification(
      'I run a peer-support group.', 'health_professional',
      ARRAY['https://example.org/about'],
      '[{"kind":"credential","detail":"RN licence 88213"}]'::jsonb)$$,
  'a structured application is accepted'
);

SELECT is(
  (SELECT count(*)::INT FROM public.verification_evidence
    WHERE user_id = 'ee110000-0000-4000-8000-000000000001'),
  1,
  'evidence is written through the RPC, which is the only writer'
);

-- One open application at a time. The partial unique index covers all three
-- open states, not just pending, so a second cannot be created while a
-- reviewer holds the first.
SELECT throws_ok(
  $$SELECT public.request_verification('again','creator',NULL,NULL)$$,
  'P0001', 'already_pending',
  'a second application cannot be opened alongside an open one'
);

-- ---------------------------------------------------------------------------
-- Evidence is not readable by other members
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" =
  '{"sub":"ee110000-0000-4000-8000-000000000003","role":"authenticated"}';

SELECT is(
  (SELECT count(*)::INT FROM public.verification_evidence),
  0,
  'another member cannot read anybody''s verification evidence'
);
SELECT is(
  (SELECT count(*)::INT FROM public.verification_requests),
  0,
  'another member cannot read anybody''s application'
);
SELECT throws_ok(
  $$SELECT public.admin_verification_queue(NULL, NULL, 10)$$,
  'P0001', 'forbidden',
  'an ordinary member cannot read the review queue'
);
SELECT throws_ok(
  $$SELECT public.admin_revoke_verification(
      'ee110000-0000-4000-8000-000000000001','because')$$,
  'P0001', NULL,
  'an ordinary member cannot revoke a verification'
);

RESET ROLE;

-- A client cannot mint evidence directly: no INSERT is granted, so the RPC's
-- validation cannot be bypassed.
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.verification_evidence', 'INSERT'),
  'evidence can only enter through request_verification()'
);
SELECT ok(
  NOT has_table_privilege(
    'authenticated', 'public.verification_review_events', 'INSERT'),
  'the decision ledger cannot be written by a client'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.verification_evidence', 'SELECT'),
  'evidence is not readable without a session'
);

-- ---------------------------------------------------------------------------
-- Reviewing
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"ee110000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.admin_claim_verification((SELECT request_id FROM ver_probe))$$,
  'a reviewer can claim an application'
);
SELECT is(
  (SELECT status FROM public.verification_requests
    WHERE user_id = 'ee110000-0000-4000-8000-000000000001'),
  'under_review',
  'claiming moves it out of the unassigned queue'
);

-- "We need more information" with no question is a dead end for the person
-- waiting, so the message is required.
SELECT throws_ok(
  $$SELECT public.admin_request_verification_info(
      (SELECT request_id FROM ver_probe), '  ')$$,
  'P0001', 'message_required',
  'asking for more information requires saying what is needed'
);

SELECT lives_ok(
  $$SELECT public.admin_request_verification_info(
      (SELECT request_id FROM ver_probe), 'Link to the group?')$$,
  'a reviewer can ask the applicant a question'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"ee110000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT info_request FROM public.my_verification_state()),
  'Link to the group?',
  'the applicant is told exactly what was asked'
);

-- Back to pending rather than under_review: the reviewer who asked may not be
-- the one who picks it up again.
SELECT lives_ok(
  $$SELECT public.respond_to_verification_request('https://example.org/group')$$,
  'the applicant can answer'
);
SELECT is(
  (SELECT status FROM public.my_verification_state()),
  'pending',
  'answering returns the application to the queue'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"ee110000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.admin_review_verification(
      (SELECT request_id FROM ver_probe), TRUE, 'Credential checked.')$$,
  'approving works from the post-answer pending state'
);

RESET ROLE;

-- manual_on is what stops the automatic reach sweep from touching a decision
-- a human made.
SELECT results_eq(
  $$SELECT is_verified, verification_override FROM public.users
     WHERE user_id = 'ee110000-0000-4000-8000-000000000001'$$,
  $$VALUES (TRUE, 'manual_on'::TEXT)$$,
  'approval verifies the account and pins it against the sweep'
);

-- ---------------------------------------------------------------------------
-- Revoking
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
  '{"sub":"ee110000-0000-4000-8000-000000000002","role":"authenticated"}';

-- Removing a badge is visible to the member and to everyone who follows them.
SELECT throws_ok(
  $$SELECT public.admin_revoke_verification(
      'ee110000-0000-4000-8000-000000000001', '')$$,
  'P0001', 'reason_required',
  'a revocation must be explained'
);

SELECT lives_ok(
  $$SELECT public.admin_revoke_verification(
      'ee110000-0000-4000-8000-000000000001', 'Licence lapsed.')$$,
  'a reviewer can revoke with a reason'
);

RESET ROLE;

-- manual_off, not NULL. Without it the sweep would re-verify an account that
-- still meets the reach thresholds, silently undoing a human decision.
SELECT results_eq(
  $$SELECT is_verified, verification_override FROM public.users
     WHERE user_id = 'ee110000-0000-4000-8000-000000000001'$$,
  $$VALUES (FALSE, 'manual_off'::TEXT)$$,
  'revocation un-verifies and pins it against re-verification'
);

-- ---------------------------------------------------------------------------
-- The ledger, and the thing it must not break
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.verification_review_events SET reason = 'tampered'
     WHERE subject_id = 'ee110000-0000-4000-8000-000000000001'$$,
  'P0001', NULL,
  'the decision ledger refuses to be rewritten'
);

-- The regression this design exists to avoid. 20261010090000 and
-- 20261011090000 were both written because an append-only table carrying a
-- foreign key made the referenced account undeletable: the cascade fires an
-- UPDATE or DELETE that the table's own guard rejects, so the DELETE fails.
-- verification_review_events therefore holds plain UUIDs with no FK.
SELECT lives_ok(
  $$DELETE FROM public.users
     WHERE user_id = 'ee110000-0000-4000-8000-000000000001'$$,
  'an account with verification history can still be deleted'
);

-- Evidence is the member's personal data and goes with the account. The
-- decision ledger is an audit trail and is retained, exactly as audit_log is.
SELECT is(
  (SELECT count(*)::INT FROM public.verification_evidence
    WHERE user_id = 'ee110000-0000-4000-8000-000000000001'),
  0,
  'deleting the account removes its evidence'
);
SELECT ok(
  (SELECT count(*) FROM public.verification_review_events
    WHERE subject_id = 'ee110000-0000-4000-8000-000000000001') > 0,
  'the decision ledger survives the account, so the audit trail holds'
);

SELECT * FROM finish();

ROLLBACK;
