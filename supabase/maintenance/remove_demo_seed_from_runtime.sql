-- MANUAL, DESTRUCTIVE MAINTENANCE SCRIPT. NEVER RUN DURING A NORMAL DEPLOY.
--
-- Removes historical showcase and test-account datasets from a runtime
-- database. Venttly currently relies on the linked database's launch content
-- for cold-start discovery, so this script must only be used after an operator
-- verifies that enough genuine or first-party editorial content exists.
--
-- Review the selected IDs and take a database backup before execution.

BEGIN;

CREATE TEMP TABLE venttly_demo_users ON COMMIT DROP AS
SELECT user_id
  FROM public.users
 WHERE recovery_key_hash LIKE 'seed-%'
    OR user_id::TEXT LIKE 'a0000000-0000-4000-8000-%'
    OR anonymous_pseudonym IN (
      'tester_user', 'tester_keeper', 'tester_admin',
      'demo_alex', 'demo_sam', 'demo_riley'
    );

DELETE FROM public.notifications
 WHERE user_id IN (SELECT user_id FROM venttly_demo_users)
    OR actor_id IN (SELECT user_id FROM venttly_demo_users)
    OR (kind = 'new_follower'
        AND payload = '{"message":"GoldenHour sent you a friend request"}'::JSONB)
    OR (kind = 'tribe_prompt'
        AND payload = '{"message":"Midnight Confessions is live — come say hi","tribe_slug":"midnight-confessions"}'::JSONB)
    OR payload @> '{"seed":true}'::JSONB;

DELETE FROM public.chat_rooms
 WHERE initiated_by IN (SELECT user_id FROM venttly_demo_users)
    OR received_by IN (SELECT user_id FROM venttly_demo_users)
    OR created_by IN (SELECT user_id FROM venttly_demo_users)
    OR request_preview LIKE 'seed:%';

DELETE FROM public.chat_messages
 WHERE sender_id IN (SELECT user_id FROM venttly_demo_users);

DELETE FROM public.tribe_messages
 WHERE sender_id IN (SELECT user_id FROM venttly_demo_users);

DELETE FROM public.whisper_comments
 WHERE author_id IN (SELECT user_id FROM venttly_demo_users);

DELETE FROM public.whispers
 WHERE author_id IN (SELECT user_id FROM venttly_demo_users)
    OR whisper_id::TEXT LIKE 'f0000000-0000-4000-8000-%'
    OR audio_path LIKE 'seed/%';

DELETE FROM public.posts_comments
 WHERE author_id IN (SELECT user_id FROM venttly_demo_users)
    OR content LIKE 'seed:%'
    OR comment_id::TEXT LIKE 'e0000000-0000-4000-8000-%';

DELETE FROM public.posts
 WHERE author_id IN (SELECT user_id FROM venttly_demo_users)
    OR content LIKE 'seed:%'
    OR post_id::TEXT LIKE 'd0000000-0000-4000-8000-%'
    OR post_id::TEXT LIKE 'd1000000-0000-4000-8000-%';

DELETE FROM public.plug_prompts
 WHERE plug_id IN (SELECT user_id FROM venttly_demo_users)
    OR author_id IN (SELECT user_id FROM venttly_demo_users)
    OR prompt_text LIKE 'seed:%'
    OR prompt_id::TEXT LIKE '99000000-0000-4000-8000-%';

DELETE FROM public.prompt_answers
 WHERE author_id IN (SELECT user_id FROM venttly_demo_users)
    OR answer_text LIKE 'seed:%';

DELETE FROM public.reports
 WHERE reporter_id IN (SELECT user_id FROM venttly_demo_users);

DELETE FROM public.tribes
 WHERE keeper_id IN (SELECT user_id FROM venttly_demo_users)
    OR tribe_id::TEXT LIKE 'b0000000-0000-4000-8000-%';

DELETE FROM public.users
 WHERE user_id IN (SELECT user_id FROM venttly_demo_users);

DELETE FROM auth.users
 WHERE id IN (SELECT user_id FROM venttly_demo_users);

COMMIT;
