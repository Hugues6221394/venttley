-- The home feed was returning posts without their safety verdict.
--
-- personal_feed lists 35 columns in its RETURNS TABLE and media_status is not
-- among them, even though feed_posts has exposed it since 0087. PostgREST
-- returns a plain map, so a column that is not selected is simply an absent
-- key — indistinguishable, on the client, from a real null. The row-shape
-- guard has been saying so on every launch:
--
--     [WARN] db.missing_columns {source: posts, count: 5,
--       columns: [media_status, card_background_color, card_text_color,
--                 is_story, story_audience]}
--
-- What that meant depended on the client's default, and both were wrong:
--
--   * with the old `?? 'clean'`, every image in the home feed rendered
--     unveiled regardless of its verdict. Media the scanner had marked
--     sensitive was displayed as though it had been cleared. That is the
--     failure this whole subsystem exists to prevent.
--   * with the current fail-safe `?? 'pending'`, every image in the home feed
--     is veiled instead — which is why ordinary photos looked blurred.
--
-- The default was never the bug. The bug is a feed that does not report the
-- verdict at all, and no default can be right when the fact is missing.
--
-- Changing RETURNS TABLE changes the return type, which CREATE OR REPLACE
-- refuses with 42P13. So this drops and recreates, and re-GRANTs — dropping a
-- function takes its privileges with it, and forgetting that would leave the
-- feed unreadable for every user.
--
-- WHILE HERE: what "personalised" was missing
--
-- The ranking was already per-user — tribes, liked categories, location — so
-- the feed was never identical for everyone. But the strongest signal any
-- social app has was absent: it did not know who you are friends with. A post
-- from someone you talk to every day scored exactly the same as a stranger's.
-- Three additions, in order of how much they change what you see:
--
--   1. Friends. An accepted friendship is the clearest statement a person
--      makes about whose posts they want, and it outranks every other term.
--   2. Author diversity. Nothing stopped one prolific poster taking ten of
--      the top twenty slots. Each additional post by the same author now
--      scores progressively lower, so a feed cannot become one person.
--   3. Already-engaged posts drop out. Something you have already liked has
--      served its purpose; showing it again is a slot not spent on something
--      new, and is the main reason a feed feels stale on reopening.
--
-- And one safety correction: blocks were being applied in one direction only.
-- Posts were hidden from people you blocked, but not from people who blocked
-- you — so blocking someone did not stop their content reaching you if they
-- were the one who acted. Now both directions.

BEGIN;

DROP FUNCTION IF EXISTS public.personal_feed(
  INTEGER, INTEGER, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
);

CREATE FUNCTION public.personal_feed(
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0,
  p_category TEXT DEFAULT NULL,
  p_mood TEXT DEFAULT NULL,
  p_before_score DOUBLE PRECISION DEFAULT NULL,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_post_id UUID DEFAULT NULL
)
RETURNS TABLE(
  post_id UUID,
  author_id UUID,
  author_pseudonym TEXT,
  author_avatar_seed VARCHAR,
  author_profile_photo_url TEXT,
  author_is_verified BOOLEAN,
  author_karma INTEGER,
  tribe_name VARCHAR,
  tribe_slug TEXT,
  tribe_id UUID,
  category_name VARCHAR,
  post_type VARCHAR,
  content TEXT,
  post_mood public.mood_badge_type,
  is_whisper BOOLEAN,
  location_bucket TEXT,
  likes_count INTEGER,
  comments_count INTEGER,
  view_count INTEGER,
  image_url TEXT,
  audio_url TEXT,
  audio_duration_seconds INTEGER,
  crisis_level TEXT,
  created_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  personal_score DOUBLE PRECISION,
  music_track_id UUID,
  music_start_ms INTEGER,
  music_duration_ms INTEGER,
  music_volume REAL,
  goal_reached_at TIMESTAMPTZ,
  -- The five the client was guessing at.
  media_status TEXT,
  card_background_color TEXT,
  card_text_color TEXT,
  is_story BOOLEAN,
  story_audience TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_uid UUID := auth.uid();
  v_bucket TEXT;
  v_cutoff_w TIMESTAMPTZ := now() - INTERVAL '24 hours';
  v_cutoff_a TIMESTAMPTZ := now() - INTERVAL '1 hour';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT lower(home_city)
    INTO v_bucket
    FROM public.users
   WHERE user_id = v_uid;

  RETURN QUERY
  WITH
  my_tribes AS (
    SELECT tm.tribe_id
      FROM public.tribe_members AS tm
     WHERE tm.user_id = v_uid
  ),
  my_friends AS (
    -- friendships stores the pair ordered (user_a < user_b), so membership has
    -- to be checked from both ends and the friend is whichever one is not me.
    SELECT CASE WHEN f.user_a = v_uid THEN f.user_b ELSE f.user_a END AS friend_id
      FROM public.friendships AS f
     WHERE f.status = 'accepted'
       AND (f.user_a = v_uid OR f.user_b = v_uid)
  ),
  my_categories AS (
    SELECT DISTINCT p.category_name
      FROM public.post_likes AS l
      JOIN public.posts AS p ON p.post_id = l.post_id
     WHERE l.user_id = v_uid
       AND l.created_at > now() - INTERVAL '30 days'
  ),
  my_likes AS (
    SELECT l.post_id FROM public.post_likes AS l WHERE l.user_id = v_uid
  ),
  my_blocks AS (
    -- Both directions. Previously only blocker_id = me was applied, so if
    -- somebody blocked you, their posts still reached your feed.
    SELECT ub.blocked_id AS other FROM public.user_blocks AS ub
     WHERE ub.blocker_id = v_uid
    UNION
    SELECT ub.blocker_id FROM public.user_blocks AS ub
     WHERE ub.blocked_id = v_uid
  ),
  candidates AS (
    SELECT f.*, u.created_at AS author_created_at
      FROM public.feed_posts AS f
      JOIN public.users AS u ON u.user_id = f.author_id
     WHERE f.deleted_at IS NULL
       AND f.is_story = FALSE
       AND (f.is_whisper = FALSE OR f.created_at > v_cutoff_w)
       AND u.created_at < v_cutoff_a
       -- Blocked media never reaches a feed, whatever else it scores. The
       -- scanner's verdict is not advisory.
       AND f.media_status <> 'blocked'
       AND NOT EXISTS (
         SELECT 1 FROM my_blocks AS b WHERE b.other = f.author_id
       )
       -- Already liked: you have seen it and acted on it. Keeping it in
       -- competes with posts you have not seen, which is what makes a feed
       -- feel like the same feed every time you open it.
       AND NOT EXISTS (
         SELECT 1 FROM my_likes AS ml WHERE ml.post_id = f.post_id
       )
       AND (p_category IS NULL OR f.category_name = p_category)
       AND (p_mood IS NULL OR f.post_mood = p_mood::public.mood_badge_type)
  ),
  scored AS (
    SELECT
      c.*,
      (
        log(GREATEST(c.likes_count + c.comments_count, 1))
        + public._venttly_age_decay(c.created_at)
        -- The strongest term, deliberately. Being friends is the most
        -- explicit statement someone makes about whose posts they want.
        + CASE WHEN c.author_id IN (SELECT friend_id FROM my_friends)
               THEN 2.5 ELSE 0 END
        + CASE WHEN c.tribe_id IN (SELECT tribe_id FROM my_tribes)
               THEN 1.5 ELSE 0 END
        + CASE WHEN c.category_name IN (SELECT category_name FROM my_categories)
               THEN 0.8 ELSE 0 END
        + CASE WHEN v_bucket IS NOT NULL AND c.location_bucket = v_bucket
               THEN 0.6 ELSE 0 END
        - CASE WHEN c.comments_count > c.likes_count * 4
               THEN 0.8 ELSE 0 END
      )::DOUBLE PRECISION AS base_score
    FROM candidates AS c
  ),
  ranked AS (
    SELECT
      s.post_id,
      s.author_id,
      s.author_pseudonym,
      s.author_avatar_seed,
      s.author_profile_photo_url,
      s.author_is_verified,
      s.author_karma,
      s.tribe_name,
      s.tribe_slug,
      s.tribe_id,
      s.category_name,
      s.post_type,
      s.content,
      s.post_mood,
      s.is_whisper,
      s.location_bucket,
      s.likes_count,
      s.comments_count,
      s.view_count,
      s.image_url,
      s.audio_url,
      s.audio_duration_seconds,
      s.crisis_level,
      s.created_at,
      s.deleted_at,
      -- Author diversity. The nth-best post by an author it has already shown
      -- is penalised, so one prolific poster cannot own the feed. Computed
      -- over the whole candidate set rather than the page, so the score of a
      -- given post does not change as you scroll — keyset pagination below
      -- depends on that being stable.
      (
        s.base_score
        - (
            ROW_NUMBER() OVER (
              PARTITION BY s.author_id ORDER BY s.base_score DESC, s.post_id
            ) - 1
          ) * 0.7
      )::DOUBLE PRECISION AS personal_score,
      s.music_track_id,
      s.music_start_ms,
      s.music_duration_ms,
      s.music_volume,
      s.goal_reached_at,
      s.media_status,
      s.card_background_color,
      s.card_text_color,
      s.is_story,
      s.story_audience
    FROM scored AS s
  ),
  paged AS (
    SELECT *
      FROM ranked AS r
     WHERE p_before_post_id IS NULL
        OR r.personal_score < p_before_score
        OR (
          r.personal_score = p_before_score
          AND r.created_at < p_before_created_at
        )
        OR (
          r.personal_score = p_before_score
          AND r.created_at = p_before_created_at
          AND r.post_id < p_before_post_id
        )
  )
  SELECT *
    FROM paged
   ORDER BY personal_score DESC, created_at DESC, post_id DESC
   OFFSET CASE
            WHEN p_before_post_id IS NULL THEN GREATEST(0, p_offset)
            ELSE 0
          END
   LIMIT GREATEST(1, LEAST(p_limit, 100));
END;
$$;

COMMENT ON FUNCTION public.personal_feed(
  INTEGER, INTEGER, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
) IS
  'Per-user ranked home feed. Returns media_status so the client can veil correctly rather than guess, and never returns blocked media at all.';

-- Dropping the function dropped its privileges with it. Without these the feed
-- returns a permission error for every signed-in user.
REVOKE ALL ON FUNCTION public.personal_feed(
  INTEGER, INTEGER, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.personal_feed(
  INTEGER, INTEGER, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260919090000', 'personal_feed_safety_and_signals'
);

NOTIFY pgrst, 'reload schema';
