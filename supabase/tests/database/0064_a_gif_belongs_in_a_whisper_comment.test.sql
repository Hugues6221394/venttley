-- A GIF as a comment on a whisper.
--
-- Asked for directly: "ensure in comment section people can share GIFs,
-- emojis, you can like or reply". Likes and replies were already there, emoji
-- are characters in the text, and this is the part that needed a column.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

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
    ('cdf10000-0000-4000-8000-000000000001'::UUID),  -- the whisperer
    ('cdf10000-0000-4000-8000-000000000002'::UUID)   -- answers with a GIF
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES
  ('cdf10000-0000-4000-8000-000000000001','gifwhisperer','x','x','Whisperer','whisperer','gifwhisperer','normal','active',1990),
  ('cdf10000-0000-4000-8000-000000000002','gifreplier','x','x','Replier','replier','gifreplier','normal','active',1990);

INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
 WHERE u.user_id IN ('cdf10000-0000-4000-8000-000000000001',
                     'cdf10000-0000-4000-8000-000000000002')
ON CONFLICT DO NOTHING;

INSERT INTO public.whispers (whisper_id, author_id, audio_path, audio_url,
                             audio_duration_seconds, category_name)
VALUES ('cdf1aaaa-0000-4000-8000-000000000001',
        'cdf10000-0000-4000-8000-000000000001',
        'a.m4a','http://example.test/a.m4a', 30, 'mental_health');

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"cdf10000-0000-4000-8000-000000000002","role":"authenticated"}';

-- Words, as before.
SELECT isnt(
  public.add_whisper_comment(
    'cdf1aaaa-0000-4000-8000-000000000001', 'that sounds hard'
  ),
  NULL,
  'a comment can still be only words'
);

-- A GIF and nothing else, which is how most people answer.
SELECT isnt(
  public.add_whisper_comment(
    'cdf1aaaa-0000-4000-8000-000000000001',
    '',
    NULL, NULL,
    'https://media.tenor.com/example.gif'
  ),
  NULL,
  'and a GIF on its own is a comment'
);

-- Neither is not.
SELECT throws_ok(
  $$ SELECT public.add_whisper_comment('cdf1aaaa-0000-4000-8000-000000000001', '   ') $$,
  'empty comment',
  'but nothing at all is refused'
);

-- Only hotlinks, only over TLS. Nothing uploads, so anything else arrived from
-- somewhere this app has no path for.
SELECT throws_ok(
  $$ SELECT public.add_whisper_comment(
       'cdf1aaaa-0000-4000-8000-000000000001', 'look',
       NULL, NULL, 'http://media.tenor.com/example.gif') $$,
  'image must be an https url',
  'a plain-http image is refused'
);

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'cdf1aaaa-0000-4000-8000-000000000001'),
  2,
  'both are counted'
);

-- And the list hands the URL back, or the sheet has nothing to draw.
SELECT is(
  (SELECT count(*)::INT FROM public.list_whisper_comments(
     'cdf1aaaa-0000-4000-8000-000000000001', 50, 0)
    WHERE image_url = 'https://media.tenor.com/example.gif'),
  1,
  'the GIF comes back with the comment'
);

-- A GIF is liked and replied to like anything else, which is the rest of the
-- ask. Both paths already existed; this is that they still work on a comment
-- whose body is a picture.
--
-- As the whisperer, because liking your own comment is refused outright.
SET LOCAL request.jwt.claims = '{"sub":"cdf10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT ok(
  public.toggle_whisper_comment_like(
    (SELECT comment_id FROM public.whisper_comments
      WHERE image_url IS NOT NULL
        AND whisper_id = 'cdf1aaaa-0000-4000-8000-000000000001')
  ),
  'a GIF comment can be liked'
);

SELECT isnt(
  public.add_whisper_comment(
    'cdf1aaaa-0000-4000-8000-000000000001',
    'ha',
    NULL,
    (SELECT comment_id FROM public.whisper_comments
      WHERE image_url IS NOT NULL
        AND whisper_id = 'cdf1aaaa-0000-4000-8000-000000000001')
  ),
  NULL,
  'and replied to'
);

-- The column itself refuses a row that would slip past the RPC.
SET LOCAL ROLE postgres;
SELECT throws_ok(
  $$ INSERT INTO public.whisper_comments (whisper_id, author_id, content, image_url)
     VALUES ('cdf1aaaa-0000-4000-8000-000000000001',
             'cdf10000-0000-4000-8000-000000000002', '',
             'javascript:alert(1)') $$,
  '23514',
  'new row for relation "whisper_comments" violates check constraint "whisper_comments_image_url_check"',
  'the table refuses an image that is not an https url'
);

SELECT * FROM finish();
ROLLBACK;
