BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(15);

-- Two accounts. One will consent, one will not, so "outstanding" can be shown
-- to be per-account rather than a global flag.
SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('c04c0000-0000-4000-8000-000000000001','consenter','consenter','x',
        'consenter','consenter','consenter','normal','active',1995),
       ('c04c0000-0000-4000-8000-000000000002','refuser','refuser','x',
        'refuser','refuser','refuser','normal','active',1995);

SET session_replication_role = origin;

-- The seeded v1 pair from 20261008090000. Asserted rather than assumed: every
-- other test here depends on there being exactly one live document per kind,
-- and a second in-force row would make current_policies() ambiguous.
SELECT is(
  (SELECT count(*)::INT FROM public.current_policies()),
  2,
  'exactly one in-force document per kind ships with the migration'
);

-- ---------------------------------------------------------------------------
-- Anonymous readers
-- ---------------------------------------------------------------------------
-- The documents have to be legible before an account exists, or "read this
-- before you sign up" is not something the product can actually offer.
SET LOCAL ROLE anon;
SET LOCAL "request.jwt.claims" = '{"role":"anon"}';

SELECT is(
  (SELECT count(*)::INT FROM public.current_policies()),
  2,
  'anon can read the Terms and Privacy Policy before signing up'
);

SELECT throws_ok(
  $$SELECT public.accept_policies('2026-09-07','2026-09-07')$$,
  '42501', NULL,
  'anon cannot record an acceptance'
);

SELECT throws_ok(
  $$SELECT count(*) FROM public.policy_acceptances$$,
  '42501', NULL,
  'anon cannot read anybody''s acceptance record'
);

RESET ROLE;

-- ---------------------------------------------------------------------------
-- The signed-in member
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = 'c04c0000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"c04c0000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT count(*)::INT FROM public.my_outstanding_policies()),
  2,
  'a fresh account owes both documents'
);

-- The whole point of passing the version back. If the server substituted the
-- current version instead of checking, a policy that changed while somebody
-- was reading the old one would be recorded as accepted unread.
SELECT throws_ok(
  $$SELECT public.accept_policies('1999-01-01','2026-09-07')$$,
  'P0001', 'policy_version_stale',
  'a version the caller was not shown is refused, not substituted'
);

SELECT is(
  (SELECT count(*)::INT FROM public.policy_acceptances
    WHERE user_id = 'c04c0000-0000-4000-8000-000000000001'),
  0,
  'the refused call recorded nothing'
);

-- Acceptance cannot be written directly. This is what makes the record worth
-- anything: there is no path to a consent row that does not go through the
-- RPC, so a modified client cannot mint one, and it cannot choose the
-- timestamp either.
SELECT throws_ok(
  $$INSERT INTO public.policy_acceptances (user_id, kind, version)
    VALUES ('c04c0000-0000-4000-8000-000000000001','terms','2026-09-07')$$,
  '42501', NULL,
  'a client cannot insert its own acceptance'
);

SELECT lives_ok(
  $$SELECT public.accept_policies('2026-09-07','2026-09-07')$$,
  'accepting the versions actually shown succeeds'
);

SELECT is(
  (SELECT count(*)::INT FROM public.my_outstanding_policies()),
  0,
  'nothing is outstanding once both are accepted'
);

RESET ROLE;

-- Idempotent, and specifically not DO UPDATE: a retried call must converge on
-- the row that exists rather than moving accepted_at forward, or a network
-- retry would silently rewrite when somebody agreed.
CREATE TEMP TABLE consent_before ON COMMIT DROP AS
  SELECT kind, accepted_at FROM public.policy_acceptances
   WHERE user_id = 'c04c0000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = 'c04c0000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"c04c0000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.accept_policies('2026-09-07','2026-09-07')$$,
  'a repeat acceptance is a no-op rather than an error'
);

RESET ROLE;

SELECT is(
  (SELECT count(*)::INT FROM public.policy_acceptances a
     JOIN consent_before b ON b.kind = a.kind AND b.accepted_at = a.accepted_at
    WHERE a.user_id = 'c04c0000-0000-4000-8000-000000000001'),
  2,
  'the retry left both original timestamps untouched'
);

-- ---------------------------------------------------------------------------
-- Re-consent
-- ---------------------------------------------------------------------------
-- A material new version is owed by everybody who has not accepted that exact
-- version. This is the mechanism the whole feature rests on for a policy
-- change, and it needs no client release to take effect.
INSERT INTO public.policy_documents (kind, version, title, body_markdown, material)
VALUES ('terms','2027-01-01','Venttly Terms & Conditions','# changed', TRUE);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = 'c04c0000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"c04c0000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT results_eq(
  $$SELECT kind, version FROM public.my_outstanding_policies()$$,
  $$VALUES ('terms'::TEXT, '2027-01-01'::TEXT)$$,
  'a material new version becomes outstanding again, and only that document'
);

RESET ROLE;

-- A non-material correction — a typo, a dead link — creates a version so the
-- record still says which text was shown, but it must not put the entire
-- userbase behind a consent wall.
INSERT INTO public.policy_documents (kind, version, title, body_markdown, material)
VALUES ('privacy','2027-01-02','Venttly Privacy Policy','# typo fixed', FALSE);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = 'c04c0000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"c04c0000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT results_eq(
  $$SELECT kind, version FROM public.my_outstanding_policies()$$,
  $$VALUES ('terms'::TEXT, '2027-01-01'::TEXT)$$,
  'a non-material correction does not force a fresh acceptance'
);

-- One account consenting must not consent for another. Cheap to assert and
-- exactly the kind of thing a badly-scoped auth.uid() would get wrong.
SET LOCAL "request.jwt.claim.sub" = 'c04c0000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"c04c0000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT is(
  (SELECT count(*)::INT FROM public.policy_acceptances),
  0,
  'a member cannot see another member''s acceptance record'
);

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
