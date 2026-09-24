-- Whether a Space will accept a vent, asked before one is written.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(14);

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
    ('ddd10000-0000-4000-8000-000000000001'::UUID),  -- keeper
    ('ddd10000-0000-4000-8000-000000000002'::UUID),  -- member
    ('ddd10000-0000-4000-8000-000000000003'::UUID),  -- mod
    ('ddd10000-0000-4000-8000-000000000004'::UUID)   -- stranger
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('ddd10000-0000-4000-8000-000000000001','spacekeeper','x','x','Keeper','keeper','spacekeeper','normal','active',1990, now() - INTERVAL '2 years'),
  ('ddd10000-0000-4000-8000-000000000002','spacemember','x','x','Member','member','spacemember','normal','active',1990, now() - INTERVAL '2 years'),
  ('ddd10000-0000-4000-8000-000000000003','spacemod','x','x','Mod','mod','spacemod','normal','active',1990, now() - INTERVAL '2 years'),
  ('ddd10000-0000-4000-8000-000000000004','spacestranger','x','x','Stranger','stranger','spacestranger','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category, visibility)
VALUES ('ddd1eeee-0000-4000-8000-000000000001','Quiet Tribe','quiet-tribe',
        'ddd10000-0000-4000-8000-000000000001','campus','private');

INSERT INTO public.tribe_members (tribe_id, user_id, role) VALUES
  ('ddd1eeee-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000001','keeper'),
  ('ddd1eeee-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000002','member'),
  ('ddd1eeee-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000003','mod');

INSERT INTO public.spaces (space_id, tribe_id, slug, name, posting_permission,
                           archived_at, activates_at, deactivates_at)
VALUES
  ('ddd1ffff-0000-4000-8000-000000000001','ddd1eeee-0000-4000-8000-000000000001','open','Open','members',NULL,NULL,NULL),
  ('ddd1ffff-0000-4000-8000-000000000002','ddd1eeee-0000-4000-8000-000000000001','quiet','Quiet','read_only',NULL,NULL,NULL),
  ('ddd1ffff-0000-4000-8000-000000000003','ddd1eeee-0000-4000-8000-000000000001','mods','Mods','mods',NULL,NULL,NULL),
  ('ddd1ffff-0000-4000-8000-000000000004','ddd1eeee-0000-4000-8000-000000000001','notice','Notices','keeper',NULL,NULL,NULL),
  ('ddd1ffff-0000-4000-8000-000000000005','ddd1eeee-0000-4000-8000-000000000001','later','Later','members',NULL, now() + INTERVAL '2 days', NULL),
  ('ddd1ffff-0000-4000-8000-000000000006','ddd1eeee-0000-4000-8000-000000000001','over','Over','members',NULL,NULL, now() - INTERVAL '1 day'),
  ('ddd1ffff-0000-4000-8000-000000000007','ddd1eeee-0000-4000-8000-000000000001','gone','Gone','members', now(), NULL, NULL);

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000001'),
  'open', 'an ordinary Space is open to an ordinary member');

-- These four were all invisible until the insert failed. The screen showed
-- "Start a Vent" and the person found out after typing.
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000002'),
  'read_only', 'a read-only Space says so');
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000003'),
  'mods_only', 'a mods-only Space says so');
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000004'),
  'keeper_only', 'a keeper-only Space says so');
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000005'),
  'not_open_yet', 'a Space scheduled to open later says so');
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000006'),
  'closed', 'and one whose window has passed says so');

-- Archived beats everything else, because it is the one that will not change
-- on its own.
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000007'),
  'archived', 'an archived Space says archived');

-- The same rooms, from further up the hierarchy.
SET LOCAL request.jwt.claims = '{"sub":"ddd10000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000003'),
  'open', 'a mod can post in the mods-only Space');
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000004'),
  'keeper_only', 'but not in the keeper-only one');

SET LOCAL request.jwt.claims = '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000004'),
  'open', 'the keeper can');

-- Said separately from the closed states, because the answer is a different
-- screen: join the tribe, not come back on Monday.
SET LOCAL request.jwt.claims = '{"sub":"ddd10000-0000-4000-8000-000000000004","role":"authenticated"}';
SELECT is(public.my_space_posting_state('ddd1ffff-0000-4000-8000-000000000001'),
  'not_a_member', 'somebody outside the tribe is told that, not "read only"');

-- The names of the rooms inside a private tribe describe its members whether
-- or not anybody can read a vent in them.
SELECT is(
  (SELECT count(*)::INT FROM public.spaces
    WHERE tribe_id = 'ddd1eeee-0000-4000-8000-000000000001'),
  0,
  'and cannot list the Spaces of a private tribe at all'
);

-- The reason none of this had ever been noticed. 0050 created the table,
-- enabled RLS and wrote a FOR SELECT policy, but never granted SELECT. The
-- grant is checked before any policy, so every Spaces list in the app failed
-- with "permission denied for table spaces" from the day the feature shipped.
SET LOCAL request.jwt.claims = '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT ok(
  (SELECT count(*) FROM public.spaces
    WHERE tribe_id = 'ddd1eeee-0000-4000-8000-000000000001') = 7,
  'a member can read the Spaces of their own tribe at all'
);
-- And the view is security_invoker, so it checks the same privilege and would
-- have failed the same way.
SELECT ok(
  (SELECT count(*) FROM public.space_directory
    WHERE tribe_id = 'ddd1eeee-0000-4000-8000-000000000001') = 7,
  'including through the view the app actually reads'
);

SELECT * FROM finish();
ROLLBACK;
