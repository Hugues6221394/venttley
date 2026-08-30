BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(31);

-- ============================================================
-- Wiring
-- ============================================================
SELECT ok(
  (
    SELECT count(*)::INT = 0
      FROM (VALUES
        ('private.guard_comment_block()'),
        ('private.guard_whisper_comment_block()'),
        ('private.guard_chat_message_block()')
      ) AS f(sig)
     WHERE has_function_privilege('authenticated', f.sig, 'EXECUTE')
  ),
  'no client can call a block guard directly'
);

SELECT has_trigger(
  'public', 'posts_comments', 'block_guard_post_comments',
  'replies to a post pass a block check'
);
SELECT has_trigger(
  'public', 'whisper_comments', 'block_guard_whisper_comments',
  'replies to a whisper pass a block check'
);
SELECT has_trigger(
  'public', 'chat_messages', 'block_guard_chat_messages',
  'direct messages pass a block check'
);

-- Triggers of the same timing fire in name order. The block check has to win
-- that race, or a blocked write burns the sender's rate-limit budget and runs
-- the moderation classifier before being thrown away.
SELECT is(
  (
    SELECT trigger.tgname
      FROM pg_catalog.pg_trigger AS trigger
      JOIN pg_catalog.pg_class AS class ON class.oid = trigger.tgrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relname = 'posts_comments'
       AND NOT trigger.tgisinternal
       AND (trigger.tgtype::INT & 2) = 2
     ORDER BY trigger.tgname
     LIMIT 1
  ),
  'block_guard_post_comments',
  'the block check is the first thing a new reply is measured against'
);
SELECT is(
  (
    SELECT trigger.tgname
      FROM pg_catalog.pg_trigger AS trigger
      JOIN pg_catalog.pg_class AS class ON class.oid = trigger.tgrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relname = 'chat_messages'
       AND NOT trigger.tgisinternal
       AND (trigger.tgtype::INT & 2) = 2
     ORDER BY trigger.tgname
     LIMIT 1
  ),
  'block_guard_chat_messages',
  'the block check is the first thing a new message is measured against'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.create_threaded_comment(uuid,uuid,uuid,text,uuid,text,text)',
    'EXECUTE'
  ),
  'the commenting RPC that cannot work is no longer offered to clients'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_threaded_comment_idempotent(uuid,uuid,text,uuid,uuid,text,text)',
    'EXECUTE'
  ),
  'the commenting RPC the app actually uses still works'
);

-- ============================================================
-- Fixtures
-- ============================================================
INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '96000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'blockowner@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"block_owner","avatar_seed":"block-owner","birth_year":1995}'::JSONB,
    now(), now()
  ),
  (
    '96000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'blocktarget@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"block_target","avatar_seed":"block-target","birth_year":1995}'::JSONB,
    now(), now()
  ),
  (
    '96000000-0000-4000-8000-000000000003',
    'authenticated', 'authenticated', 'blockbystander@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"block_bystander","avatar_seed":"block-bystander","birth_year":1995}'::JSONB,
    now(), now()
  );

INSERT INTO public.posts (
  post_id, author_id, category_name, content, post_mood, is_story, story_audience
) VALUES
  (
    '96200000-0000-4000-8000-000000000001',
    '96000000-0000-4000-8000-000000000001',
    'confessions', 'a post by the person who does the blocking', 'healing',
    FALSE, 'everyone'
  ),
  (
    '96200000-0000-4000-8000-000000000002',
    '96000000-0000-4000-8000-000000000002',
    'confessions', 'a post by the person who gets blocked', 'healing',
    FALSE, 'everyone'
  ),
  (
    '96200000-0000-4000-8000-000000000003',
    '96000000-0000-4000-8000-000000000003',
    'confessions', 'a post by somebody with no part in this', 'healing',
    FALSE, 'everyone'
  );

INSERT INTO public.whispers (
  whisper_id, author_id, audio_path, audio_url, audio_duration_seconds,
  category_name
) VALUES (
  '96600000-0000-4000-8000-000000000001',
  '96000000-0000-4000-8000-000000000001',
  'fixture/block-owner.m4a', 'https://example.invalid/block-owner.m4a', 10,
  'confessions'
);

-- A thread on the bystander's post, so a reply can be aimed at the blocker
-- without the blocker owning the post it sits under.
INSERT INTO public.posts_comments (
  comment_id, post_id, author_id, content, path
) VALUES (
  '96300000-0000-4000-8000-000000000001',
  '96200000-0000-4000-8000-000000000003',
  '96000000-0000-4000-8000-000000000001',
  'the blocker replying on a neutral post',
  public.text2ltree('96300000000040008000000000000001')
);

-- The conversation that already exists. This is the whole point: it was opened
-- while the two were on speaking terms and can_dm() was happy, and it stays
-- 'active' after the block because block_user() never touches chat rooms.
INSERT INTO public.chat_rooms (
  room_id, initiated_by, received_by, request_preview, room_status
) VALUES
  (
    '96400000-0000-4000-8000-000000000001',
    '96000000-0000-4000-8000-000000000001',
    '96000000-0000-4000-8000-000000000002',
    'a conversation from before the falling-out', 'active'
  ),
  (
    '96400000-0000-4000-8000-000000000002',
    '96000000-0000-4000-8000-000000000001',
    '96000000-0000-4000-8000-000000000003',
    'an unrelated conversation', 'active'
  );

INSERT INTO public.chat_rooms (
  room_id, initiated_by, received_by, request_preview, room_status,
  room_kind, title, created_by
) VALUES (
  '96400000-0000-4000-8000-000000000003',
  '96000000-0000-4000-8000-000000000003',
  NULL,
  'a group all three are in', 'active', 'group', 'Group fixture',
  '96000000-0000-4000-8000-000000000003'
);

INSERT INTO public.chat_room_members (room_id, user_id, member_role) VALUES
  ('96400000-0000-4000-8000-000000000003',
   '96000000-0000-4000-8000-000000000003', 'owner'),
  ('96400000-0000-4000-8000-000000000003',
   '96000000-0000-4000-8000-000000000001', 'member'),
  ('96400000-0000-4000-8000-000000000003',
   '96000000-0000-4000-8000-000000000002', 'member');

-- ============================================================
-- Before the block, everything is ordinary
-- ============================================================
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000001',
      '96200000-0000-4000-8000-000000000001',
      'a perfectly normal reply, before any of this'
    )$$,
  'with no block in place a reply lands as usual'
);
SELECT lives_ok(
  $$SELECT public.send_chat_message_idempotent(
      '96a00000-0000-4000-8000-000000000002',
      '96400000-0000-4000-8000-000000000001',
      'a perfectly normal message, before any of this'
    )$$,
  'with no block in place a direct message sends as usual'
);

-- ============================================================
-- The block
-- ============================================================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.block_user('96000000-0000-4000-8000-000000000002', NULL)$$,
  'the block itself is recorded'
);
SELECT is(
  (
    SELECT room_status FROM public.chat_rooms
     WHERE room_id = '96400000-0000-4000-8000-000000000001'
  ),
  'active',
  'blocking does not close the room, so the send path is what has to refuse'
);

-- ============================================================
-- Replies to a post
-- ============================================================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT throws_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000003',
      '96200000-0000-4000-8000-000000000001',
      'still here, still talking to you'
    )$$,
  'blocked_by_user',
  'a blocked account cannot reply to the blocker''s post'
);
SELECT throws_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000004',
      '96200000-0000-4000-8000-000000000003',
      'answering you under somebody else''s post instead',
      '96300000-0000-4000-8000-000000000001'
    )$$,
  'blocked_by_user',
  'nor reply to the blocker under a third party''s post'
);
SELECT lives_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000005',
      '96200000-0000-4000-8000-000000000003',
      'an unrelated thought on an unrelated post'
    )$$,
  'a block is between two people and costs the blocked account nothing else'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000006',
      '96200000-0000-4000-8000-000000000002',
      'i blocked you but i would like the last word'
    )$$,
  'blocked_by_user',
  'the block binds the blocker too, who cannot keep replying to someone who '
  'can no longer answer'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000003';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000003","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000007',
      '96200000-0000-4000-8000-000000000001',
      'a bystander who never blocked anybody'
    )$$,
  'somebody else''s block does not follow a third party around'
);

-- ============================================================
-- Replies to a whisper
-- ============================================================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT throws_ok(
  $$SELECT public.add_whisper_comment_idempotent(
      '96a00000-0000-4000-8000-000000000008',
      '96600000-0000-4000-8000-000000000001',
      'the same person, through the audio side of the app'
    )$$,
  'blocked_by_user',
  'whispers are not a way around a block'
);

-- ============================================================
-- The conversation that already existed
-- ============================================================
SELECT throws_ok(
  $$SELECT public.send_chat_message_idempotent(
      '96a00000-0000-4000-8000-000000000009',
      '96400000-0000-4000-8000-000000000001',
      'you cannot get rid of me that easily'
    )$$,
  'blocked_by_user',
  'a block closes a direct thread that was opened before it'
);
SELECT is(
  (
    SELECT count(*)::INT FROM public.chat_messages
     WHERE room_id = '96400000-0000-4000-8000-000000000001'
  ),
  1,
  'nothing from the refused send is left behind in the room'
);
SELECT lives_ok(
  $$SELECT public.send_chat_message_idempotent(
      '96a00000-0000-4000-8000-000000000010',
      '96400000-0000-4000-8000-000000000003',
      'a message to the group, which is nobody else''s business'
    )$$,
  'a block between two members does not silently break the group they share'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_ok(
  $$SELECT public.send_chat_message_idempotent(
      '96a00000-0000-4000-8000-000000000011',
      '96400000-0000-4000-8000-000000000001',
      'one more thing before you go'
    )$$,
  'blocked_by_user',
  'the blocker cannot keep using the thread either'
);
SELECT lives_ok(
  $$SELECT public.send_chat_message_idempotent(
      '96a00000-0000-4000-8000-000000000012',
      '96400000-0000-4000-8000-000000000002',
      'an unrelated message to an unrelated person'
    )$$,
  'other conversations are untouched'
);

-- ============================================================
-- Unblocking puts everything back
-- ============================================================
SELECT lives_ok(
  $$SELECT public.unblock_user('96000000-0000-4000-8000-000000000002')$$,
  'the block can be lifted'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000013',
      '96200000-0000-4000-8000-000000000001',
      'thanks for hearing me out'
    )$$,
  'replying works again once the block is lifted'
);
SELECT lives_ok(
  $$SELECT public.send_chat_message_idempotent(
      '96a00000-0000-4000-8000-000000000014',
      '96400000-0000-4000-8000-000000000001',
      'good to be talking again'
    )$$,
  'the old thread reopens once the block is lifted'
);

-- ============================================================
-- Housekeeping paths still work
-- ============================================================
-- Backfills, cron, and the service role have no JWT. They are not people and
-- cannot block each other, so the guard has to let them past — otherwise an
-- old block quietly breaks a migration years later.
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$SELECT public.block_user('96000000-0000-4000-8000-000000000002', NULL)$$,
  'the block goes back on for the last few checks'
);

-- Dropping the role is not enough: the claims outlive it, and auth.uid() reads
-- the claim rather than the role.
RESET ROLE;
SET LOCAL "request.jwt.claim.sub" = '';
SET LOCAL "request.jwt.claims" = '';

SELECT lives_ok(
  $$INSERT INTO public.posts_comments (comment_id, post_id, author_id, content, path)
    VALUES (
      '96300000-0000-4000-8000-000000000002',
      '96200000-0000-4000-8000-000000000001',
      '96000000-0000-4000-8000-000000000002',
      'written by a backfill, not by a person',
      public.text2ltree('96300000000040008000000000000002')
    )$$,
  'a write with no signed-in user behind it is not subject to a block'
);

-- ============================================================
-- Self-interaction
-- ============================================================
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '96000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"96000000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT lives_ok(
  $$SELECT public.create_threaded_comment_idempotent(
      '96a00000-0000-4000-8000-000000000015',
      '96200000-0000-4000-8000-000000000002',
      'adding to my own post while blocked by somebody else'
    )$$,
  'being blocked does not lock an account out of its own posts'
);

-- ============================================================
-- Nothing here weakened the checks that already existed
-- ============================================================
SELECT throws_ok(
  $$SELECT public.start_chat_room('96000000-0000-4000-8000-000000000001', 'hello')$$,
  'DM blocked: send a friend request first',
  'opening a brand new thread is still refused, as it was before'
);
-- has_block() is symmetric but not a definer, so it reads user_blocks through
-- RLS — which only shows a row to the person who created it. Asked as the
-- blocked party it answers "no". That is the reason the guards above are
-- SECURITY DEFINER rather than plain checks: from the caller's own privileges
-- the block the caller is subject to is invisible.
RESET ROLE;
SELECT ok(
  public.has_block(
    '96000000-0000-4000-8000-000000000002',
    '96000000-0000-4000-8000-000000000001'
  ),
  'the block reads the same from either side, to a caller that can see it'
);

SELECT * FROM finish();

ROLLBACK;
