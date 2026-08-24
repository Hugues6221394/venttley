-- ============================================================================
-- Venttly | Investor demo seed (idempotent)
--
-- Creates real Supabase Auth users + live rows for the investor rehearsal:
--   • demo_alex   — primary member login (friends, stories, feed, inbox)
--   • demo_sam    — friend with 24h stories
--   • demo_riley  — friend with stories + whispers
--   • tester_*    — role coverage (run test_accounts.sql first, or included below)
--
-- Password for all demo_* accounts : DemoPass123!
-- Password for all tester_* accounts: TestPass123!
--
-- Run in Supabase SQL Editor AFTER migrations 0067–0068.
-- Safe to re-run: refreshes story timestamps and replaces demo content.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Auth users → public.users via handle_new_auth_user trigger
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
)
SELECT
    '00000000-0000-0000-0000-000000000000'::uuid,
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    pseudonym || '@id.venttly.app',
    crypt(pw, gen_salt('bf')),
    now(),
    jsonb_build_object(
        'pseudonym',   pseudonym,
        'avatar_seed', avatar,
        'birth_year',  1998,
        'safety_tier', 'standard'
    ),
    now(),
    now(),
    '', '', '', ''
FROM (VALUES
    ('demo_alex',  'alex-orb-demo1',  'DemoPass123!'),
    ('demo_sam',   'sam-orb-demo2',   'DemoPass123!'),
    ('demo_riley', 'riley-orb-demo3', 'DemoPass123!')
) AS s(pseudonym, avatar, pw)
WHERE NOT EXISTS (
    SELECT 1 FROM auth.users WHERE email = s.pseudonym || '@id.venttly.app'
);

-- tester accounts (member / keeper / admin) — skip if already present
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
)
SELECT
    '00000000-0000-0000-0000-000000000000'::uuid,
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    pseudonym || '@id.venttly.app',
    crypt('TestPass123!', gen_salt('bf')),
    now(),
    jsonb_build_object(
        'pseudonym',   pseudonym,
        'avatar_seed', avatar,
        'birth_year',  1998,
        'safety_tier', 'standard'
    ),
    now(),
    now(),
    '', '', '', ''
FROM (VALUES
    ('tester_user',   'rose-orb-test1'),
    ('tester_keeper', 'plum-orb-test2'),
    ('tester_admin',  'berry-spark-test3')
) AS s(pseudonym, avatar)
WHERE NOT EXISTS (
    SELECT 1 FROM auth.users WHERE email = s.pseudonym || '@id.venttly.app'
);

-- Roles + keeper tribe (mirrors test_accounts.sql)
UPDATE public.users
   SET user_role = 'super_admin'
 WHERE anonymous_pseudonym = 'tester_admin';

UPDATE public.users
   SET user_role = 'plug', is_verified = true
 WHERE anonymous_pseudonym = 'tester_keeper';

WITH keeper AS (
    SELECT user_id FROM public.users WHERE anonymous_pseudonym = 'tester_keeper'
)
INSERT INTO public.tribes (name, slug, category, description, is_private, keeper_id)
SELECT
    'Quiet Mornings', 'quiet-mornings', 'support',
    'A gentle place for early thoughts. Tea optional. Soft hello required.',
    false, keeper.user_id
FROM keeper
WHERE NOT EXISTS (
    SELECT 1 FROM public.tribes t
     WHERE t.keeper_id = keeper.user_id AND t.slug = 'quiet-mornings'
);

INSERT INTO public.tribe_members (tribe_id, user_id)
SELECT t.tribe_id, u.user_id
  FROM public.tribes t
  JOIN public.users u ON u.user_id = t.keeper_id
 WHERE u.anonymous_pseudonym = 'tester_keeper'
   AND t.slug = 'quiet-mornings'
ON CONFLICT DO NOTHING;

-- Profile polish (optional photos — real HTTPS URLs, served at runtime)
UPDATE public.users SET
    home_city = 'Austin',
    home_country = 'US',
    current_mood = 'hopeful',
    profile_photo_url = 'https://i.pravatar.cc/300?u=demo_alex'
WHERE anonymous_pseudonym = 'demo_alex';

UPDATE public.users SET
    home_city = 'Brooklyn',
    home_country = 'US',
    current_mood = 'happy',
    profile_photo_url = 'https://i.pravatar.cc/300?u=demo_sam'
WHERE anonymous_pseudonym = 'demo_sam';

UPDATE public.users SET
    home_city = 'Chicago',
    home_country = 'US',
    current_mood = 'healing',
    profile_photo_url = 'https://i.pravatar.cc/300?u=demo_riley'
WHERE anonymous_pseudonym = 'demo_riley';

-- ---------------------------------------------------------------------------
-- 1) Wipe prior demo content (posts, whispers, demo inbox threads)
-- ---------------------------------------------------------------------------
DELETE FROM public.chat_messages
 WHERE room_id IN (
    SELECT room_id FROM public.chat_rooms
     WHERE request_preview LIKE 'demo:%'
 );

DELETE FROM public.chat_rooms
 WHERE request_preview LIKE 'demo:%';

-- 0061 replaced the legacy whisper_likes table with typed reactions.
DELETE FROM public.whisper_reactions
 WHERE whisper_id IN (
    SELECT w.whisper_id FROM public.whispers w
     JOIN public.users u ON u.user_id = w.author_id
     WHERE u.anonymous_pseudonym LIKE 'demo_%'
 );

DELETE FROM public.whispers
 WHERE author_id IN (
    SELECT user_id FROM public.users WHERE anonymous_pseudonym LIKE 'demo_%'
 );

DELETE FROM public.post_likes
 WHERE post_id IN (
    SELECT p.post_id FROM public.posts p
     JOIN public.users u ON u.user_id = p.author_id
     WHERE u.anonymous_pseudonym LIKE 'demo_%'
 );

DELETE FROM public.posts
 WHERE author_id IN (
    SELECT user_id FROM public.users WHERE anonymous_pseudonym LIKE 'demo_%'
 );

-- ---------------------------------------------------------------------------
-- 2) Friend graph (accepted — powers stories rail + friend profiles)
-- ---------------------------------------------------------------------------
INSERT INTO public.friendships (user_a, user_b, status, requested_by, accepted_at)
SELECT
    LEAST(a.user_id, b.user_id),
    GREATEST(a.user_id, b.user_id),
    'accepted',
    a.user_id,
    now()
FROM public.users a
JOIN public.users b ON b.anonymous_pseudonym = 'demo_sam'
WHERE a.anonymous_pseudonym = 'demo_alex'
ON CONFLICT (user_a, user_b) DO UPDATE
   SET status = 'accepted', accepted_at = COALESCE(friendships.accepted_at, now());

INSERT INTO public.friendships (user_a, user_b, status, requested_by, accepted_at)
SELECT
    LEAST(a.user_id, b.user_id),
    GREATEST(a.user_id, b.user_id),
    'accepted',
    a.user_id,
    now()
FROM public.users a
JOIN public.users b ON b.anonymous_pseudonym = 'demo_riley'
WHERE a.anonymous_pseudonym = 'demo_alex'
ON CONFLICT (user_a, user_b) DO UPDATE
   SET status = 'accepted', accepted_at = COALESCE(friendships.accepted_at, now());

INSERT INTO public.friendships (user_a, user_b, status, requested_by, accepted_at)
SELECT
    LEAST(a.user_id, b.user_id),
    GREATEST(a.user_id, b.user_id),
    'accepted',
    b.user_id,
    now()
FROM public.users a
JOIN public.users b ON b.anonymous_pseudonym = 'demo_riley'
WHERE a.anonymous_pseudonym = 'demo_sam'
ON CONFLICT (user_a, user_b) DO UPDATE
   SET status = 'accepted', accepted_at = COALESCE(friendships.accepted_at, now());

-- demo members join the keeper tribe
INSERT INTO public.tribe_members (tribe_id, user_id)
SELECT t.tribe_id, u.user_id
  FROM public.tribes t
  CROSS JOIN public.users u
 WHERE t.slug = 'quiet-mornings'
   AND u.anonymous_pseudonym IN ('demo_alex', 'demo_sam', 'demo_riley')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Feed vents (regular posts — not 24h stories)
-- ---------------------------------------------------------------------------
INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'hot_takes', 'user_post',
       'Unpopular opinion: group chats are just anxiety with notifications.',
       'overthinking', false, now() - interval '3 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_alex';

INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'campus_life', 'user_post',
       'Professor said "see you next week" and the whole room collectively exhaled.',
       'happy', false, now() - interval '5 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_sam';

INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'relationships', 'user_post',
       'Matched with someone who replies in full sentences. Suspicious but intrigued.',
       'hopeful', false, now() - interval '7 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_riley';

INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'funny_confessions', 'user_post',
       'I rehearse arguments in the shower and still lose in real life.',
       'anxious', false, now() - interval '9 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_alex';

INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'healing_corner', 'user_post',
       'Small win today: drank water before coffee. The bar is on the floor and I''m still proud.',
       'grateful', false, now() - interval '11 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_riley';

-- ---------------------------------------------------------------------------
-- 4) 24h stories (is_whisper = true, fresh timestamps)
-- ---------------------------------------------------------------------------
INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'late_night', 'user_post',
       'Coffee before the world wakes up. Anyone else a 6am thoughts person?',
       'hopeful', true, now() - interval '2 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_sam';

INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'confessions', 'user_post',
       'Okay but why does one nice text completely reset my whole mood?',
       'happy', true, now() - interval '4 hours'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_riley';

INSERT INTO public.posts (author_id, category_name, post_type, content, post_mood, is_whisper, created_at)
SELECT u.user_id, 'dreams_goals', 'user_post',
       'Manifesting a week where my calendar and my energy match.',
       'hopeful', true, now() - interval '1 hour'
  FROM public.users u WHERE u.anonymous_pseudonym = 'demo_alex';

-- ---------------------------------------------------------------------------
-- 5) Whispers (real public audio URLs — playable in app)
-- ---------------------------------------------------------------------------
INSERT INTO public.whispers (
    author_id, audio_path, audio_url, audio_duration_seconds,
    background_image_url, voice_filter, category_name,
    title, description, plays_count, likes_count, comments_count, created_at
)
SELECT
    u.user_id,
    'demo/sam-night-drive.m4a',
    'https://cdn.pixabay.com/download/audio/2022/03/10/audio_8cbffa913c.mp3?filename=soft-piano-100556.mp3',
    42,
    'https://picsum.photos/seed/venttly-whisper-sam/900/1400',
    'soft',
    'late_night',
    'Night drive thoughts',
    'Windows down, brain loud.',
    128, 14, 3,
    now() - interval '6 hours'
FROM public.users u WHERE u.anonymous_pseudonym = 'demo_sam';

INSERT INTO public.whispers (
    author_id, audio_path, audio_url, audio_duration_seconds,
    background_image_url, voice_filter, category_name,
    title, description, plays_count, likes_count, comments_count, created_at
)
SELECT
    u.user_id,
    'demo/riley-campus.m4a',
    'https://cdn.pixabay.com/download/audio/2022/05/27/audio_1808fbf07a.mp3?filename=storybook-112157.mp3',
    38,
    'https://picsum.photos/seed/venttly-whisper-riley/900/1400',
    'none',
    'campus_life',
    'Library at 2am',
    'If you know, you know.',
    256, 31, 7,
    now() - interval '8 hours'
FROM public.users u WHERE u.anonymous_pseudonym = 'demo_riley';

INSERT INTO public.whispers (
    author_id, audio_path, audio_url, audio_duration_seconds,
    background_image_url, voice_filter, category_name,
    title, description, plays_count, likes_count, comments_count, created_at
)
SELECT
    u.user_id,
    'demo/alex-hot-take.m4a',
    'https://cdn.pixabay.com/download/audio/2021/08/04/audio_12b0c1443c.mp3?filename=ambient-piano-and-strings-10711.mp3',
    55,
    'https://picsum.photos/seed/venttly-whisper-alex/900/1400',
    'anonymous',
    'hot_takes',
    'Hot take hour',
    'No context, just vibes.',
    89, 9, 2,
    now() - interval '12 hours'
FROM public.users u WHERE u.anonymous_pseudonym = 'demo_alex';

-- ---------------------------------------------------------------------------
-- 6) Inbox thread (demo_alex ↔ demo_sam) for story-reply rehearsal
-- ---------------------------------------------------------------------------
INSERT INTO public.chat_rooms (initiated_by, received_by, request_preview, room_status, created_at, updated_at)
SELECT a.user_id, s.user_id,
       'demo:Hey — loved your morning story',
       'active', now() - interval '1 day', now() - interval '20 minutes'
  FROM public.users a, public.users s
 WHERE a.anonymous_pseudonym = 'demo_sam'
   AND s.anonymous_pseudonym = 'demo_alex';

INSERT INTO public.chat_messages (room_id, sender_id, encrypted_payload, nonce_iv, created_at, read_at)
SELECT r.room_id, s.user_id,
       'Your 6am story was so real. Same brain.',
       'v1-plaintext',
       now() - interval '18 minutes',
       now() - interval '15 minutes'
  FROM public.chat_rooms r
  JOIN public.users a ON a.user_id = r.received_by
  JOIN public.users s ON s.user_id = r.initiated_by
 WHERE r.request_preview = 'demo:Hey — loved your morning story'
   AND a.anonymous_pseudonym = 'demo_alex'
   AND s.anonymous_pseudonym = 'demo_sam';

INSERT INTO public.chat_messages (room_id, sender_id, encrypted_payload, nonce_iv, created_at)
SELECT r.room_id, a.user_id,
       'Ha — glad it landed. Want to vent about mornings sometime?',
       'v1-plaintext',
       now() - interval '12 minutes'
  FROM public.chat_rooms r
  JOIN public.users a ON a.user_id = r.received_by
  JOIN public.users s ON s.user_id = r.initiated_by
 WHERE r.request_preview = 'demo:Hey — loved your morning story'
   AND a.anonymous_pseudonym = 'demo_alex'
   AND s.anonymous_pseudonym = 'demo_sam';

COMMIT;

-- ---------------------------------------------------------------------------
-- Credentials (printed after seed)
-- ---------------------------------------------------------------------------
SELECT
    u.anonymous_pseudonym AS username,
    CASE
        WHEN u.anonymous_pseudonym LIKE 'demo_%' THEN 'DemoPass123!'
        ELSE 'TestPass123!'
    END AS password,
    u.user_role AS role,
    COALESCE(u.profile_photo_url, '(avatar only)') AS profile_photo
FROM public.users u
WHERE u.anonymous_pseudonym IN (
    'demo_alex', 'demo_sam', 'demo_riley',
    'tester_user', 'tester_keeper', 'tester_admin'
)
ORDER BY
    CASE u.anonymous_pseudonym
        WHEN 'demo_alex' THEN 1
        WHEN 'demo_sam' THEN 2
        WHEN 'demo_riley' THEN 3
        WHEN 'tester_keeper' THEN 4
        WHEN 'tester_user' THEN 5
        ELSE 6
    END;
