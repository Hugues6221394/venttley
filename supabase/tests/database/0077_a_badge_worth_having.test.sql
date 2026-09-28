-- Automatic verification had never fired and could never fire: it wanted
-- 100,000 connections and 1,000,000 hugs and 25,000 vents, together. The
-- numbers are reachable now, and these assertions are the ones that matter —
-- that it promotes somebody who has genuinely done the work, and that it
-- refuses everybody who has done only part of it.
--
-- The four conditions are deliberately AND-ed: reach without resonance is a
-- spammer, resonance without time is a fluke. So each is tested by failing
-- exactly one of them.

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
    ('bad90000-0000-4000-8000-000000000001'::UUID),  -- earns it
    ('bad90000-0000-4000-8000-000000000002'::UUID),  -- too few connections
    ('bad90000-0000-4000-8000-000000000003'::UUID),  -- too few vents
    ('bad90000-0000-4000-8000-000000000004'::UUID),  -- too few hugs
    ('bad90000-0000-4000-8000-000000000005'::UUID),  -- too new
    ('bad90000-0000-4000-8000-000000000006'::UUID),  -- suspended
    ('bad90000-0000-4000-8000-000000000007'::UUID),  -- an admin said no
    ('bad90000-0000-4000-8000-000000000008'::UUID)   -- reads the posts
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at,
                          connections_count, is_verified, verification_override)
VALUES
  ('bad90000-0000-4000-8000-000000000001','earnsit','x','x','E','e','earnsit','normal','active',1990, now() - INTERVAL '1 year',  2500, FALSE, NULL),
  ('bad90000-0000-4000-8000-000000000002','fewconn','x','x','F','f','fewconn','normal','active',1990, now() - INTERVAL '1 year',  1999, FALSE, NULL),
  ('bad90000-0000-4000-8000-000000000003','fewvents','x','x','V','v','fewvents','normal','active',1990, now() - INTERVAL '1 year', 2500, FALSE, NULL),
  ('bad90000-0000-4000-8000-000000000004','fewhugs','x','x','H','h','fewhugs','normal','active',1990, now() - INTERVAL '1 year',  2500, FALSE, NULL),
  ('bad90000-0000-4000-8000-000000000005','toonew','x','x','N','n','toonew','normal','active',1990, now() - INTERVAL '30 days',   2500, FALSE, NULL),
  ('bad90000-0000-4000-8000-000000000006','suspended1','x','x','S','s','suspended1','normal','suspended',1990, now() - INTERVAL '1 year', 2500, FALSE, NULL),
  ('bad90000-0000-4000-8000-000000000007','refused','x','x','R','r','refused','normal','active',1990, now() - INTERVAL '1 year', 2500, FALSE, 'manual_off'),
  ('bad90000-0000-4000-8000-000000000008','thereader','x','x','D','d','thereader','normal','active',1990, now() - INTERVAL '2 years', 0, FALSE, NULL);

-- 750 vents each for everybody except the one who is short of them.
INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood, created_at)
SELECT ('bad9bbbb-' || lpad(a.n::TEXT, 4, '0') || '-4000-8000-' || lpad(i::TEXT, 12, '0'))::UUID,
       a.uid, 'mental_health', 'seeded for the threshold test', 'hopeful',
       now() - INTERVAL '200 days'
  FROM (VALUES
         (1, 'bad90000-0000-4000-8000-000000000001'::UUID, 750),
         (2, 'bad90000-0000-4000-8000-000000000002'::UUID, 750),
         (3, 'bad90000-0000-4000-8000-000000000003'::UUID, 749),
         (4, 'bad90000-0000-4000-8000-000000000004'::UUID, 750),
         (5, 'bad90000-0000-4000-8000-000000000005'::UUID, 750),
         (6, 'bad90000-0000-4000-8000-000000000006'::UUID, 750),
         (7, 'bad90000-0000-4000-8000-000000000007'::UUID, 750)
       ) AS a(n, uid, howmany),
       generate_series(1, a.howmany) AS i;

-- 15,000 hugs each, except the one who is short of them. One reader can only
-- like a post once, so the hugs are spread across the posts themselves.
INSERT INTO public.post_likes (post_id, user_id, reaction_type, created_at)
SELECT p.post_id, 'bad90000-0000-4000-8000-000000000008', 'hug', now() - INTERVAL '100 days'
  FROM public.posts p
 WHERE p.author_id IN ('bad90000-0000-4000-8000-000000000001',
                       'bad90000-0000-4000-8000-000000000002',
                       'bad90000-0000-4000-8000-000000000003',
                       'bad90000-0000-4000-8000-000000000005',
                       'bad90000-0000-4000-8000-000000000006',
                       'bad90000-0000-4000-8000-000000000007');

SET session_replication_role = origin;

-- The hug threshold is 15,000 and one reader cannot supply that, so the count
-- is set directly for the accounts whose hugs are supposed to pass. What is
-- under test is the decision, not how the likes were accumulated.
CREATE OR REPLACE FUNCTION pg_temp.fake_stats(p_target UUID)
RETURNS TABLE(posts_total INT, hugs_received INT, connections INT)
LANGUAGE sql STABLE AS $$
  SELECT (SELECT count(*)::INT FROM public.posts WHERE author_id = p_target
            AND deleted_at IS NULL),
         CASE WHEN p_target = 'bad90000-0000-4000-8000-000000000004' THEN 14999
              ELSE 15000 END,
         COALESCE((SELECT connections_count FROM public.users
                    WHERE user_id = p_target), 0);
$$;

SELECT is(
  (SELECT posts_total FROM pg_temp.fake_stats('bad90000-0000-4000-8000-000000000001')),
  750,
  'the fixture writer really does have 750 vents'
);

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000001') = FALSE,
  'nobody is verified on the real hug count, because 15,000 hugs is 15,000 '
  'separate people and this test has one'
);

-- From here the stats function is the faked one, so the decision is the only
-- thing under test.
ALTER FUNCTION public.user_profile_extra_stats(UUID) RENAME TO real_extra_stats;
CREATE OR REPLACE FUNCTION public.user_profile_extra_stats(p_target UUID)
RETURNS TABLE(posts_total INT, hugs_received INT, connections INT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT * FROM pg_temp.fake_stats(p_target);
$$;

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000001'),
  'somebody with the connections, the vents, the hugs and the time is verified'
);

SELECT is(
  (SELECT is_verified FROM public.users WHERE username_normalized = 'earnsit'),
  TRUE,
  'and the badge is actually written to their account'
);

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000002') = FALSE,
  'one connection short is short'
);

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000003') = FALSE,
  'one vent short is short'
);

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000004') = FALSE,
  'one hug short is short — the term nobody can grind alone'
);

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000005') = FALSE,
  'and doing all of it inside a month does not count'
);

SELECT ok(
  public.evaluate_user_verification('bad90000-0000-4000-8000-000000000007') = FALSE,
  'an admin who said no is not overruled by an arithmetic threshold'
);

SELECT * FROM finish();
ROLLBACK;
