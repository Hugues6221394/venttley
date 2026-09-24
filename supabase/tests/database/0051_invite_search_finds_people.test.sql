-- Finding people to invite by typing part of a name.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(13);

-- handle_new_user fires on auth.users and would allocate its own pseudonyms,
-- which collide with the ones fixed here.
SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
SELECT v.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       v.id || '@id.venttly.app', 'x', now(), '{}', '{}', now(), now(),
       '','','','','','','',''
  FROM (VALUES
    ('bbb10000-0000-4000-8000-000000000001'::UUID),  -- the keeper
    ('bbb10000-0000-4000-8000-000000000002'::UUID),  -- riverwalker, a friend
    ('bbb10000-0000-4000-8000-000000000003'::UUID),  -- riverstone, already a member
    ('bbb10000-0000-4000-8000-000000000004'::UUID),  -- riverlight, already invited
    ('bbb10000-0000-4000-8000-000000000005'::UUID),  -- riverblock, blocked the keeper
    ('bbb10000-0000-4000-8000-000000000006'::UUID),  -- rivergone, deactivated
    ('bbb10000-0000-4000-8000-000000000007'::UUID),  -- a stranger, display name only
    ('bbb10000-0000-4000-8000-000000000008'::UUID)   -- somebody else entirely
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, is_verified,
                          deactivated_at)
VALUES
  ('bbb10000-0000-4000-8000-000000000001','keeperone','x','x','Keeper One','keeper one','keeperone','normal','active',1990,FALSE,NULL),
  ('bbb10000-0000-4000-8000-000000000002','riverwalker','x','x','River Walker','river walker','riverwalker','normal','active',1990,TRUE,NULL),
  ('bbb10000-0000-4000-8000-000000000003','riverstone','x','x','River Stone','river stone','riverstone','normal','active',1990,FALSE,NULL),
  ('bbb10000-0000-4000-8000-000000000004','riverlight','x','x','River Light','river light','riverlight','normal','active',1990,FALSE,NULL),
  ('bbb10000-0000-4000-8000-000000000005','riverblock','x','x','River Block','river block','riverblock','normal','active',1990,FALSE,NULL),
  ('bbb10000-0000-4000-8000-000000000006','rivergone','x','x','River Gone','river gone','rivergone','normal','active',1990,FALSE,now()),
  ('bbb10000-0000-4000-8000-000000000007','quietpine','x','x','Riverside Quiet','riverside quiet','quietpine','normal','active',1990,FALSE,NULL),
  ('bbb10000-0000-4000-8000-000000000008','oakhollow','x','x','Oak Hollow','oak hollow','oakhollow','normal','active',1990,FALSE,NULL);

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category)
VALUES ('bbb1cccc-0000-4000-8000-000000000001','River Tribe','river-tribe',
        'bbb10000-0000-4000-8000-000000000001','campus'),
       -- A second tribe the keeper does not run, for the authorization check.
       ('bbb1cccc-0000-4000-8000-000000000002','Not Yours','not-yours',
        'bbb10000-0000-4000-8000-000000000008','campus');

INSERT INTO public.tribe_members (tribe_id, user_id, role) VALUES
  ('bbb1cccc-0000-4000-8000-000000000001','bbb10000-0000-4000-8000-000000000001','keeper'),
  ('bbb1cccc-0000-4000-8000-000000000001','bbb10000-0000-4000-8000-000000000003','member');

INSERT INTO public.tribe_invites (tribe_id, invited_user_id, invited_by, status)
VALUES ('bbb1cccc-0000-4000-8000-000000000001','bbb10000-0000-4000-8000-000000000004',
        'bbb10000-0000-4000-8000-000000000001','pending');

INSERT INTO public.friendships (user_a, user_b, status, requested_by, accepted_at)
VALUES ('bbb10000-0000-4000-8000-000000000001','bbb10000-0000-4000-8000-000000000002',
        'accepted','bbb10000-0000-4000-8000-000000000001', now());

-- Blocked in the direction that matters least: they blocked the keeper, not the
-- other way round. An invite is a notification, so it must still not be offered.
INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES ('bbb10000-0000-4000-8000-000000000005','bbb10000-0000-4000-8000-000000000001');

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"bbb10000-0000-4000-8000-000000000001","role":"authenticated"}';

CREATE TEMP VIEW hits AS
SELECT * FROM public.search_tribe_invite_candidates(
  'bbb1cccc-0000-4000-8000-000000000001', 'river', 30);

-- The whole point: a partial handle returns everyone who matches, not one
-- exact hit or nothing.
SELECT ok(
  (SELECT count(*) FROM hits) >= 4,
  'a prefix returns every matching person, not a single exact hit'
);

SELECT ok(
  EXISTS (SELECT 1 FROM hits WHERE pseudonym = 'riverwalker'),
  'a friend whose handle starts with the prefix is found'
);

-- Typed against the display name, which the old exact-handle lookup could
-- never have found: this person is @quietpine.
SELECT ok(
  EXISTS (SELECT 1 FROM hits WHERE pseudonym = 'quietpine'),
  'somebody is found by their display name, not just their handle'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM hits WHERE pseudonym = 'oakhollow'),
  'and somebody who matches neither is not'
);

-- Who must never appear.
SELECT ok(
  NOT EXISTS (SELECT 1 FROM hits WHERE pseudonym = 'rivergone'),
  'a deactivated account is not offered'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM hits WHERE pseudonym = 'riverblock'),
  'nor is somebody who blocked the keeper'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM hits WHERE pseudonym = 'keeperone'),
  'nor the keeper themselves'
);

-- The two answers that are about the tribe rather than the person. Without
-- these the keeper invites a member, the unique constraint swallows it, and
-- they are told an invitation was sent that nobody will receive.
SELECT ok(
  (SELECT already_member FROM hits WHERE pseudonym = 'riverstone'),
  'an existing member is returned, and marked as one'
);
SELECT ok(
  (SELECT already_invited FROM hits WHERE pseudonym = 'riverlight'),
  'somebody already asked is marked as already asked'
);
SELECT ok(
  NOT (SELECT already_member OR already_invited FROM hits WHERE pseudonym = 'riverwalker'),
  'and somebody who is neither is marked as neither'
);

SELECT ok(
  (SELECT is_friend AND is_verified FROM hits WHERE pseudonym = 'riverwalker'),
  'friendship and the verified badge come back with the row'
);

-- Friends first: the keeper inviting somebody usually has somebody in mind.
SELECT is(
  (SELECT pseudonym FROM hits LIMIT 1),
  'riverwalker',
  'a friend is ranked above everybody else'
);

-- Inviting is keeper-only, so the picker is too. It raises rather than
-- returning nothing, so the client can tell "not allowed" from "no matches".
SELECT throws_ok(
  $$ SELECT * FROM public.search_tribe_invite_candidates(
       'bbb1cccc-0000-4000-8000-000000000002', 'river', 30) $$,
  'not_the_keeper',
  'somebody who cannot invite cannot browse the list either'
);

SELECT * FROM finish();
ROLLBACK;
