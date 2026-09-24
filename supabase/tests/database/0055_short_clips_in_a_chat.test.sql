-- A short clip, sent to a friend.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(8);

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
    ('fff10000-0000-4000-8000-000000000001'::UUID),
    ('fff10000-0000-4000-8000-000000000002'::UUID)
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('fff10000-0000-4000-8000-000000000001','clipsender','x','x','Sender','sender','clipsender','normal','active',1990, now() - INTERVAL '2 years'),
  ('fff10000-0000-4000-8000-000000000002','clipgetter','x','x','Getter','getter','clipgetter','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status, room_kind)
VALUES ('fff1aaaa-0000-4000-8000-000000000001',
        'fff10000-0000-4000-8000-000000000001',
        'fff10000-0000-4000-8000-000000000002', 'active', 'direct');

-- A user who has never accepted the policies cannot write anything, which is
-- correct and is not what this test is about. Recorded the way signup records
-- it rather than left in a state no real account occupies.
INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;

-- The bucket. 8 MB was ten or fifteen seconds of passable 720p, which would
-- have failed most clips at the storage boundary with an error nobody could
-- act on.
SELECT ok(
  (SELECT 'video/mp4' = ANY(allowed_mime_types) FROM storage.buckets WHERE id = 'chat-media'),
  'chat-media accepts mp4'
);
SELECT ok(
  -- An iPhone hands you a .mov, and nothing here transcodes: the bundled
  -- ffmpeg build is the audio-only one and ships no video codecs.
  (SELECT 'video/quicktime' = ANY(allowed_mime_types) FROM storage.buckets WHERE id = 'chat-media'),
  'and quicktime, because that is what an iPhone produces'
);
SELECT ok(
  (SELECT file_size_limit FROM storage.buckets WHERE id = 'chat-media') >= 24 * 1024 * 1024,
  'with room for about a minute of it'
);

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"fff10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT lives_ok(
  $$ SELECT public.send_chat_message(
       'fff1aaaa-0000-4000-8000-000000000001', 'look at this', NULL,
       'fff1aaaa-0000-4000-8000-000000000001/clip.mp4', 'video') $$,
  'a video message sends'
);

-- Both of the places that enumerate the media types fail closed, so missing
-- one produces a different error rather than a silent gap. This is the one
-- that would have been missed.
SELECT is(
  (SELECT attached_media_type FROM public.chat_messages
    WHERE room_id = 'fff1aaaa-0000-4000-8000-000000000001'),
  'video',
  'and the CHECK on the row lets it land'
);

SELECT is(
  (SELECT last_message_preview FROM public.inbox_rooms
    WHERE room_id = 'fff1aaaa-0000-4000-8000-000000000001'),
  'look at this',
  'the inbox shows what was said alongside it'
);

SET LOCAL request.jwt.claims = '{"sub":"fff10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT lives_ok(
  $$ SELECT public.send_chat_message(
       'fff1aaaa-0000-4000-8000-000000000001', NULL, NULL,
       'fff1aaaa-0000-4000-8000-000000000001/reply.mp4', 'video') $$,
  'a clip with nothing written alongside it sends too'
);
-- The arm that did not exist: an unlabelled video used to leave the inbox row
-- blank, because the CASE only knew about audio and image.
SELECT is(
  (SELECT last_message_preview FROM public.inbox_rooms
    WHERE room_id = 'fff1aaaa-0000-4000-8000-000000000001'),
  'Video',
  'and on its own it is described rather than left blank'
);

SELECT * FROM finish();
ROLLBACK;
