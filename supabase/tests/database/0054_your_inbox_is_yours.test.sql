-- Deleting and archiving a chat, each of them one person's decision.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(10);

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
    ('eee10000-0000-4000-8000-000000000001'::UUID),  -- me
    ('eee10000-0000-4000-8000-000000000002'::UUID),  -- the other person
    ('eee10000-0000-4000-8000-000000000003'::UUID)   -- somebody unrelated
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('eee10000-0000-4000-8000-000000000001','inboxme','x','x','Me','me','inboxme','normal','active',1990, now() - INTERVAL '2 years'),
  ('eee10000-0000-4000-8000-000000000002','inboxyou','x','x','You','you','inboxyou','normal','active',1990, now() - INTERVAL '2 years'),
  ('eee10000-0000-4000-8000-000000000003','inboxnobody','x','x','Nobody','nobody','inboxnobody','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status, room_kind)
VALUES ('eee1aaaa-0000-4000-8000-000000000001',
        'eee10000-0000-4000-8000-000000000001',
        'eee10000-0000-4000-8000-000000000002', 'active', 'direct');

INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv, created_at)
VALUES
  ('eee1bbbb-0000-4000-8000-000000000001','eee1aaaa-0000-4000-8000-000000000001',
   'eee10000-0000-4000-8000-000000000002','an old secret','x', now() - INTERVAL '2 hours'),
  ('eee1bbbb-0000-4000-8000-000000000002','eee1aaaa-0000-4000-8000-000000000001',
   'eee10000-0000-4000-8000-000000000002','the latest line','x', now() - INTERVAL '1 hour');

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT last_message_preview FROM public.inbox_rooms
    WHERE room_id = 'eee1aaaa-0000-4000-8000-000000000001'),
  'the latest line',
  'the thread is in my inbox to start with'
);

-- Archiving.
SELECT lives_ok(
  $$ SELECT public.set_chat_room_archived('eee1aaaa-0000-4000-8000-000000000001', TRUE) $$,
  'I can archive a conversation'
);
SELECT ok(
  (SELECT archived_at IS NOT NULL FROM public.inbox_rooms
    WHERE room_id = 'eee1aaaa-0000-4000-8000-000000000001'),
  'and the inbox can see that it is archived'
);
-- Archiving is not deleting: the room and its messages are untouched, which is
-- what makes it reversible.
SELECT is(
  (SELECT last_message_preview FROM public.inbox_rooms
    WHERE room_id = 'eee1aaaa-0000-4000-8000-000000000001'),
  'the latest line',
  'an archived thread keeps its messages'
);
SELECT lives_ok(
  $$ SELECT public.set_chat_room_archived('eee1aaaa-0000-4000-8000-000000000001', FALSE) $$,
  'and I can put it back'
);

-- Deleting, which is the one that used to take the conversation away from
-- both people.
SELECT lives_ok(
  $$ SELECT public.clear_chat_room('eee1aaaa-0000-4000-8000-000000000001') $$,
  'I can delete a conversation'
);
SELECT is(
  (SELECT count(*)::INT FROM public.inbox_rooms
    WHERE room_id = 'eee1aaaa-0000-4000-8000-000000000001'),
  0,
  'and it leaves my inbox'
);
-- Hiding the room is not enough on its own: chat_messages is read directly by
-- the client, so without the policy the history would come back the moment a
-- new message pulled the room into the list again.
SELECT is(
  (SELECT count(*)::INT FROM public.chat_messages
    WHERE room_id = 'eee1aaaa-0000-4000-8000-000000000001'),
  0,
  'and the messages I cleared are gone from my side'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"eee10000-0000-4000-8000-000000000002","role":"authenticated"}';

-- The whole point. "Delete conversation" wrote room_status = 'declined' on the
-- shared row, so it ended the thread for the other person too, silently and
-- with no way back.
SELECT is(
  (SELECT last_message_preview FROM public.inbox_rooms
    WHERE room_id = 'eee1aaaa-0000-4000-8000-000000000001'),
  'the latest line',
  'while the other person still has the conversation'
);

SET LOCAL request.jwt.claims = '{"sub":"eee10000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT throws_ok(
  $$ SELECT public.clear_chat_room('eee1aaaa-0000-4000-8000-000000000001') $$,
  'not_a_participant',
  'and somebody who is not in the room cannot touch it'
);

SELECT * FROM finish();
ROLLBACK;
