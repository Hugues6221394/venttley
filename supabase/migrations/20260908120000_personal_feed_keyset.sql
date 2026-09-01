-- personal_feed keyset pagination
--
-- OFFSET pagination walks and discards every skipped row — O(n) cost that
-- compounds under concurrent readers at scale, and the window shifts when new
-- posts arrive (duplicate / skipped rows mid-scroll). Keyset seek from the
-- caller's last (personal_score, created_at, post_id) tuple is stable and
-- constant-time at any depth.
--
-- p_offset remains for backward compatibility; when p_before_post_id is set the
-- cursor path is used and offset is ignored.

DROP FUNCTION IF EXISTS public.personal_feed(INTEGER, INTEGER, TEXT, TEXT);

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
  goal_reached_at TIMESTAMPTZ
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
  my_categories AS (
    SELECT DISTINCT p.category_name
      FROM public.post_likes AS l
      JOIN public.posts AS p ON p.post_id = l.post_id
     WHERE l.user_id = v_uid
       AND l.created_at > now() - INTERVAL '30 days'
  ),
  my_blocks AS (
    SELECT ub.blocked_id
      FROM public.user_blocks AS ub
     WHERE ub.blocker_id = v_uid
  ),
  candidates AS (
    SELECT f.*, u.created_at AS author_created_at
      FROM public.feed_posts AS f
      JOIN public.users AS u ON u.user_id = f.author_id
     WHERE f.deleted_at IS NULL
       AND f.is_story = FALSE
       AND (f.is_whisper = FALSE OR f.created_at > v_cutoff_w)
       AND u.created_at < v_cutoff_a
       AND NOT EXISTS (
         SELECT 1 FROM my_blocks AS b WHERE b.blocked_id = f.author_id
       )
       AND (p_category IS NULL OR f.category_name = p_category)
       AND (p_mood IS NULL OR f.post_mood = p_mood::public.mood_badge_type)
  ),
  ranked AS (
    SELECT
      c.post_id,
      c.author_id,
      c.author_pseudonym,
      c.author_avatar_seed,
      c.author_profile_photo_url,
      c.author_is_verified,
      c.author_karma,
      c.tribe_name,
      c.tribe_slug,
      c.tribe_id,
      c.category_name,
      c.post_type,
      c.content,
      c.post_mood,
      c.is_whisper,
      c.location_bucket,
      c.likes_count,
      c.comments_count,
      c.view_count,
      c.image_url,
      c.audio_url,
      c.audio_duration_seconds,
      c.crisis_level,
      c.created_at,
      c.deleted_at,
      (
        log(GREATEST(c.likes_count + c.comments_count, 1))
        + public._venttly_age_decay(c.created_at)
        + CASE WHEN c.tribe_id IN (SELECT tribe_id FROM my_tribes)
               THEN 1.5 ELSE 0 END
        + CASE WHEN c.category_name IN (SELECT category_name FROM my_categories)
               THEN 0.8 ELSE 0 END
        + CASE WHEN v_bucket IS NOT NULL AND c.location_bucket = v_bucket
               THEN 0.6 ELSE 0 END
        - CASE WHEN c.comments_count > c.likes_count * 4
               THEN 0.8 ELSE 0 END
      )::DOUBLE PRECISION AS personal_score,
      c.music_track_id,
      c.music_start_ms,
      c.music_duration_ms,
      c.music_volume,
      c.goal_reached_at
    FROM candidates AS c
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

REVOKE ALL ON FUNCTION public.personal_feed(
  INTEGER, INTEGER, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.personal_feed(
  INTEGER, INTEGER, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
) TO authenticated;

NOTIFY pgrst, 'reload schema';
