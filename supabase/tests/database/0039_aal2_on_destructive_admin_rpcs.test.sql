-- A staff password, on its own, must not be able to suspend anybody.
--
-- Every admin RPC was gated on is_staff(auth.uid()) and nothing else, so a
-- password was sufficient. The console requires MFA, but the console is not
-- the boundary: that check lives in proxy.ts and a direct PostgREST call never
-- goes near it. Anyone holding a staff password could suspend accounts, decide
-- cases and search every member from curl, with no second factor in the path.
--
-- These assertions are written as the attack: sign in as a real moderator with
-- a real staff role, at aal1, and try. Testing the reverse — that an aal2
-- moderator succeeds — is the easy half and proves nothing about the control.
-- Both are here, because a check that refuses everyone is not a working gate
-- either, it is an outage.
--
-- The claim shape matters. private.current_aal() reads 'aal' out of
-- request.jwt.claims and treats an unreadable or absent value as NULL, which
-- fails the check. So the no-claim case is covered too: that is what a cron
-- job or a service_role caller looks like, and it is why every one of these
-- eight was checked for non-human callers before the requirement was added.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(14);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('aa110000-0000-4000-8000-000000000001','aalmod','aalmod','x',
        'aalmod','aalmod','aalmod','super_admin','active',1990),
       ('aa110000-0000-4000-8000-000000000002','aaltarget','aaltarget','x',
        'aaltarget','aaltarget','aaltarget','normal','active',1995);

-- The profiles above are written with session_replication_role = replica, which
-- skips the foreign key from public.users to auth.users. A row inserted that way
-- stays in violation of it, and the next ordinary UPDATE of that row -- a karma
-- increment, a status change, a counter -- fails the constraint even though the
-- UPDATE never touches user_id. So each fixture gets the auth row it is supposed
-- to have.
--
-- Written here, still inside the replica fence, rather than before it: an insert
-- into auth.users fires handle_new_user, which would build a second profile and
-- collide with the one above on users_pseudonym_lower_unique. Replica mode
-- suppresses that trigger along with the foreign key.
INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  ('aa110000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 't0039u1@id.venttly.app',
   '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
   now(), now()),
  ('aa110000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 't0039u2@id.venttly.app',
   '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
   now(), now())
ON CONFLICT (id) DO NOTHING;

SET session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- aal1: a real super_admin, correctly signed in, with no step-up.
-- ---------------------------------------------------------------------------

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"aa110000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT throws_like(
  $q$SELECT public.admin_set_user_status('aa110000-0000-4000-8000-000000000002','suspended','no mfa')$q$,
  '%aal2_required%', 'a password alone cannot suspend an account');

SELECT throws_like(
  $q$SELECT public.admin_suspend_user_ladder('aa110000-0000-4000-8000-000000000002','no mfa')$q$,
  '%aal2_required%', 'nor through the ladder, which reaches the same place');

SELECT throws_like(
  $q$SELECT public.admin_lift_suspension('aa110000-0000-4000-8000-000000000002','no mfa')$q$,
  '%aal2_required%', 'nor reinstate one');

SELECT throws_like(
  $q$SELECT public.admin_set_shadow_ban('aa110000-0000-4000-8000-000000000002', true, 'no mfa')$q$,
  '%aal2_required%', 'nor apply a restriction the member cannot detect');

SELECT throws_like(
  $q$SELECT * FROM public.admin_global_search('aaltarget', 5)$q$,
  '%aal2_required%', 'nor read across every member on the platform');

-- ---------------------------------------------------------------------------
-- No claim at all. This is the shape of a cron job or a service_role caller,
-- and the reason each of these was checked for non-human callers first.
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims', '', true);
SELECT throws_ok(
  $q$SELECT public.admin_set_user_status('aa110000-0000-4000-8000-000000000002','suspended','no jwt')$q$,
  NULL, NULL, 'a caller with no JWT is refused rather than admitted');

-- An unparseable claim must fail closed too — current_aal swallows the error
-- and returns NULL, which is the safe direction only if NULL is refused.
SELECT set_config('request.jwt.claims', 'not json at all', true);
SELECT throws_ok(
  $q$SELECT public.admin_set_user_status('aa110000-0000-4000-8000-000000000002','suspended','bad jwt')$q$,
  NULL, NULL, 'so is one whose claims do not parse');

-- And a forged aal is still just a string in a claim the caller does not sign;
-- asserted here only to pin that nothing accepts a value other than aal2.
SELECT set_config('request.jwt.claims',
  '{"sub":"aa110000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal3"}', true);
SELECT throws_like(
  $q$SELECT public.admin_set_user_status('aa110000-0000-4000-8000-000000000002','suspended','odd aal')$q$,
  '%aal2_required%', 'and only the literal aal2 passes, not merely "not aal1"');

RESET role;

-- ---------------------------------------------------------------------------
-- aal2: the same moderator, stepped up. The control has to let real work
-- through, or it is an outage rather than a gate.
-- ---------------------------------------------------------------------------

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"aa110000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

SELECT lives_ok(
  $q$SELECT public.admin_set_user_status('aa110000-0000-4000-8000-000000000002','suspended','with mfa')$q$,
  'a stepped-up moderator can still suspend');

SELECT is(
  (SELECT account_status FROM public.users WHERE user_id = 'aa110000-0000-4000-8000-000000000002'),
  'suspended', 'and it actually took effect');

SELECT lives_ok(
  $q$SELECT public.admin_lift_suspension('aa110000-0000-4000-8000-000000000002','with mfa')$q$,
  'and can reverse it');

SELECT lives_ok(
  $q$SELECT * FROM public.admin_global_search('aaltarget', 5)$q$,
  'and can search');

RESET role;

-- ---------------------------------------------------------------------------
-- The gate order: staff first, step-up second. A non-staff caller must not
-- learn that MFA is what stands between them and the function.
-- ---------------------------------------------------------------------------

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"aa110000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
SELECT throws_like(
  $q$SELECT public.admin_set_user_status('aa110000-0000-4000-8000-000000000001','suspended','not staff')$q$,
  '%forbidden%', 'a non-staff caller is refused as non-staff, not as un-stepped-up');
RESET role;

-- The five that already had it keep it. This file is about not regressing the
-- set, not only about the eight added.
SELECT is(
  (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prosrc ~ 'require_aal2'),
  50,
  'fifty admin functions require a step-up: the original destructive set, '
  'impact reporting, operational governance, staff inbox rollout/recovery/operations, checked workflows, scoped support bindings, '
  'media review, access reviews, the staff invitation ledger and staff outreach '
  '(admin_message_member, admin_warn_member, admin_email_member)'
);

SELECT * FROM finish();
ROLLBACK;
