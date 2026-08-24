BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(5);

INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '71000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'cold-start-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"cold_start_a","avatar_seed":"cold-a","birth_year":2000}'::JSONB,
    NOW() - INTERVAL '2 hours', NOW() - INTERVAL '2 hours'
  ),
  (
    '71000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'cold-start-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"cold_start_b","avatar_seed":"cold-b","birth_year":2000}'::JSONB,
    NOW() - INTERVAL '2 hours', NOW() - INTERVAL '2 hours'
  );

UPDATE public.users
   SET created_at = NOW() - INTERVAL '2 hours'
 WHERE user_id::TEXT LIKE '71000000-0000-4000-8000-%';

INSERT INTO public.posts (
  post_id, author_id, category_name, content, post_mood, created_at
) VALUES (
  '72000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  'confessions', 'database-backed cold-start post', 'hopeful',
  NOW() - INTERVAL '30 minutes'
);

INSERT INTO public.whispers (
  whisper_id, author_id, audio_path, audio_url, audio_duration_seconds,
  category_name, created_at
) VALUES (
  '73000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001/cold-start.m4a',
  'https://media.venttly.test/cold-start.m4a', 12,
  'confessions', NOW() - INTERVAL '20 minutes'
);

INSERT INTO public.tribes (
  tribe_id, name, category, keeper_id, slug, is_private
) VALUES (
  '74000000-0000-4000-8000-000000000001',
  'Cold Start Community', 'support',
  '71000000-0000-4000-8000-000000000001',
  'cold-start-community', FALSE
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '71000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.personal_feed(30, 0, NULL, NULL)
     WHERE post_id = '72000000-0000-4000-8000-000000000001'
  ),
  'a user with no history receives global database posts'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.friend_suggestions(8)
     WHERE user_id = '71000000-0000-4000-8000-000000000001'
  ),
  'a user with no friends receives database-backed people suggestions'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.whispers_feed
     WHERE whisper_id = '73000000-0000-4000-8000-000000000001'
  ),
  'a user with no connections receives community whispers'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.tribe_directory
     WHERE tribe_id = '74000000-0000-4000-8000-000000000001'
  ),
  'a user with no memberships receives public tribe recommendations'
);
SELECT is(
  (SELECT count(*) FROM public.my_friends),
  0::BIGINT,
  'cold-start recommendations do not fabricate friendships'
);

SELECT * FROM finish();
ROLLBACK;
