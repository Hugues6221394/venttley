-- A private tribe that is private, and a keeper who hears about it.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(17);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
SELECT v.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       v.id || '@id.venttly.app', 'x', now(), '{}', '{}',
       now() - INTERVAL '2 years', now(), '','','','','','','',''
  FROM (VALUES
    ('ccc10000-0000-4000-8000-000000000001'::UUID),  -- keeper
    ('ccc10000-0000-4000-8000-000000000002'::UUID),  -- outsider who wants in
    ('ccc10000-0000-4000-8000-000000000003'::UUID)   -- an existing member
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('ccc10000-0000-4000-8000-000000000001','gatekeeper','x','x','Gatekeeper','gatekeeper','gatekeeper','normal','active',1990, now() - INTERVAL '2 years'),
  ('ccc10000-0000-4000-8000-000000000002','outsider','x','x','Outsider','outsider','outsider','normal','active',1990, now() - INTERVAL '2 years'),
  ('ccc10000-0000-4000-8000-000000000003','insider','x','x','Insider','insider','insider','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category, visibility)
VALUES ('ccc1dddd-0000-4000-8000-000000000001','Quiet Room','quiet-room',
        'ccc10000-0000-4000-8000-000000000001','campus','private'),
       ('ccc1dddd-0000-4000-8000-000000000002','Open Room','open-room',
        'ccc10000-0000-4000-8000-000000000001','campus','public');

INSERT INTO public.tribe_members (tribe_id, user_id, role) VALUES
  ('ccc1dddd-0000-4000-8000-000000000001','ccc10000-0000-4000-8000-000000000001','keeper'),
  ('ccc1dddd-0000-4000-8000-000000000001','ccc10000-0000-4000-8000-000000000003','member');

SET session_replication_role = origin;

-- The mirror. admin_create_tribe writes is_private and never visibility, so a
-- private tribe used to come out visibility='public' — openly readable and
-- openly joinable while the app drew a padlock on it.
--
-- The fixture above ran under session_replication_role = replica, which
-- disables triggers, so these have to move the columns themselves rather than
-- reading what the INSERT left behind.
UPDATE public.tribes SET visibility = 'private' WHERE slug = 'quiet-room';
SELECT is(
  (SELECT is_private FROM public.tribes WHERE slug = 'quiet-room'),
  TRUE,
  'setting visibility carries is_private with it'
);
UPDATE public.tribes SET is_private = FALSE WHERE slug = 'quiet-room';
SELECT is(
  (SELECT visibility FROM public.tribes WHERE slug = 'quiet-room'),
  'public',
  'and writing the old boolean still moves the column that decides'
);
UPDATE public.tribes SET visibility = 'private' WHERE slug = 'quiet-room';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"ccc10000-0000-4000-8000-000000000002","role":"authenticated"}';

-- The hole this migration exists to close. A row naming yourself satisfied
-- "tribe_members self", so one POST joined any tribe — and could say
-- role='keeper', which can_manage_tribe() accepts.
SELECT throws_ok(
  $$ INSERT INTO public.tribe_members (tribe_id, user_id, role)
     VALUES ('ccc1dddd-0000-4000-8000-000000000001',
             'ccc10000-0000-4000-8000-000000000002', 'member') $$,
  '42501',
  NULL,
  'a client cannot write its own membership row'
);
SELECT throws_ok(
  $$ INSERT INTO public.tribe_members (tribe_id, user_id, role)
     VALUES ('ccc1dddd-0000-4000-8000-000000000002',
             'ccc10000-0000-4000-8000-000000000002', 'keeper') $$,
  '42501',
  NULL,
  'and certainly cannot make itself a keeper'
);

-- Which leaves the RPC as the only way in, and it says no.
SELECT is(
  public.request_tribe_membership('ccc1dddd-0000-4000-8000-000000000001'),
  'pending',
  'asking to join a private tribe produces a request, not a membership'
);
SELECT is(
  (SELECT count(*)::INT FROM public.tribe_members
    WHERE tribe_id = 'ccc1dddd-0000-4000-8000-000000000001'
      AND user_id = 'ccc10000-0000-4000-8000-000000000002'),
  0,
  'and no membership until somebody decides'
);
SELECT is(
  public.request_tribe_membership('ccc1dddd-0000-4000-8000-000000000002'),
  'joined',
  'a public tribe still lets you straight in'
);

-- A roster is a list of people who have admitted something by being there.
SELECT is(
  (SELECT count(*)::INT FROM public.tribe_members
    WHERE tribe_id = 'ccc1dddd-0000-4000-8000-000000000001'),
  0,
  'an outsider cannot read a private tribe membership list'
);

RESET ROLE;
SELECT is(
  (SELECT n.user_id FROM public.notifications AS n
    WHERE n.kind = 'tribe_join_request'),
  'ccc10000-0000-4000-8000-000000000001'::UUID,
  'the keeper is told somebody is waiting, rather than having to look'
);
SELECT is(
  (SELECT payload->>'tribe_slug' FROM public.notifications
    WHERE kind = 'tribe_join_request'),
  'quiet-room',
  'and the notification carries the slug the tap target needs'
);

-- Deciding. The id is captured here, as postgres: the read policy on
-- tribe_join_requests shows you your own rows and the ones you manage, so an
-- ordinary member looking it up inline gets NULL and the function reports
-- join_request_not_found instead of refusing them.
CREATE TEMP TABLE subject AS
SELECT request_id FROM public.tribe_join_requests LIMIT 1;
GRANT SELECT ON subject TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT throws_ok(
  $$ SELECT public.respond_tribe_join_request(
       (SELECT request_id FROM subject), TRUE, NULL) $$,
  'not_tribe_manager',
  'an ordinary member cannot approve'
);

SET LOCAL request.jwt.claims = '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT ok(
  public.respond_tribe_join_request(
    (SELECT request_id FROM subject), TRUE, NULL),
  'the keeper can'
);

RESET ROLE;
-- A request that vanishes without a word is worse than a refusal.
SELECT is(
  (SELECT n.kind FROM public.notifications AS n
    WHERE n.user_id = 'ccc10000-0000-4000-8000-000000000002'
      AND n.kind LIKE 'tribe_join_%'),
  'tribe_join_approved',
  'and the person who asked is told what was decided'
);
SELECT is(
  (SELECT count(*)::INT FROM public.tribe_members
    WHERE tribe_id = 'ccc1dddd-0000-4000-8000-000000000001'
      AND user_id = 'ccc10000-0000-4000-8000-000000000002'),
  1,
  'approval is what admits them'
);

-- Leaving. DELETE was revoked from authenticated in 20260816020550 and never
-- re-granted, while the client kept deleting directly — so this has been
-- failing with 42501 in production.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"ccc10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT ok(
  public.leave_tribe('ccc1dddd-0000-4000-8000-000000000001'),
  'somebody can leave a tribe they joined'
);
SELECT is(
  (SELECT count(*)::INT FROM public.tribe_members
    WHERE tribe_id = 'ccc1dddd-0000-4000-8000-000000000001'
      AND user_id = 'ccc10000-0000-4000-8000-000000000002'),
  0,
  'and they are actually out'
);

-- A tribe with no keeper has nobody to approve a request or answer a report.
SET LOCAL request.jwt.claims = '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT throws_ok(
  $$ SELECT public.leave_tribe('ccc1dddd-0000-4000-8000-000000000001') $$,
  'keeper_must_transfer_first',
  'but a keeper has to hand the tribe over first'
);

SELECT * FROM finish();
ROLLBACK;
