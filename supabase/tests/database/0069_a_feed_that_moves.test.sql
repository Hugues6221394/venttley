-- The feed was handing out posts row level security had already refused.
--
-- personal_feed ran SECURITY DEFINER as postgres, a role with BYPASSRLS, so
-- the policy on posts -- private tribes, hidden posts, unapproved posts --
-- never ran. The only surviving filter was the author check inside the
-- feed_posts view. The first four assertions here are that leak, written as
-- the attack: a stranger asking for their own feed and being handed somebody
-- else's private tribe.
--
-- The fifth is the other half. A feed that refuses everything is not a fixed
-- feed, it is an outage, so the ordinary public post has to still be there.
--
-- After that: the ranking. Age is a decay now rather than a quantity added to
-- the score for every hour a post has existed, which is why a month-old post
-- with five thousand hugs can still be worth showing and a month-old post
-- with three cannot. Posts already shown are demoted. Two slots in every ten
-- are held for something outside your own circle. And Hot is simply expected
-- to answer at all -- it has been returning "permission denied for
-- materialized view mv_hot_posts" to every signed-in client since the cache
-- behind it was revoked from authenticated.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(18);

-- Every fixture below is posted with the mood 'broken', and every assertion
-- asks the feed for that mood. Without it these assertions say "my fixture is
-- in the top fifty of the whole database", which is a claim about how much
-- else is in the database rather than about the ranking: a few hundred real
-- posts with real engagement on them outrank a fresh empty fixture on merit,
-- as they should, and the file starts failing for the one reason that is not
-- a bug.

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
    ('feed0000-0000-4000-8000-000000000001'::UUID),  -- the reader
    ('feed0000-0000-4000-8000-000000000002'::UUID),  -- a stranger
    ('feed0000-0000-4000-8000-000000000003'::UUID),  -- keeps a private tribe
    ('feed0000-0000-4000-8000-000000000004'::UUID),  -- blocked the reader
    ('feed0000-0000-4000-8000-000000000005'::UUID),  -- posts a great deal
    ('feed0000-0000-4000-8000-000000000006'::UUID),  -- another stranger
    ('feed0000-0000-4000-8000-000000000007'::UUID),  -- second reader
    ('feed0000-0000-4000-8000-000000000008'::UUID),  -- second reader's friend
    ('feed0000-0000-4000-8000-000000000009'::UUID)   -- and another friend
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('feed0000-0000-4000-8000-000000000001','feedreader','x','x','R','r','feedreader','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000002','feedstranger','x','x','S','s','feedstranger','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000003','feedkeeper','x','x','K','k','feedkeeper','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000004','feedblocker','x','x','B','b','feedblocker','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000005','feedprolific','x','x','P','p','feedprolific','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000006','feedother','x','x','O','o','feedother','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000007','feedreadertwo','x','x','R2','r2','feedreadertwo','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000008','feedfriendone','x','x','F1','f1','feedfriendone','normal','active',1990, now() - INTERVAL '2 years'),
  ('feed0000-0000-4000-8000-000000000009','feedfriendtwo','x','x','F2','f2','feedfriendtwo','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category, visibility)
VALUES ('feedaaaa-0000-4000-8000-000000000001','Locked','feed-locked',
        'feed0000-0000-4000-8000-000000000003','campus','private');
INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('feedaaaa-0000-4000-8000-000000000001','feed0000-0000-4000-8000-000000000003','keeper');

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES ('feed0000-0000-4000-8000-000000000004','feed0000-0000-4000-8000-000000000001');

INSERT INTO public.friendships (user_a, user_b, status, requested_by)
VALUES ('feed0000-0000-4000-8000-000000000007','feed0000-0000-4000-8000-000000000008','accepted','feed0000-0000-4000-8000-000000000007'),
       ('feed0000-0000-4000-8000-000000000007','feed0000-0000-4000-8000-000000000009','accepted','feed0000-0000-4000-8000-000000000007');

-- The four a stranger must never be handed, and the one they must.
INSERT INTO public.posts (post_id, author_id, tribe_id, category_name, content,
                          post_mood, created_at, hidden_at, is_approved, likes_count)
VALUES
  ('feedbbbb-0000-4000-8000-000000000001','feed0000-0000-4000-8000-000000000003',
   'feedaaaa-0000-4000-8000-000000000001','mental_health','inside a private tribe',
   'broken', now() - INTERVAL '1 minute', NULL, TRUE, 0),
  ('feedbbbb-0000-4000-8000-000000000002','feed0000-0000-4000-8000-000000000002',
   NULL,'mental_health','hidden by a moderator','broken', now() - INTERVAL '1 minute', now(), TRUE, 0),
  ('feedbbbb-0000-4000-8000-000000000003','feed0000-0000-4000-8000-000000000002',
   NULL,'mental_health','not approved yet','broken', now() - INTERVAL '1 minute', NULL, FALSE, 0),
  ('feedbbbb-0000-4000-8000-000000000004','feed0000-0000-4000-8000-000000000004',
   NULL,'mental_health','written by somebody who blocked me','broken', now() - INTERVAL '1 minute', NULL, TRUE, 0),
  ('feedbbbb-0000-4000-8000-000000000005','feed0000-0000-4000-8000-000000000002',
   NULL,'mental_health','an ordinary public post','broken', now() - INTERVAL '1 minute', NULL, TRUE, 0);

-- Age: a decay, not a ramp.
INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood,
                          created_at, likes_count)
VALUES
  ('feedcccc-0000-4000-8000-000000000001','feed0000-0000-4000-8000-000000000006',
   'mental_health','a day old and loved','broken', now() - INTERVAL '26 hours', 1000),
  ('feedcccc-0000-4000-8000-000000000002','feed0000-0000-4000-8000-000000000006',
   'mental_health','a month old and ordinary','broken', now() - INTERVAL '30 days', 3),
  ('feedcccc-0000-4000-8000-000000000003','feed0000-0000-4000-8000-000000000002',
   'mental_health','a minute old and empty','broken', now() - INTERVAL '2 minutes', 0);

-- Two posts alike in every way except that one has been seen.
INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood,
                          created_at, likes_count)
VALUES
  ('feeddddd-0000-4000-8000-000000000001','feed0000-0000-4000-8000-000000000005',
   'mental_health','already read this one','broken', now() - INTERVAL '3 minutes', 10),
  ('feeddddd-0000-4000-8000-000000000002','feed0000-0000-4000-8000-000000000003',
   'mental_health','have not read this one','broken', now() - INTERVAL '3 minutes', 10);

-- Twelve posts from two friends, for the reserved-slot check.
INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood, created_at)
SELECT ('feedeeee-0000-4000-8000-' || lpad(i::TEXT, 12, '0'))::UUID,
       CASE WHEN i % 2 = 0
            THEN 'feed0000-0000-4000-8000-000000000008'::UUID
            ELSE 'feed0000-0000-4000-8000-000000000009'::UUID END,
       'mental_health', 'from a friend ' || i, 'broken',
       now() - (i || ' minutes')::INTERVAL
  FROM generate_series(1, 12) AS i;

SET session_replication_role = origin;

--------------------------------------------------------------------------
-- The leak.
--------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"feed0000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000001'),
  0,
  'a post inside a private tribe does not reach somebody who never joined it'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000002'),
  0,
  'a post a moderator hid stays hidden'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000003'),
  0,
  'a post still waiting for approval is not published by the feed'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000004'),
  0,
  'and being blocked by someone keeps their posts out of your feed'
);

SELECT is(
  (SELECT count(*)::INT FROM public.feed_posts
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000004'),
  0,
  'a block hides the post everywhere, not only in the feed'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000005'),
  1,
  'while an ordinary public post is still served'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'hot', NULL, NULL, NULL, 'broken')),
  (SELECT count(*)::INT FROM public.personal_feed(50, 'hot', NULL, NULL, NULL, 'broken')),
  'Hot answers a signed-in client instead of refusing the cache behind it'
);

SELECT ok(
  (SELECT count(*) FROM public.personal_feed(50, 'hot', NULL, NULL, NULL, 'broken')) > 0,
  'and returns posts'
);

--------------------------------------------------------------------------
-- The keeper's own tribe is still their feed.
--------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"feed0000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedbbbb-0000-4000-8000-000000000001'),
  1,
  'the keeper of the private tribe still sees what was posted in it'
);

--------------------------------------------------------------------------
-- Age as a decay.
--------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"feed0000-0000-4000-8000-000000000001","role":"authenticated"}';

-- The old score added roughly two points for every day a post had existed,
-- with no ceiling, so the newest post on the screen won whatever was in it:
-- a day of age was worth about forty-six points and a thousand hugs was worth
-- three. This is that comparison.
SELECT ok(
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedcccc-0000-4000-8000-000000000001')
  <
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedcccc-0000-4000-8000-000000000003'),
  'a day-old post with a thousand hugs outranks a minute-old empty one'
);

SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(10, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feedcccc-0000-4000-8000-000000000002'),
  0,
  'while a month-old post with three hugs reaches nobody''s first page'
);

--------------------------------------------------------------------------
-- What you have already been shown.
--------------------------------------------------------------------------
-- Both are in the feed to begin with, and within a slot of each other: the
-- demotion below has to be the thing that separates them.
SELECT is(
  (SELECT count(*)::INT FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id IN ('feeddddd-0000-4000-8000-000000000001',
                      'feeddddd-0000-4000-8000-000000000002')),
  2,
  'two posts alike in everything both start out in the feed'
);

SELECT is(
  public.note_post_impressions(ARRAY['feeddddd-0000-4000-8000-000000000001']::UUID[]),
  1,
  'the client can say which posts reached the screen'
);

SELECT ok(
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feeddddd-0000-4000-8000-000000000002')
  <
  (SELECT feed_position FROM public.personal_feed(50, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE post_id = 'feeddddd-0000-4000-8000-000000000001'),
  'and the one already read falls behind the one that has not been'
);

SELECT throws_ok(
  $$INSERT INTO public.post_impressions (user_id, post_id)
    VALUES ('feed0000-0000-4000-8000-000000000002',
            'feeddddd-0000-4000-8000-000000000001')$$,
  '42501',
  NULL,
  'nobody can write an impression for somebody else'
);

--------------------------------------------------------------------------
-- Paging the same feed, not a feed that moved underneath.
--------------------------------------------------------------------------
SELECT is(
  (WITH anchored AS (SELECT now() AS a),
   p1 AS (SELECT post_id, feed_position FROM anchored, public.personal_feed(3, 'foryou', anchored.a, NULL, NULL, 'broken')),
   p2 AS (SELECT post_id, feed_position FROM anchored, public.personal_feed(3, 'foryou', anchored.a, 3, NULL, 'broken'))
   SELECT count(*)::INT FROM p1 JOIN p2 USING (post_id)),
  0,
  'the second page repeats nothing from the first'
);

SELECT is(
  (WITH anchored AS (SELECT now() AS a),
   pages AS (
     SELECT feed_position FROM anchored, public.personal_feed(3, 'foryou', anchored.a, NULL, NULL, 'broken')
     UNION ALL
     SELECT feed_position FROM anchored, public.personal_feed(3, 'foryou', anchored.a, 3, NULL, 'broken')
   )
   SELECT array_agg(feed_position ORDER BY feed_position)::INT[] FROM pages),
  ARRAY[1,2,3,4,5,6],
  'and skips nothing between them'
);

--------------------------------------------------------------------------
-- Two slots in ten for something outside your own circle.
--------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"feed0000-0000-4000-8000-000000000007","role":"authenticated"}';

SELECT ok(
  (SELECT count(*) FROM public.personal_feed(10, 'foryou', NULL, NULL, NULL, 'broken')
    WHERE author_id NOT IN ('feed0000-0000-4000-8000-000000000008',
                            'feed0000-0000-4000-8000-000000000009')) >= 2,
  'a page of ten holds at least two posts from outside your friends and tribes'
);

SELECT * FROM finish();
ROLLBACK;
