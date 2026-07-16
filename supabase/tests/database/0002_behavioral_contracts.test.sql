BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(20);

INSERT INTO auth.users (
  id,
  aud,
  role,
  email,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) VALUES
  (
    '10000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'phase2-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"phase2_a","avatar_seed":"phase2-a","safety_tier":"standard"}'::JSONB,
    NOW() - INTERVAL '2 hours',
    NOW() - INTERVAL '2 hours'
  ),
  (
    '10000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'phase2-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"phase2_b","avatar_seed":"phase2-b","safety_tier":"standard"}'::JSONB,
    NOW() - INTERVAL '2 hours',
    NOW() - INTERVAL '2 hours'
  ),
  (
    '10000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'phase2-c@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"phase2_c","avatar_seed":"phase2-c","safety_tier":"standard"}'::JSONB,
    NOW() - INTERVAL '2 hours',
    NOW() - INTERVAL '2 hours'
  ),
  (
    '10000000-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'phase2-d@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"phase2_d","avatar_seed":"phase2-d","safety_tier":"standard"}'::JSONB,
    NOW() - INTERVAL '2 hours',
    NOW() - INTERVAL '2 hours'
  );

UPDATE public.users
   SET created_at = NOW() - INTERVAL '2 hours'
 WHERE user_id::TEXT LIKE '10000000-0000-4000-8000-%';

INSERT INTO public.chat_rooms (
  room_id,
  initiated_by,
  received_by,
  request_preview,
  room_status
) VALUES
  (
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    'active fixture',
    'active'
  ),
  (
    '20000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    'pending fixture',
    'pending_request'
  ),
  (
    '20000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000004',
    'outsider fixture',
    'active'
  );

INSERT INTO public.chat_messages (
  message_id,
  room_id,
  sender_id,
  encrypted_payload,
  nonce_iv
) VALUES
  (
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'participant fixture',
    'v1-plaintext'
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000003',
    'outsider fixture',
    'v1-plaintext'
  );

CREATE TEMP TABLE phase2_results (
  result_key TEXT PRIMARY KEY,
  resource_id UUID NOT NULL
) ON COMMIT DROP;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT count(*) FROM public.chat_rooms),
  2::BIGINT,
  'a participant sees only their DM rooms'
);
SELECT is(
  (SELECT count(*) FROM public.chat_messages),
  1::BIGINT,
  'a participant sees only messages from their rooms'
);
SELECT throws_ok(
  $$
    INSERT INTO public.posts (
      author_id,
      category_name,
      content,
      post_mood
    ) VALUES (
      '10000000-0000-4000-8000-000000000002',
      'confessions',
      'spoofed author fixture',
      'healing'
    )
  $$,
  '42501',
  NULL,
  'authenticated users cannot spoof a post author'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000003';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000003","role":"authenticated"}';

SELECT is(
  (SELECT count(*) FROM public.chat_rooms),
  1::BIGINT,
  'an outsider cannot enumerate another pair DM rooms'
);
SELECT is(
  (SELECT count(*) FROM public.chat_messages),
  1::BIGINT,
  'an outsider cannot enumerate another pair DM messages'
);
SELECT throws_ok(
  $$
    SELECT public.send_chat_message_idempotent(
      '40000000-0000-4000-8000-000000000099',
      '20000000-0000-4000-8000-000000000001',
      'outsider send attempt'
    )
  $$,
  'P0001',
  'not a participant',
  'an outsider cannot send through a security-definer DM RPC'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}';

INSERT INTO phase2_results VALUES (
  'post-first',
  public.create_post_idempotent(
    '40000000-0000-4000-8000-000000000001',
    'idempotent post fixture',
    'confessions',
    'healing'
  )
);
INSERT INTO phase2_results VALUES (
  'post-retry',
  public.create_post_idempotent(
    '40000000-0000-4000-8000-000000000001',
    'idempotent post fixture',
    'confessions',
    'healing'
  )
);

SELECT is(
  (SELECT resource_id FROM phase2_results WHERE result_key = 'post-first'),
  (SELECT resource_id FROM phase2_results WHERE result_key = 'post-retry'),
  'replaying a post mutation returns the original resource'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.posts
     WHERE author_id = '10000000-0000-4000-8000-000000000001'
       AND content = 'idempotent post fixture'
  ),
  1::BIGINT,
  'replaying a post mutation creates one row'
);

SELECT throws_ok(
  format(
    'SELECT public.create_threaded_comment_idempotent(%L, %L, %L)',
    '40000000-0000-4000-8000-000000000001',
    (SELECT resource_id FROM phase2_results WHERE result_key = 'post-first'),
    'same key, different operation'
  ),
  'P0001',
  'mutation id already used for post',
  'a mutation key cannot be reused for another operation kind'
);

INSERT INTO phase2_results VALUES (
  'dm-first',
  public.send_chat_message_idempotent(
    '40000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000001',
    'idempotent dm fixture'
  )
);
INSERT INTO phase2_results VALUES (
  'dm-retry',
  public.send_chat_message_idempotent(
    '40000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000001',
    'idempotent dm fixture'
  )
);

SELECT is(
  (SELECT resource_id FROM phase2_results WHERE result_key = 'dm-first'),
  (SELECT resource_id FROM phase2_results WHERE result_key = 'dm-retry'),
  'replaying a DM mutation returns the original message'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.chat_messages
     WHERE room_id = '20000000-0000-4000-8000-000000000001'
       AND encrypted_payload = 'idempotent dm fixture'
  ),
  1::BIGINT,
  'replaying a DM mutation creates one message'
);
SELECT throws_ok(
  $$
    SELECT public.send_chat_message_idempotent(
      '40000000-0000-4000-8000-000000000003',
      '20000000-0000-4000-8000-000000000002',
      'pending rooms must reject sends'
    )
  $$,
  'P0001',
  'room is not active',
  'pending DM rooms cannot accept messages'
);
SELECT lives_ok(
  $$
    SELECT public.send_chat_message_idempotent(
      '40000000-0000-4000-8000-000000000004',
      '20000000-0000-4000-8000-000000000001',
      '',
      NULL,
      '20000000-0000-4000-8000-000000000001/voice-fixture-d2s.m4a',
      'audio'
    )
  $$,
  'an active DM accepts a room-scoped voice note'
);
SELECT is(
  (
    SELECT attached_media_type
      FROM public.chat_messages
     WHERE attached_media_path =
       '20000000-0000-4000-8000-000000000001/voice-fixture-d2s.m4a'
  ),
  'audio',
  'the DM voice-note media type is persisted'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000003';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000003","role":"authenticated"}';

INSERT INTO phase2_results VALUES (
  'post-other-user',
  public.create_post_idempotent(
    '40000000-0000-4000-8000-000000000001',
    'same key on another account',
    'confessions',
    'healing'
  )
);

SELECT isnt(
  (SELECT resource_id FROM phase2_results WHERE result_key = 'post-first'),
  (SELECT resource_id FROM phase2_results WHERE result_key = 'post-other-user'),
  'mutation keys are scoped to the authenticated account'
);

RESET ROLE;

SELECT is(
  (
    SELECT count(*)
      FROM private.client_mutation_receipts
     WHERE mutation_id = '40000000-0000-4000-8000-000000000001'
  ),
  2::BIGINT,
  'the same mutation key has independent receipts for two accounts'
);
SELECT is(
  (
    SELECT count(*)
      FROM private.client_mutation_receipts
     WHERE user_id = '10000000-0000-4000-8000-000000000001'
       AND mutation_id = '40000000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'a replay stores one receipt per account and mutation key'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT is(
  (
    SELECT count(*)
      FROM public.feed_posts
     WHERE post_id = (
       SELECT resource_id
         FROM phase2_results
        WHERE result_key = 'post-first'
     )
  ),
  1::BIGINT,
  'authenticated post detail reads work without shadow-ban column access'
);

RESET ROLE;
UPDATE public.users
   SET shadow_banned = TRUE
 WHERE user_id = '10000000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT is(
  (
    SELECT count(*)
      FROM public.feed_posts
     WHERE post_id = (
       SELECT resource_id
         FROM phase2_results
        WHERE result_key = 'post-first'
     )
  ),
  0::BIGINT,
  'other users cannot open a shadow-banned author post'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '10000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (
    SELECT count(*)
      FROM public.feed_posts
     WHERE post_id = (
       SELECT resource_id
         FROM phase2_results
        WHERE result_key = 'post-first'
     )
  ),
  1::BIGINT,
  'a shadow-banned author can still open their own post'
);

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
