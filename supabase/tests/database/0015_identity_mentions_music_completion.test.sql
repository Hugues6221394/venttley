BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(30);

SELECT has_table(
  'private', 'content_mentions',
  'mention targets are persisted outside the Data API schema'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'private.content_mentions', 'SELECT'),
  'authenticated clients cannot enumerate immutable mention bindings'
);
SELECT has_column(
  'public', 'music_tracks', 'cache_allowed',
  'the catalog explicitly controls preview caching rights'
);
SELECT has_column(
  'public', 'tribe_messages_feed', 'sender_display_name',
  'tribe chat exposes the sender display label'
);
SELECT has_column(
  'public', 'tribe_messages_feed', 'reply_sender_display_name',
  'tribe chat exposes the reply display label'
);
SELECT has_column(
  'public', 'friend_requests_inbox', 'from_display_name',
  'incoming friend requests expose a display label'
);
SELECT has_column(
  'public', 'friend_requests_outbox', 'to_display_name',
  'outgoing friend requests expose a display label'
);
SELECT has_function(
  'public', 'music_catalog_section', ARRAY['text', 'integer'],
  'sectioned music discovery is available'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.music_catalog_section(text,integer)', 'EXECUTE'
  ),
  'signed-in clients can load authorized catalog sections'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.music_catalog_section(text,integer)', 'EXECUTE'
  ),
  'anonymous callers cannot enumerate the music catalog'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.admin_set_user_feature_override(uuid,text,boolean)',
    'EXECUTE'
  ),
  'staff can reach the auth-bound override RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.admin_set_user_feature_override(uuid,text,boolean)',
    'EXECUTE'
  ),
  'anonymous callers cannot reach rollout controls'
);
SELECT ok(
  (SELECT enabled FROM public.feature_flags WHERE flag_key = 'vent_music'),
  'the music master switch can admit explicit internal overrides'
);
SELECT is(
  (SELECT rollout_pct FROM public.feature_flags WHERE flag_key = 'vent_music'),
  0,
  'the default music cohort starts at zero percent'
);

SELECT lives_ok(
  $$INSERT INTO auth.users (
      id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) VALUES
    (
      'b9100000-0000-4000-8000-000000000001',
      'authenticated', 'authenticated', 'mention_a@id.venttly.app',
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"pseudonym":"mention_a","avatar_seed":"mention-a","birth_year":2000}'::jsonb,
      now(), now()
    ),
    (
      'b9100000-0000-4000-8000-000000000002',
      'authenticated', 'authenticated', 'mention_b@id.venttly.app',
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"pseudonym":"mention_b","avatar_seed":"mention-b","birth_year":2000}'::jsonb,
      now(), now()
    )$$,
  'mention fixtures create through the canonical auth trigger'
);
SELECT lives_ok(
  $$UPDATE public.users SET display_name = CASE user_id
      WHEN 'b9100000-0000-4000-8000-000000000001'::uuid THEN 'First Voice'
      ELSE 'Second Voice' END
    WHERE user_id IN (
      'b9100000-0000-4000-8000-000000000001',
      'b9100000-0000-4000-8000-000000000002'
    )$$,
  'display labels remain independent from stable usernames'
);
SELECT lives_ok(
  $$INSERT INTO public.posts (
      post_id, author_id, category_name, content, post_mood
    ) VALUES (
      'b9200000-0000-4000-8000-000000000001',
      'b9100000-0000-4000-8000-000000000001',
      'confessions', 'Thank you @mention_b', 'healing'
    )$$,
  'creating tagged content persists its immutable target'
);
SELECT is(
  (
    SELECT mentioned_user_id
      FROM private.content_mentions
     WHERE source_kind = 'post'
       AND source_id = 'b9200000-0000-4000-8000-000000000001'
  ),
  'b9100000-0000-4000-8000-000000000002'::uuid,
  'the mention binds to the target user id rather than display text'
);
SELECT lives_ok(
  $$UPDATE public.posts
       SET content = 'Edited, still thanking @mention_b'
     WHERE post_id = 'b9200000-0000-4000-8000-000000000001'$$,
  'editing unchanged mentions is retry safe'
);
SELECT is(
  (
    SELECT count(*)::integer FROM private.content_mentions
     WHERE source_kind = 'post'
       AND source_id = 'b9200000-0000-4000-8000-000000000001'
  ),
  1,
  'an edit cannot duplicate the immutable binding'
);
SELECT lives_ok(
  $$UPDATE public.posts
       SET content = 'Edited without a mention'
     WHERE post_id = 'b9200000-0000-4000-8000-000000000001'$$,
  'mention bindings resynchronize on content edits'
);
SELECT is(
  (
    SELECT count(*)::integer FROM private.content_mentions
     WHERE source_kind = 'post'
       AND source_id = 'b9200000-0000-4000-8000-000000000001'
  ),
  0,
  'removed mentions leave no stale recipient binding'
);

INSERT INTO public.feature_flag_overrides (flag_key, user_id, bool_value)
VALUES ('vent_music', 'b9100000-0000-4000-8000-000000000001', TRUE);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" =
  'b9100000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"b9100000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (
    SELECT enabled FROM public.my_feature_flags()
     WHERE flag_key = 'vent_music'
  ),
  TRUE,
  'an explicit internal override enables music for that authenticated user'
);
SELECT throws_ok(
  $$SELECT public.admin_set_user_feature_override(
      'b9100000-0000-4000-8000-000000000002', 'vent_music', TRUE
    )$$,
  'P0001', 'forbidden',
  'a normal authenticated user cannot administer rollout overrides'
);
SELECT lives_ok(
  $$DO $test$
    BEGIN
      PERFORM public.set_post_music(
        'b9200000-0000-4000-8000-000000000001',
        'a7100000-0000-4000-8000-000000000001', 0, 15000, 0.75
      );
      PERFORM public.set_post_music(
        'b9200000-0000-4000-8000-000000000001',
        'a7100000-0000-4000-8000-000000000001', 0, 15000, 0.75
      );
    END $test$;$$,
  'replaying the same music attachment succeeds'
);
SELECT lives_ok(
  $$SELECT * FROM public.music_catalog_section('trending', 12)$$,
  'an enabled user can load an authorized catalog section'
);
SELECT throws_ok(
  $$SELECT * FROM public.music_catalog_section('unknown', 12)$$,
  'P0001', 'unsupported catalog section',
  'catalog section names are allow-listed server-side'
);

RESET ROLE;

SELECT is(
  (
    SELECT use_count FROM private.music_track_usage
     WHERE user_id = 'b9100000-0000-4000-8000-000000000001'
       AND track_id = 'a7100000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'retries do not inflate recently-used or trending music counts'
);
SELECT is(
  (
    SELECT cache_allowed FROM public.music_tracks
     WHERE track_id = 'a7100000-0000-4000-8000-000000000001'
  ),
  TRUE,
  'Venttly-owned previews are explicitly cacheable'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public._notify_mentions(uuid,text,text,uuid,jsonb)',
    'EXECUTE'
  ),
  'clients cannot forge immutable mention bindings or notifications'
);

SELECT * FROM finish();
ROLLBACK;
