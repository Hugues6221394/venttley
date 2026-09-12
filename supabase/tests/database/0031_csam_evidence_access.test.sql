BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(17);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ccc10000-0000-4000-8000-000000000001','csamsuper','csamsuper','x',
        'csamsuper','csamsuper','csamsuper','super_admin','active',1990),
       ('ccc10000-0000-4000-8000-000000000002','csammember','csammember','x',
        'csammember','csammember','csammember','normal','active',1995),
       -- A moderator works the ordinary queues and must not reach this one.
       ('ccc10000-0000-4000-8000-000000000003','csammod','csammod','x',
        'csammod','csammod','csammod','moderator','active',1990),
       -- Reviewing who looked at what is this role's whole job.
       ('ccc10000-0000-4000-8000-000000000004','csamaudit','csamaudit','x',
        'csamaudit','csamaudit','csamaudit','read_only_auditor','active',1990),
       ('ccc10000-0000-4000-8000-000000000005','csamauthor','csamauthor','x',
        'csamauthor','csamauthor','csamauthor','normal','active',1995);

INSERT INTO public.csam_incidents (incident_id, kind, content_ref, media_url,
                                   author_id, labels, status)
VALUES ('ccc20000-0000-4000-8000-000000000001','post',
        'ccc30000-0000-4000-8000-000000000001',
        'storage://quarantine/fixture.jpg',
        'ccc10000-0000-4000-8000-000000000005',
        '{"csam":0.97,"minor":0.91}'::jsonb, 'detected');

SET session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- The queue is super_admin only
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);

SELECT throws_ok(
  $$ SELECT * FROM public.admin_csam_queue() $$,
  'P0001',
  'forbidden',
  'a member cannot list child-safety incidents'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}', true);

SELECT throws_ok(
  $$ SELECT * FROM public.admin_csam_queue() $$,
  'P0001',
  'forbidden',
  'a moderator cannot list child-safety incidents either: this queue is super_admin only'
);

-- ---------------------------------------------------------------------------
-- The queue deliberately does NOT require step-up
--
-- Knowing that work is waiting discloses nothing. An operator without their
-- token can see the backlog and act on none of it, which is the intended
-- asymmetry: admin_resolve_csam_incident and admin_read_csam_evidence both
-- require AAL2.
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT is(
  (SELECT count(*)::int FROM public.admin_csam_queue()
    WHERE incident_id = 'ccc20000-0000-4000-8000-000000000001'),
  1,
  'a super admin without step-up can still see that an incident is waiting'
);

SELECT ok(
  position('content_ref' IN pg_get_function_result(
      'public.admin_csam_queue(text,int)'::regprocedure)) = 0
  AND position('author_id' IN pg_get_function_result(
      'public.admin_csam_queue(text,int)'::regprocedure)) = 0
  AND position('media_url' IN pg_get_function_result(
      'public.admin_csam_queue(text,int)'::regprocedure)) = 0
  AND position('labels' IN pg_get_function_result(
      'public.admin_csam_queue(text,int)'::regprocedure)) = 0,
  'the queue projection cannot return evidence even by accident: no content_ref, author_id, media_url or labels in its result type'
);

-- ---------------------------------------------------------------------------
-- Reading the evidence is the act that is gated and recorded
-- ---------------------------------------------------------------------------

SELECT throws_ok(
  $$ SELECT public.admin_read_csam_evidence(
       'ccc20000-0000-4000-8000-000000000001', 'preparing the report') $$,
  'P0001',
  'aal2_required: this action requires a completed MFA step-up, not just a signed-in session',
  'reading evidence without step-up is refused'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

SELECT throws_like(
  $$ SELECT public.admin_read_csam_evidence(
       'ccc20000-0000-4000-8000-000000000001', '   ') $$,
  '%requires a stated reason%',
  'a blank reason is refused: the access review reads this text'
);

-- Scoped to the fixture, not a global count. A bare count(*) here passes only
-- on an empty database and fails the moment anyone has used the feature —
-- which is exactly what happened the first time this ran.
SELECT is(
  (SELECT count(*)::int FROM public.csam_evidence_access
    WHERE incident_id = 'ccc20000-0000-4000-8000-000000000001'),
  0,
  'a refused read leaves no trace in the ledger, so the ledger never claims an access that did not happen'
);

SELECT is(
  public.admin_read_csam_evidence(
    'ccc20000-0000-4000-8000-000000000001',
    'Verifying the classifier call before escalation')::jsonb ->> 'content_ref',
  'ccc30000-0000-4000-8000-000000000001',
  'with step-up and a stated reason, the evidence is returned'
);

SELECT is(
  (SELECT count(*)::int FROM public.csam_evidence_access
    WHERE incident_id = 'ccc20000-0000-4000-8000-000000000001'),
  1,
  'the disclosure wrote exactly one access record'
);

SELECT results_eq(
  $$ SELECT actor_pseudonym, actor_role, reason
       FROM public.csam_evidence_access
      WHERE incident_id = 'ccc20000-0000-4000-8000-000000000001' $$,
  $$ VALUES ('csamsuper', 'super_admin',
             'Verifying the classifier call before escalation') $$,
  'the record names who, in what role, and why — denormalised, so it still reads correctly after the account is gone'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_log
           WHERE action = 'csam.evidence_read'
             AND target_id = 'ccc20000-0000-4000-8000-000000000001'),
  'and audit_log records it too: the general ledger and the child-safety ledger are both written, on purpose'
);

-- ---------------------------------------------------------------------------
-- The ledger cannot be edited, and cannot become a reason someone is undeletable
-- ---------------------------------------------------------------------------

SELECT throws_like(
  $$ UPDATE public.csam_evidence_access SET reason = 'rewritten' $$,
  '%append-only%',
  'an access record cannot be rewritten'
);

SELECT throws_like(
  $$ DELETE FROM public.csam_evidence_access $$,
  '%append-only%',
  'an access record cannot be deleted'
);

SELECT is(
  (SELECT count(*)::int FROM pg_constraint
    WHERE conrelid = 'public.csam_evidence_access'::regclass AND contype = 'f'),
  0,
  'the ledger carries no foreign keys: an append-only guard refuses the UPDATE that ON DELETE SET NULL performs, so an FK here would make looking at an incident permanently block account deletion'
);

-- ---------------------------------------------------------------------------
-- Evidence outlives the account, and the refusal explains itself
-- ---------------------------------------------------------------------------

SELECT throws_like(
  $$ DELETE FROM public.users
      WHERE user_id = 'ccc10000-0000-4000-8000-000000000005' $$,
  '%child-safety incident%',
  'deleting the author of an unresolved incident is refused, and says which incident and why rather than a bare legal_hold_active'
);

-- ---------------------------------------------------------------------------
-- The access ledger is reviewable by the role whose job that is
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2"}', true);

SELECT is(
  (SELECT count(*)::int FROM public.admin_csam_access_log(
     'ccc20000-0000-4000-8000-000000000001')),
  1,
  'a read-only auditor can review who opened child-safety evidence'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}', true);

SELECT throws_ok(
  $$ SELECT * FROM public.admin_csam_access_log() $$,
  'P0001',
  'forbidden',
  'a moderator cannot read the child-safety access ledger'
);

SELECT * FROM finish();
ROLLBACK;
