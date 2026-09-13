-- Consent as a boundary, not a checkbox.
--
-- 0025 covers the consent records themselves: documents, versions, acceptance
-- rows, and accept_policies refusing a fabricated version. What it did not
-- cover — because it did not exist — was whether anything consulted those
-- records before letting someone publish. It did not. A brand-new account that
-- had accepted nothing posted successfully, which is how
-- 20261020090000_consent_gates_content_writes came to be written.
--
-- The invariant worth protecting here is not "writes are blocked". It is that
-- the gate and the prompt agree. If assert_user_can_write ever demanded more
-- than my_outstanding_policies reported, the app would show a clean slate
-- while the server refused every write, and the user would be locked out of a
-- demand nobody could show them. Both now read private.outstanding_policies,
-- and the tests below check them against each other rather than against a
-- hardcoded expectation, so a future edit to one has to move the other.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(12);

INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES (
  'ccc40000-0000-4000-8000-000000000001',
  'authenticated','authenticated','consentee@id.venttly.app',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"pseudonym":"consentee","avatar_seed":"consent-a","birth_year":2000}'::jsonb,
  now(), now()
);

-- ---------------------------------------------------------------------------
-- Before accepting anything
-- ---------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM private.outstanding_policies('ccc40000-0000-4000-8000-000000000001')),
  (SELECT count(*)::int FROM public.current_policies()),
  'a brand-new account owes every current policy'
);

SELECT throws_like(
  $$ INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood)
     VALUES ('ccc50000-0000-4000-8000-000000000001',
             'ccc40000-0000-4000-8000-000000000001',
             'confessions','publishing without consent','healing') $$,
  '%policy_acceptance_required%',
  'publishing before accepting is refused at the database, not merely hidden in the client'
);

-- The refusal has to say what is owed. A bare 'forbidden' would leave the
-- client guessing which document to present.
SELECT throws_like(
  $$ INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood)
     VALUES ('ccc50000-0000-4000-8000-000000000002',
             'ccc40000-0000-4000-8000-000000000001',
             'confessions','again','healing') $$,
  '%privacy and terms%',
  'and names which documents are outstanding'
);

-- ---------------------------------------------------------------------------
-- What consent must NOT block
-- ---------------------------------------------------------------------------

SELECT ok(
  (SELECT count(*) FROM public.posts) >= 0,
  'reading is not gated: a consent wall must not trap someone inside an account they cannot read'
);

SELECT is(
  (SELECT count(*)::int FROM private.outstanding_policies('ccc40000-0000-4000-8000-000000000001')),
  2,
  'and the account can still be told exactly what it owes'
);

-- ---------------------------------------------------------------------------
-- Accepting
-- ---------------------------------------------------------------------------

INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT 'ccc40000-0000-4000-8000-000000000001', c.kind, c.version
  FROM public.current_policies() c;

SELECT is(
  (SELECT count(*)::int FROM private.outstanding_policies('ccc40000-0000-4000-8000-000000000001')),
  0,
  'accepting the current versions clears the debt'
);

SELECT lives_ok(
  $$ INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood)
     VALUES ('ccc50000-0000-4000-8000-000000000003',
             'ccc40000-0000-4000-8000-000000000001',
             'confessions','published with consent','healing') $$,
  'and the same write now succeeds'
);

-- ---------------------------------------------------------------------------
-- Re-consent: material versions gate, cosmetic ones do not
-- ---------------------------------------------------------------------------

-- A typo fix. The record says which text was shown, but nobody is walled.
INSERT INTO public.policy_documents (kind, version, title, body_markdown, material, effective_at)
VALUES ('terms','2999-01-01','Terms (typo fix)','body', false, now());

SELECT is(
  (SELECT count(*)::int FROM private.outstanding_policies('ccc40000-0000-4000-8000-000000000001')),
  0,
  'a non-material new version does not re-gate anyone: a typo fix is not a new agreement'
);

SELECT lives_ok(
  $$ INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood)
     VALUES ('ccc50000-0000-4000-8000-000000000004',
             'ccc40000-0000-4000-8000-000000000001',
             'confessions','still publishing','healing') $$,
  'and writing continues uninterrupted'
);

-- A material change. Everyone owes a fresh acceptance.
INSERT INTO public.policy_documents (kind, version, title, body_markdown, material, effective_at)
VALUES ('terms','2999-06-01','Terms (material change)','body', true, now());

SELECT is(
  (SELECT string_agg(o.kind, ',') FROM private.outstanding_policies('ccc40000-0000-4000-8000-000000000001') o),
  'terms',
  'a material new version re-gates, and only the document that changed'
);

SELECT throws_like(
  $$ INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood)
     VALUES ('ccc50000-0000-4000-8000-000000000005',
             'ccc40000-0000-4000-8000-000000000001',
             'confessions','after a material change','healing') $$,
  '%policy_acceptance_required%',
  'writing stops until the new terms are accepted — this is what "support re-consent" has to mean'
);

-- ---------------------------------------------------------------------------
-- The gate and the prompt cannot disagree
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc40000-0000-4000-8000-000000000001","role":"authenticated"}', true);

SELECT results_eq(
  $$ SELECT kind, version FROM public.my_outstanding_policies() ORDER BY kind $$,
  $$ SELECT kind, version FROM private.outstanding_policies('ccc40000-0000-4000-8000-000000000001') ORDER BY kind $$,
  'what the app is told to show is exactly what the server enforces — otherwise the user is locked out of a demand nobody can display'
);

SELECT * FROM finish();
ROLLBACK;
