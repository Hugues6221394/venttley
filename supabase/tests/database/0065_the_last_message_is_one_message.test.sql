-- Which message the inbox calls the last one.
--
-- Found by a test that had been passing and then was not: two clips sent in
-- one transaction, and the inbox reported the first. Both rows carried the
-- same CURRENT_TIMESTAMP — the transaction's start time — and the view asked
-- for ORDER BY created_at DESC LIMIT 1 with nothing to break the tie. Three
-- separate subqueries asked that question, so they could disagree with each
-- other: one message's text beside another message's timestamp.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(5);

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
    ('cef10000-0000-4000-8000-000000000001'::UUID),
    ('cef10000-0000-4000-8000-000000000002'::UUID)
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES
  ('cef10000-0000-4000-8000-000000000001','lastmsgone','x','x','One','one','lastmsgone','normal','active',1990),
  ('cef10000-0000-4000-8000-000000000002','lastmsgtwo','x','x','Two','two','lastmsgtwo','normal','active',1990);

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status, room_kind)
VALUES ('cef1aaaa-0000-4000-8000-000000000001',
        'cef10000-0000-4000-8000-000000000001',
        'cef10000-0000-4000-8000-000000000002','active','direct');

INSERT INTO public.chat_room_members (room_id, user_id)
VALUES ('cef1aaaa-0000-4000-8000-000000000001','cef10000-0000-4000-8000-000000000001'),
       ('cef1aaaa-0000-4000-8000-000000000001','cef10000-0000-4000-8000-000000000002');

-- Two messages in one transaction, taking the column default. This is the
-- shape that broke: under CURRENT_TIMESTAMP both rows would land on the same
-- instant.
INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv)
VALUES ('cef1bbbb-0000-4000-8000-000000000001',
        'cef1aaaa-0000-4000-8000-000000000001',
        'cef10000-0000-4000-8000-000000000001','first','x');

INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv)
VALUES ('cef1bbbb-0000-4000-8000-000000000002',
        'cef1aaaa-0000-4000-8000-000000000001',
        'cef10000-0000-4000-8000-000000000001','second','x');

SET session_replication_role = origin;

SELECT ok(
  (SELECT created_at FROM public.chat_messages
    WHERE message_id = 'cef1bbbb-0000-4000-8000-000000000002')
  > (SELECT created_at FROM public.chat_messages
      WHERE message_id = 'cef1bbbb-0000-4000-8000-000000000001'),
  'two messages in one transaction are not sent at the same instant'
);

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"cef10000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT is(
  (SELECT last_message_preview FROM public.inbox_rooms
    WHERE room_id = 'cef1aaaa-0000-4000-8000-000000000001'),
  'second',
  'the inbox shows the message that was actually sent last'
);

SELECT is(
  (SELECT last_message_at FROM public.inbox_rooms
    WHERE room_id = 'cef1aaaa-0000-4000-8000-000000000001'),
  (SELECT created_at FROM public.chat_messages
    WHERE message_id = 'cef1bbbb-0000-4000-8000-000000000002'),
  'and its timestamp, from the same row rather than a different one'
);

-- The view is what has to stay deterministic, not just this pair of rows.
SELECT ok(
  pg_get_viewdef('public.inbox_rooms'::regclass) LIKE '%message_id DESC%',
  'the ordering has a tie-break at all'
);

SELECT is(
  (SELECT column_default FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'chat_messages'
      AND column_name = 'created_at'),
  'clock_timestamp()',
  'and a message is stamped when it is written, not when its transaction began'
);

SELECT * FROM finish();
ROLLBACK;
