-- Until now the only thing a reader could say about a post was a hug or
-- silence, and silence had to carry "I have read this", "this is not for me"
-- and "please stop showing me this person" all at once.
--
-- These are the two new sentences, and what the feed does with them: hiding
-- one post, quieting one person, and noticing when somebody says the first
-- thing about the same author four times. Plus the page cache, which is only
-- safe if a post that disappears after the ranking cannot come back through
-- it — so that is asserted too, by deleting one and asking again.
--
-- Fixtures use the mood 'sad' and every assertion asks for that mood, so the
-- file measures its own fixtures rather than however many posts happen to be
-- in the database.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(14);

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
    ('fee20000-0000-4000-8000-000000000001'::UUID),  -- the reader
    ('fee20000-0000-4000-8000-000000000002'::UUID),  -- gets told to be quiet
    ('fee20000-0000-4000-8000-000000000003'::UUID),  -- someone the reader reads
    ('fee20000-0000-4000-8000-000000000004'::UUID),  -- four times not interested
    ('fee20000-0000-4000-8000-000000000005'::UUID)   -- a stranger
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('fee20000-0000-4000-8000-000000000001','ni_reader','x','x','R','r','ni_reader','normal','active',1990, now() - INTERVAL '2 years'),
  ('fee20000-0000-4000-8000-000000000002','ni_loud','x','x','L','l','ni_loud','normal','active',1990, now() - INTERVAL '2 years'),
  ('fee20000-0000-4000-8000-000000000003','ni_read','x','x','D','d','ni_read','normal','active',1990, now() - INTERVAL '2 years'),
  ('fee20000-0000-4000-8000-000000000004','ni_cooled','x','x','C','c','ni_cooled','normal','active',1990, now() - INTERVAL '2 years'),
  ('fee20000-0000-4000-8000-000000000005','ni_stranger','x','x','S','s','ni_stranger','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category, visibility)
VALUES ('fee2aaaa-0000-4000-8000-000000000001','Shut','ni-shut',
        'fee20000-0000-4000-8000-000000000002','campus','private');
INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('fee2aaaa-0000-4000-8000-000000000001','fee20000-0000-4000-8000-000000000002','keeper');

INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood,
                          created_at, likes_count)
VALUES
  ('fee2bbbb-0000-4000-8000-000000000001','fee20000-0000-4000-8000-000000000002',
   'mental_health','the one I do not want','sad', now() - INTERVAL '1 minute', 0),
  ('fee2bbbb-0000-4000-8000-000000000002','fee20000-0000-4000-8000-000000000002',
   'mental_health','another one by the same person','sad', now() - INTERVAL '2 minutes', 0),
  -- my own post, which I cannot be uninterested in
  ('fee2bbbb-0000-4000-8000-000000000003','fee20000-0000-4000-8000-000000000001',
   'mental_health','mine','sad', now() - INTERVAL '3 minutes', 0),
  -- four by the same person, to be dismissed one at a time, and a fifth that
  -- has to pay for it
  ('fee2bbbb-0000-4000-8000-000000000011','fee20000-0000-4000-8000-000000000004',
   'mental_health','cooled one','sad', now() - INTERVAL '4 minutes', 0),
  ('fee2bbbb-0000-4000-8000-000000000012','fee20000-0000-4000-8000-000000000004',
   'mental_health','cooled two','sad', now() - INTERVAL '5 minutes', 0),
  ('fee2bbbb-0000-4000-8000-000000000013','fee20000-0000-4000-8000-000000000004',
   'mental_health','cooled three','sad', now() - INTERVAL '6 minutes', 0),
  ('fee2bbbb-0000-4000-8000-000000000014','fee20000-0000-4000-8000-000000000004',
   'mental_health','cooled four','sad', now() - INTERVAL '7 minutes', 0),
  ('fee2bbbb-0000-4000-8000-000000000015','fee20000-0000-4000-8000-000000000004',
   'mental_health','the fifth one','sad', now() - INTERVAL '8 minutes', 0),
  -- a post inside a private tribe the reader has never joined
  ('fee2bbbb-0000-4000-8000-000000000021','fee20000-0000-4000-8000-000000000002',
   'mental_health','behind a door','sad', now() - INTERVAL '9 minutes', 0),
  -- two posts alike in everything except that I read one of these people
  ('fee2bbbb-0000-4000-8000-000000000031','fee20000-0000-4000-8000-000000000003',
   'mental_health','by somebody I read','sad', now() - INTERVAL '10 minutes', 0),
  ('fee2bbbb-0000-4000-8000-000000000032','fee20000-0000-4000-8000-000000000005',
   'mental_health','by somebody I have never read','sad', now() - INTERVAL '10 minutes', 0),
  -- the things that made them somebody I read
  ('fee2bbbb-0000-4000-8000-000000000033','fee20000-0000-4000-8000-000000000003',
   'mental_health','read before','sad', now() - INTERVAL '3 days', 0),
  ('fee2bbbb-0000-4000-8000-000000000034','fee20000-0000-4000-8000-000000000003',
   'mental_health','read before too','sad', now() - INTERVAL '4 days', 0);

UPDATE public.posts SET tribe_id = 'fee2aaaa-0000-4000-8000-000000000001'
 WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000021';

INSERT INTO public.post_likes (post_id, user_id, created_at)
VALUES ('fee2bbbb-0000-4000-8000-000000000033','fee20000-0000-4000-8000-000000000001', now() - INTERVAL '2 days'),
       ('fee2bbbb-0000-4000-8000-000000000034','fee20000-0000-4000-8000-000000000001', now() - INTERVAL '1 day');

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"fee20000-0000-4000-8000-000000000001","role":"authenticated"}';

--------------------------------------------------------------------------
-- Not interested, about one post.
--------------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000001'),
  1,
  'the post is in the feed to start with'
);

SELECT ok(
  public.mark_not_interested('fee2bbbb-0000-4000-8000-000000000001'),
  'a reader can say they are not interested'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000001'),
  0,
  'and it goes'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000002'),
  1,
  'without taking everything else that person wrote with it'
);

SELECT ok(
  public.undo_not_interested('fee2bbbb-0000-4000-8000-000000000001'),
  'and it can be taken back'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000001'),
  1,
  'which puts the post back'
);

--------------------------------------------------------------------------
-- Show less from this person.
--------------------------------------------------------------------------
SELECT ok(
  public.mark_not_interested('fee2bbbb-0000-4000-8000-000000000002', 'author'),
  'a reader can ask to see less of somebody'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE author_id = 'fee20000-0000-4000-8000-000000000002'),
  0,
  'and that quiets everything they have written, not just the one post'
);

--------------------------------------------------------------------------
-- What cannot be said.
--------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT public.mark_not_interested('fee2bbbb-0000-4000-8000-000000000003')$$,
  'that_is_your_own_post',
  'nobody can be uninterested in their own post'
);

SELECT throws_ok(
  $$SELECT public.mark_not_interested('fee2bbbb-0000-4000-8000-000000000021')$$,
  'post_not_found',
  'and not about a post inside a private tribe they never joined'
);

--------------------------------------------------------------------------
-- Saying it four times about one person.
--------------------------------------------------------------------------
SELECT ok(
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000015')
  IS NOT NULL,
  'their fifth post starts out in the feed'
);

SELECT is(
  (
    SELECT count(*)::INT FROM (
      SELECT public.mark_not_interested(p) FROM unnest(ARRAY[
        'fee2bbbb-0000-4000-8000-000000000011'::UUID,
        'fee2bbbb-0000-4000-8000-000000000012'::UUID,
        'fee2bbbb-0000-4000-8000-000000000013'::UUID,
        'fee2bbbb-0000-4000-8000-000000000014'::UUID
      ]) AS p
    ) AS said
  ),
  4,
  'four dismissals of one person'
);

SELECT ok(
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000015')
  >
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000032'),
  'and their fifth post falls behind a stranger''s, without being hidden'
);

--------------------------------------------------------------------------
-- The pool knows who you read.
--------------------------------------------------------------------------
SELECT ok(
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000031')
  <
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'sad')
    WHERE post_id = 'fee2bbbb-0000-4000-8000-000000000032'),
  'two posts alike in everything, and the one by somebody you read comes first'
);

SELECT * FROM finish();
ROLLBACK;
