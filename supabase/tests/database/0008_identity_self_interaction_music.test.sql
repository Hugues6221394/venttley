BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(44);

SELECT ok(
  has_column('public', 'users', 'display_name'),
  'canonical users table has a distinct display name'
);
SELECT ok(
  has_column('public', 'users', 'username_normalized'),
  'canonical users table has a normalized stable username'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.update_my_profile(text,text,text,text,text,boolean,boolean,boolean,text)',
    'EXECUTE'
  ),
  'anonymous callers cannot mutate profile identity'
);
SELECT is(
  (
    SELECT procedure.prosecdef
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid = 'public.search_global(text,integer)'::REGPROCEDURE
  ),
  FALSE,
  'global content search is security invoker so Post RLS remains effective'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.normalize_display_name(text)', 'EXECUTE'
  ),
  'global search does not expose its private identity normalizer'
);
SELECT is(
  (
    SELECT procedure.prosecdef
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid =
       'public.search_user_hits(text,text,integer)'::REGPROCEDURE
  ),
  TRUE,
  'the safe auth-bound profile-search helper alone has definer access'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.set_post_reaction(uuid,text)', 'EXECUTE'
  ),
  'authenticated callers can use desired-state Vent reactions'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.set_post_reaction(uuid,text)', 'EXECUTE'
  ),
  'anonymous callers cannot mutate Vent reactions'
);
SELECT ok(
  NOT (
    SELECT enabled FROM public.feature_flags WHERE flag_key = 'vent_music'
  ),
  'music ships behind a server-side kill switch that defaults off'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.music_enabled_for_me()', 'EXECUTE'
  ) AND NOT has_function_privilege(
    'anon', 'public.music_enabled_for_me()', 'EXECUTE'
  ),
  'music RLS uses an authenticated auth-bound feature bridge'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_catalog.pg_indexes
     WHERE schemaname = 'public'
       AND indexname = 'users_username_normalized_unique'
       AND indexdef ILIKE 'CREATE UNIQUE INDEX%'
  ),
  'normalized usernames have a database uniqueness boundary'
);

INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    'a8100000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'identity_a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"identity_a","avatar_seed":"identity-a","birth_year":2000}'::JSONB,
    now(), now()
  ),
  (
    'a8100000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'identity_b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"identity_b","avatar_seed":"identity-b","birth_year":2000}'::JSONB,
    now(), now()
  );

SELECT lives_ok(
  $$UPDATE public.users SET display_name = 'Midnight Soul'
     WHERE user_id IN (
       'a8100000-0000-4000-8000-000000000001',
       'a8100000-0000-4000-8000-000000000002'
     )$$,
  'display names are deliberately non-unique'
);
SELECT lives_ok(
  $$UPDATE public.users SET display_name = '希望 の 声'
     WHERE user_id = 'a8100000-0000-4000-8000-000000000001'$$,
  'international display names are preserved'
);
SELECT is(
  (
    SELECT display_name_normalized FROM public.users
     WHERE user_id = 'a8100000-0000-4000-8000-000000000001'
  ),
  '希望 の 声',
  'international display name normalization remains searchable'
);
SELECT throws_ok(
  $$UPDATE public.users SET display_name = '<script>alert(1)</script>'
     WHERE user_id = 'a8100000-0000-4000-8000-000000000001'$$,
  'P0001', 'invalid_display_name_characters',
  'unsafe display-name delimiters are rejected server-side'
);
SELECT throws_ok(
  $$UPDATE public.users SET anonymous_pseudonym = 'renamed_account'
     WHERE user_id = 'a8100000-0000-4000-8000-000000000001'$$,
  'P0001', 'username_changes_disabled',
  'direct username changes cannot strand synthetic Auth login'
);
SELECT throws_like(
  $$INSERT INTO auth.users (
      id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) VALUES (
      'a8100000-0000-4000-8000-000000000003',
      'authenticated', 'authenticated', 'duplicate@id.venttly.app',
      '{"provider":"email","providers":["email"]}'::JSONB,
      '{"pseudonym":"IDENTITY_A","avatar_seed":"duplicate","birth_year":2000}'::JSONB,
      now(), now()
    )$$,
  '%duplicate key%',
  'normalized duplicate usernames are rejected'
);

INSERT INTO public.posts (
  post_id, author_id, category_name, content, post_mood, is_story,
  story_audience
) VALUES
  (
    'a8200000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000001',
    'confessions', 'author A public fixture', 'healing', FALSE, 'everyone'
  ),
  (
    'a8200000-0000-4000-8000-000000000002',
    'a8100000-0000-4000-8000-000000000002',
    'confessions', 'author B public fixture', 'healing', FALSE, 'everyone'
  ),
  (
    'a8200000-0000-4000-8000-000000000003',
    'a8100000-0000-4000-8000-000000000001',
    'confessions', 'secretsearchfixture', 'healing', TRUE, 'friends'
  );

INSERT INTO public.posts_comments (
  comment_id, post_id, author_id, content, path
) VALUES
  (
    'a8300000-0000-4000-8000-000000000001',
    'a8200000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000001',
    'author comment', 'a8300000000040008000000000000001'::public.ltree
  ),
  (
    'a8300000-0000-4000-8000-000000000002',
    'a8200000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000002',
    'reader comment', 'a8300000000040008000000000000002'::public.ltree
  );

INSERT INTO public.post_polls (poll_id, post_id, question, closes_at)
VALUES (
  'a8400000-0000-4000-8000-000000000001',
  'a8200000-0000-4000-8000-000000000001',
  'Should the author vote?', now() + INTERVAL '1 day'
);
INSERT INTO public.poll_options (option_id, poll_id, option_text)
VALUES (
  'a8500000-0000-4000-8000-000000000001',
  'a8400000-0000-4000-8000-000000000001', 'No'
);

INSERT INTO public.whispers (
  whisper_id, author_id, audio_path, audio_url,
  audio_duration_seconds, category_name
) VALUES
  (
    'a8600000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000001',
    'fixture/a.m4a', 'https://example.invalid/a.m4a', 10, 'confessions'
  ),
  (
    'a8600000-0000-4000-8000-000000000002',
    'a8100000-0000-4000-8000-000000000002',
    'fixture/b.m4a', 'https://example.invalid/b.m4a', 10, 'confessions'
  );
INSERT INTO public.whisper_comments (
  comment_id, whisper_id, author_id, content
) VALUES
  (
    'a8700000-0000-4000-8000-000000000001',
    'a8600000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000001', 'author reply'
  ),
  (
    'a8700000-0000-4000-8000-000000000002',
    'a8600000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000002', 'listener reply'
  );

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" =
  'a8100000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"a8100000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_ok(
  $$SELECT public.set_post_reaction(
    'a8200000-0000-4000-8000-000000000001', 'hug'
  )$$,
  'P0001', 'self_interaction_not_allowed',
  'author cannot react to their own Vent through the RPC'
);
SELECT throws_ok(
  $$INSERT INTO public.post_likes (post_id, user_id, reaction_type) VALUES (
    'a8200000-0000-4000-8000-000000000001',
    'a8100000-0000-4000-8000-000000000001', 'hug'
  )$$,
  'P0001', 'self_interaction_not_allowed',
  'direct writes cannot bypass the own-Vent reaction guard'
);
SELECT is(
  public.set_post_reaction(
    'a8200000-0000-4000-8000-000000000002', 'love'
  ),
  'love',
  'a different user can react to a Vent'
);
SELECT lives_ok(
  $$SELECT public.set_post_reaction(
    'a8200000-0000-4000-8000-000000000002', 'love'
  )$$,
  'repeating the desired reaction is idempotent'
);
SELECT is(
  (
    SELECT count(*)::INT FROM public.post_likes
     WHERE post_id = 'a8200000-0000-4000-8000-000000000002'
       AND user_id = 'a8100000-0000-4000-8000-000000000001'
  ),
  1,
  'a retry creates exactly one Vent reaction row'
);
SELECT throws_ok(
  $$SELECT public.set_comment_like(
    'a8300000-0000-4000-8000-000000000001', TRUE
  )$$,
  'P0001', 'self_interaction_not_allowed',
  'author cannot like their own comment'
);
SELECT is(
  public.set_comment_like(
    'a8300000-0000-4000-8000-000000000002', TRUE
  ),
  TRUE,
  'another user can like a comment'
);
SELECT lives_ok(
  $$SELECT public.set_comment_like(
    'a8300000-0000-4000-8000-000000000002', TRUE
  )$$,
  'repeating a desired comment like is idempotent'
);
SELECT is(
  (
    SELECT likes_count FROM public.posts_comments
     WHERE comment_id = 'a8300000-0000-4000-8000-000000000002'
  ),
  1,
  'the authoritative comment counter remains correct after a retry'
);
SELECT lives_ok(
  $$SELECT public.create_threaded_comment_idempotent(
    'a8800000-0000-4000-8000-000000000001',
    'a8200000-0000-4000-8000-000000000001',
    'The author can clarify normally.',
    'a8300000-0000-4000-8000-000000000002', NULL, NULL, NULL
  )$$,
  'Vent author can reply to another member on their own Vent'
);
SELECT throws_ok(
  $$SELECT public.cast_poll_vote(
    'a8400000-0000-4000-8000-000000000001',
    'a8500000-0000-4000-8000-000000000001'
  )$$,
  'P0001', 'self_interaction_not_allowed',
  'poll author cannot vote in their own poll'
);
SELECT throws_ok(
  $$SELECT public.set_whisper_reaction_v2(
    'a8600000-0000-4000-8000-000000000001', 'hug'
  )$$,
  'P0001', 'self_interaction_not_allowed',
  'Whisper author cannot react to their own Whisper'
);
SELECT is(
  public.set_whisper_reaction_v2(
    'a8600000-0000-4000-8000-000000000002', 'hope'
  ),
  'hope',
  'a different user can react to a Whisper'
);
SELECT throws_ok(
  $$SELECT public.set_whisper_comment_like(
    'a8700000-0000-4000-8000-000000000001', TRUE
  )$$,
  'P0001', 'self_interaction_not_allowed',
  'author cannot like their own Whisper comment'
);
SELECT is(
  public.set_whisper_comment_like(
    'a8700000-0000-4000-8000-000000000002', TRUE
  ),
  TRUE,
  'another user can like a Whisper comment'
);
SELECT is(
  (SELECT count(*)::INT FROM public.search_music('', NULL, 24, 0)),
  0,
  'disabled music catalog returns no tracks'
);

RESET ROLE;
UPDATE public.feature_flags
   SET enabled = TRUE, rollout_pct = 100
 WHERE flag_key = 'vent_music';

SET LOCAL ROLE authenticated;
SELECT ok(
  (SELECT count(*) FROM public.search_music('', NULL, 24, 0)) >= 1,
  'enabled catalog returns only authorized active tracks'
);
SELECT lives_ok(
  $$SELECT public.set_post_music(
    'a8200000-0000-4000-8000-000000000001',
    'a7100000-0000-4000-8000-000000000001', 0, 15000, 0.75
  )$$,
  'author can attach an authorized active track'
);
SELECT is(
  (
    SELECT music_track_id FROM public.posts
     WHERE post_id = 'a8200000-0000-4000-8000-000000000001'
  ),
  'a7100000-0000-4000-8000-000000000001'::UUID,
  'authorized music attachment is stored by immutable track id'
);
SELECT lives_ok(
  $$SELECT public.set_post_music(
    'a8200000-0000-4000-8000-000000000001',
    'a7100000-0000-4000-8000-000000000001', 0, 15000, 0.75
  )$$,
  'retrying the same music attachment converges safely'
);
SELECT throws_ok(
  $$SELECT public.set_post_music(
    'a8200000-0000-4000-8000-000000000001',
    'ffffffff-ffff-4fff-8fff-ffffffffffff', 0, 15000, 0.75
  )$$,
  'P0001', 'music_track_unavailable',
  'unknown or unauthorized track ids cannot be attached'
);
SELECT throws_ok(
  $$SELECT public.set_post_music(
    'a8200000-0000-4000-8000-000000000002',
    'a7100000-0000-4000-8000-000000000001', 0, 15000, 0.75
  )$$,
  'P0001', 'not your post',
  'a caller cannot attach music to another user Vent'
);
SELECT lives_ok(
  $$SELECT public.set_post_music(
    'a8200000-0000-4000-8000-000000000001', NULL, 0, 15000, 0.75
  )$$,
  'author can remove attached music'
);
SELECT is(
  (
    SELECT music_track_id FROM public.posts
     WHERE post_id = 'a8200000-0000-4000-8000-000000000001'
  ),
  NULL::UUID,
  'music removal clears the complete attachment window'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.search_global('identity_a', 24)
     WHERE hit_kind = 'user'
       AND hit_id = 'a8100000-0000-4000-8000-000000000001'
  ),
  'exact username search resolves the display-name profile result'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.search_global('secretsearchfixture', 24)
     WHERE hit_kind = 'post'
       AND hit_id = 'a8200000-0000-4000-8000-000000000003'
  ),
  'story author can find their own restricted story content'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" =
  'a8100000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"a8100000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT is(
  (
    SELECT count(*)::INT
      FROM public.search_global('secretsearchfixture', 24)
     WHERE hit_kind = 'post'
  ),
  0,
  'global search preserves RLS and hides a non-friend story from outsiders'
);

SELECT * FROM finish();
ROLLBACK;
