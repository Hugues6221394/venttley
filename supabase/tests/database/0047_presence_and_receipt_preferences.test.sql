-- Activity status and read receipts: settings that change what other people
-- can learn, without changing what you can count.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(6);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('fff10000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','rcsender@id.venttly.app','x', now(),
        '{}','{}', now(), now(),'','','','','','','',''),
       ('fff10000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','rcreader@id.venttly.app','x', now(),
        '{}','{}', now(), now(),'','','','','','','','');

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('fff10000-0000-4000-8000-000000000001','rcsender','rcsender','x',
        'rcsender','rcsender','rcsender','normal','active',1990),
       ('fff10000-0000-4000-8000-000000000002','rcreader','rcreader','x',
        'rcreader','rcreader','rcreader','normal','active',1990);

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status)
VALUES ('fff20000-0000-4000-8000-000000000001',
        'fff10000-0000-4000-8000-000000000001',
        'fff10000-0000-4000-8000-000000000002', 'active');

INSERT INTO public.chat_messages (message_id, room_id, sender_id,
                                  encrypted_payload, nonce_iv)
VALUES ('fff30000-0000-4000-8000-000000000001',
        'fff20000-0000-4000-8000-000000000001',
        'fff10000-0000-4000-8000-000000000001', 'did you see this', 'iv');

SET session_replication_role = origin;

-- Defaults are on, so nothing changes for anybody who never opens settings.
SELECT results_eq(
  $$ SELECT show_last_seen, show_read_receipts FROM public.users
      WHERE user_id = 'fff10000-0000-4000-8000-000000000002' $$,
  $$ VALUES (TRUE, TRUE) $$,
  'both preferences default to on'
);

-- The reader, with receipts on, reads the room.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"fff10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT lives_ok(
  $$ SELECT public.mark_chat_room_read('fff20000-0000-4000-8000-000000000001') $$,
  'reading a room is allowed'
);
RESET ROLE;

SELECT isnt(
  (SELECT read_at FROM public.chat_messages
    WHERE message_id = 'fff30000-0000-4000-8000-000000000001'),
  NULL,
  'with receipts on, the sender can see it was read'
);

-- Now a second message, and the reader turns receipts off first.
SET session_replication_role = replica;
INSERT INTO public.chat_messages (message_id, room_id, sender_id,
                                  encrypted_payload, nonce_iv)
VALUES ('fff30000-0000-4000-8000-000000000002',
        'fff20000-0000-4000-8000-000000000001',
        'fff10000-0000-4000-8000-000000000001', 'and this one', 'iv');
SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"fff10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT results_eq(
  $$ SELECT show_read_receipts FROM public.set_presence_preferences(NULL, FALSE) $$,
  ARRAY[FALSE],
  'the preference can be changed on its own, without sending the other one'
);
SELECT public.mark_chat_room_read('fff20000-0000-4000-8000-000000000001');
RESET ROLE;

SELECT is(
  (SELECT read_at FROM public.chat_messages
    WHERE message_id = 'fff30000-0000-4000-8000-000000000002'),
  NULL,
  'with receipts off, the sender is not told it was read'
);

-- ...but the reader's own unread count still works, which is the thing that
-- would quietly break if the receipt row stopped being written.
SELECT isnt(
  (SELECT read_at FROM public.chat_message_receipts
    WHERE message_id = 'fff30000-0000-4000-8000-000000000002'
      AND user_id = 'fff10000-0000-4000-8000-000000000002'),
  NULL,
  'the read is still recorded for the reader, so their unread badge clears'
);

SELECT * FROM finish();
ROLLBACK;
