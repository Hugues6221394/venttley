-- Tagging somebody, and who hears about it.
--
-- Asked for: "@ for tagging people on vents, 24 hr stories, comments, in
-- spaces, group chats, everywhere where a tag can be useful". Vents, stories
-- and space posts are all rows in `posts`, so one trigger already covered
-- three of those. Tribe chat and group chat had nothing.
--
-- And the part nobody asked for, which only becomes visible once mentions
-- reach private rooms: a mention notification carries the first sixty
-- characters of what was written, and it was sent to anybody whose handle
-- matched, member or not.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

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
    ('caf10000-0000-4000-8000-000000000001'::UUID),  -- talks
    ('caf10000-0000-4000-8000-000000000002'::UUID),  -- is in the room
    ('caf10000-0000-4000-8000-000000000003'::UUID)   -- is not
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES
  ('caf10000-0000-4000-8000-000000000001','tagspeaker','x','x','Speaker','speaker','tagspeaker','normal','active',1990),
  ('caf10000-0000-4000-8000-000000000002','taginsider','x','x','Insider','insider','taginsider','normal','active',1990),
  ('caf10000-0000-4000-8000-000000000003','tagoutsider','x','x','Outsider','outsider','tagoutsider','normal','active',1990);

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category, visibility)
VALUES ('caf1aaaa-0000-4000-8000-000000000001','Shut Tribe','tag-shut',
        'caf10000-0000-4000-8000-000000000001','campus','private');

INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('caf1aaaa-0000-4000-8000-000000000001','caf10000-0000-4000-8000-000000000001','keeper'),
       ('caf1aaaa-0000-4000-8000-000000000001','caf10000-0000-4000-8000-000000000002','member');

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status, room_kind, created_by, title)
VALUES ('caf1bbbb-0000-4000-8000-000000000001',
        'caf10000-0000-4000-8000-000000000001', NULL, 'active','group',
        'caf10000-0000-4000-8000-000000000001','A group');

INSERT INTO public.chat_room_members (room_id, user_id)
VALUES ('caf1bbbb-0000-4000-8000-000000000001','caf10000-0000-4000-8000-000000000001'),
       ('caf1bbbb-0000-4000-8000-000000000001','caf10000-0000-4000-8000-000000000002');

INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
 WHERE u.username_normalized IN ('tagspeaker','taginsider','tagoutsider')
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;

-- Tribe group chat, which had no mentions at all.
INSERT INTO public.tribe_messages (message_id, tribe_id, sender_id, content)
VALUES ('caf1cccc-0000-4000-8000-000000000001',
        'caf1aaaa-0000-4000-8000-000000000001',
        'caf10000-0000-4000-8000-000000000001',
        'what do you think @taginsider');

SELECT is(
  (SELECT count(*)::INT FROM private.content_mentions
    WHERE source_kind = 'tribe_message'
      AND source_id = 'caf1cccc-0000-4000-8000-000000000001'),
  1,
  'a tag in a tribe chat is recorded'
);

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000002' AND kind = 'mention'),
  1,
  'and the person is told'
);

SELECT is(
  (SELECT payload->>'tribe_slug' FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000002' AND kind = 'mention'),
  'tag-shut',
  'with enough to open the room it happened in'
);

-- Somebody who is not in the tribe.
INSERT INTO public.tribe_messages (message_id, tribe_id, sender_id, content)
VALUES ('caf1cccc-0000-4000-8000-000000000002',
        'caf1aaaa-0000-4000-8000-000000000001',
        'caf10000-0000-4000-8000-000000000001',
        'and you @tagoutsider');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000003'),
  0,
  'naming an outsider does not post them sixty characters of a private tribe'
);
SELECT is(
  (SELECT count(*)::INT FROM private.content_mentions
    WHERE source_kind = 'tribe_message'
      AND source_id = 'caf1cccc-0000-4000-8000-000000000002'),
  1,
  'though the tag is still recorded, so it renders for the people in the room'
);

-- Group chat in the inbox.
INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv)
VALUES ('caf1dddd-0000-4000-8000-000000000001',
        'caf1bbbb-0000-4000-8000-000000000001',
        'caf10000-0000-4000-8000-000000000001',
        'are you around @taginsider', 'v1-plaintext');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000002' AND kind = 'mention'),
  2,
  'a tag in a group chat is delivered too'
);

INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv)
VALUES ('caf1dddd-0000-4000-8000-000000000002',
        'caf1bbbb-0000-4000-8000-000000000001',
        'caf10000-0000-4000-8000-000000000001',
        'and @tagoutsider too', 'v1-plaintext');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000003'),
  0,
  'and somebody outside the group still hears nothing'
);

-- A post in the same private tribe: the hole that was already open.
--
-- Written as the keeper, because the tribe's own write guard asks who is
-- posting and this row is going into a private tribe.
SET LOCAL request.jwt.claims = '{"sub":"caf10000-0000-4000-8000-000000000001","role":"authenticated"}';

INSERT INTO public.posts (post_id, author_id, tribe_id, content, category_name, post_mood)
VALUES ('caf1eeee-0000-4000-8000-000000000001',
        'caf10000-0000-4000-8000-000000000001',
        'caf1aaaa-0000-4000-8000-000000000001',
        'thinking about this @tagoutsider','mental_health','hopeful');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000003'),
  0,
  'nor from a post inside a private tribe they are not in'
);

-- And the ordinary case still works: a vent outside any tribe reaches anyone.
INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('caf1eeee-0000-4000-8000-000000000002',
        'caf10000-0000-4000-8000-000000000001',
        'open question for @tagoutsider','mental_health','hopeful');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'caf10000-0000-4000-8000-000000000003' AND kind = 'mention'),
  1,
  'a tag in the open still reaches a stranger, which is the point of tagging'
);

SELECT * FROM finish();
ROLLBACK;
