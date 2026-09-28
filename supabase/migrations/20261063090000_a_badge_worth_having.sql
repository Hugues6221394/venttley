-- Automatic verification that can actually happen, without becoming common.
--
-- The thresholds were 100,000 connections AND 1,000,000 hugs AND 25,000 vents,
-- all three at once. Nobody reaches that, so the badge only ever arrived
-- through the application form and the hourly sweep existed to answer "no"
-- three aggregate queries at a time, for every unverified account, forever.
--
-- The owner asked for numbers that still require commitment. The arithmetic
-- behind the ones below, for somebody in the top fraction of a percent:
--
--   vents        3-5 a day is a very active writer -> ~1,500 a year. 750 is
--                about six months of showing up, most days.
--   connections  a well-liked account might add 5-10 a day at its best ->
--                2,000 is a year of being worth following.
--   hugs         750 vents at an average of twenty hugs each is 15,000. This
--                is the term that cannot be ground out: it is other people's
--                verdict on the writing, not the writing itself.
--   age          90 days, so none of it can be done in a burst.
--
-- All four are required together. That is the point: reach without resonance
-- is a spammer, resonance without time is a fluke. Tune the constants here.

CREATE OR REPLACE FUNCTION public.evaluate_user_verification(p_user UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_min_connections CONSTANT INT := 2000;
  c_min_posts       CONSTANT INT := 750;
  c_min_hugs        CONSTANT INT := 15000;
  c_min_age_days    CONSTANT INT := 90;

  v_status   TEXT;
  v_already  BOOLEAN;
  v_override TEXT;
  v_friends  INT;
  v_created  TIMESTAMPTZ;
  v_posts    INT;
  v_hugs     INT;
BEGIN
  SELECT account_status, is_verified, verification_override,
         connections_count, created_at
    INTO v_status, v_already, v_override, v_friends, v_created
    FROM public.users WHERE user_id = p_user;

  IF v_status IS NULL THEN RETURN FALSE; END IF;
  IF v_override IS NOT NULL THEN RETURN v_already; END IF;  -- an admin decided
  IF v_already THEN RETURN TRUE; END IF;                    -- promote only

  -- The cheap tests first, all of them columns. The expensive ones below count
  -- rows in posts and post_likes, and there is no reason to do that for an
  -- account that fails on a number already sitting in front of us.
  IF v_status <> 'active'
     OR COALESCE(v_friends, 0) < c_min_connections
     OR v_created > now() - make_interval(days => c_min_age_days)
  THEN
    RETURN FALSE;
  END IF;

  SELECT posts_total, hugs_received INTO v_posts, v_hugs
    FROM public.user_profile_extra_stats(p_user);

  IF COALESCE(v_posts, 0) >= c_min_posts
     AND COALESCE(v_hugs, 0) >= c_min_hugs
  THEN
    UPDATE public.users SET is_verified = TRUE, updated_at = now()
     WHERE user_id = p_user AND is_verified = FALSE;
    BEGIN
      PERFORM public.award(p_user, 'verified');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END $$;

-- And the sweep stops walking every unverified account in the country.
--
-- It called evaluate_user_verification for each one, and that call ran three
-- aggregates including a join across post_likes. At a hundred thousand members
-- that is three hundred thousand scans an hour to produce no answer. The
-- candidates can be narrowed with an index first.
CREATE INDEX IF NOT EXISTS users_verification_candidates_idx
  ON public.users (connections_count DESC)
  WHERE is_verified = FALSE
    AND account_status = 'active'
    AND verification_override IS NULL;

CREATE OR REPLACE FUNCTION public.sweep_user_verification()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_u UUID;
  v_n INT := 0;
BEGIN
  FOR v_u IN
    SELECT user_id FROM public.users
     WHERE is_verified = FALSE
       AND account_status = 'active'
       AND verification_override IS NULL
       -- Mirrors the cheap gate inside evaluate_user_verification. Kept in
       -- step with it by hand, which is worth one comment: the constant below
       -- must not exceed c_min_connections there, or the sweep would skip
       -- accounts that qualify.
       AND COALESCE(connections_count, 0) >= 2000
       AND created_at <= now() - INTERVAL '90 days'
  LOOP
    IF public.evaluate_user_verification(v_u) THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END $$;

SELECT public.record_migration('20261063090000', 'a_badge_worth_having');

NOTIFY pgrst, 'reload schema';
