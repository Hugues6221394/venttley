-- Expose music and goal state through the paths the app actually reads.
--
-- 20260815224342 added music_track_id / music_start_ms / music_duration_ms /
-- music_volume to public.posts and public.whispers, and 20260816140000 added
-- goal_reached_at to public.posts. Neither rebuilt the views and the RPC the
-- client reads through, so the columns existed on the tables and were invisible
-- to every screen: music on vents and stories did nothing, whisper background
-- music did nothing, and a goal could never show as reached. The features were
-- shipped and inert, and nothing reported it because a view without a column
-- returns no key at all — which reads exactly like a null.
--
-- CREATE OR REPLACE VIEW can only append, never reorder, so every new column
-- goes on the end of each list. whispers_feed carries the track
-- reference only; its details are hydrated client-side like a post's. That is also why feed_hot picks up
-- media_status and the two card colours here: it has been missing them since
-- 20260727133836, so hot-sorted posts lost their chosen card colours while the
-- same post kept them under any other sort.

CREATE OR REPLACE VIEW public.feed_posts
WITH (security_invoker = true) AS
SELECT
  p.post_id,
  p.author_id,
  COALESCE(
    '@' || pr.pseudonym::TEXT,
    '@' || u.anonymous_pseudonym::TEXT,
    '@anonymous'
  ) AS author_pseudonym,
  COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS author_avatar_seed,
  CASE WHEN p.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
    AS author_profile_photo_url,
  COALESCE(u.is_verified, FALSE) AS author_is_verified,
  COALESCE(u.karma_points, 0) AS author_karma,
  p.persona_id,
  t.name AS tribe_name,
  t.slug AS tribe_slug,
  p.tribe_id,
  p.space_id,
  p.category_name,
  p.post_type,
  p.content,
  p.post_mood,
  p.is_whisper,
  p.location_bucket,
  p.likes_count,
  p.comments_count,
  p.view_count,
  p.image_url,
  p.audio_url,
  p.audio_duration_seconds,
  p.crisis_level,
  p.created_at,
  p.edited_at,
  p.deleted_at,
  p.locked_at,
  p.is_keeper_pick,
  p.keeper_pick_at,
  p.media_status,
  p.card_background_color,
  p.card_text_color,
  p.is_story,
  p.story_audience,
  p.music_track_id,
  p.music_start_ms,
  p.music_duration_ms,
  p.music_volume,
  p.goal_reached_at
FROM public.posts AS p
LEFT JOIN public.users AS u ON u.user_id = p.author_id
LEFT JOIN public.personas AS pr
  ON pr.persona_id = p.persona_id
 AND pr.deleted_at IS NULL
LEFT JOIN public.tribes AS t ON t.tribe_id = p.tribe_id
WHERE (SELECT private.can_view_post_author(p.author_id));

CREATE OR REPLACE VIEW public.feed_hot
WITH (security_invoker = true) AS
SELECT
  f.post_id,
  f.author_id,
  f.author_pseudonym,
  f.author_avatar_seed,
  f.author_profile_photo_url,
  f.author_is_verified,
  f.author_karma,
  f.persona_id,
  f.tribe_name,
  f.tribe_slug,
  f.tribe_id,
  f.space_id,
  f.category_name,
  f.post_type,
  f.content,
  f.post_mood,
  f.is_whisper,
  f.location_bucket,
  f.likes_count,
  f.comments_count,
  f.view_count,
  f.image_url,
  f.audio_url,
  f.audio_duration_seconds,
  f.crisis_level,
  f.created_at,
  f.edited_at,
  f.deleted_at,
  f.locked_at,
  f.is_keeper_pick,
  f.keeper_pick_at,
  h.hot_score,
  f.is_story,
  f.story_audience,
  f.media_status,
  f.card_background_color,
  f.card_text_color,
  f.music_track_id,
  f.music_start_ms,
  f.music_duration_ms,
  f.music_volume,
  f.goal_reached_at
FROM public.feed_posts AS f
JOIN public.mv_hot_posts AS h ON h.post_id = f.post_id;

CREATE OR REPLACE VIEW public.whispers_feed WITH (security_invoker = true) AS
SELECT
    w.whisper_id,
    w.author_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')      AS author_avatar_seed,
    CASE WHEN w.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
                                                                AS author_profile_photo_url,
    COALESCE(u.is_verified, false) AS author_is_verified,
    w.persona_id,
    w.audio_url,
    w.audio_duration_seconds,
    w.background_image_url,
    w.voice_filter,
    w.category_name,
    w.title,
    w.description,
    w.plays_count,
    w.likes_count,
    w.comments_count,
    w.crisis_level,
    w.created_at,
    w.deleted_at,
    w.media_status,
    -- No music_duration_ms here on purpose: 20260816130000 leaves it off
    -- because a bed loops for however long the whisper runs, so a duration
    -- would be meaningless. Selecting it would fail — the column does not exist.
    -- The reference only. Track title, artist and preview are hydrated by the
    -- client through music_tracks_by_ids, exactly as posts already do.
    --
    -- Joining public.music_tracks here instead looked tidier and was wrong:
    -- whispers_feed is security_invoker, so the join makes every whisper read
    -- evaluate that table's RLS, which calls music_enabled_for_me and the
    -- private feature-flag helper underneath it. That turned a hot feed query
    -- into a per-row feature-flag check and made list_unheard_whispers fail
    -- outright with 42501, silently dropping the whole already-heard filter.
    w.music_track_id,
    w.music_start_ms,
    w.music_volume
FROM public.whispers w
LEFT JOIN public.users    u  ON u.user_id     = w.author_id
LEFT JOIN public.personas pr ON pr.persona_id = w.persona_id
                            AND pr.deleted_at IS NULL;

-- personal_feed enumerates its own RETURNS TABLE rather than returning SETOF
-- feed_posts, so widening the view is not enough. Changing a function's return
-- type needs a DROP; the new columns go after personal_score in both the type
-- and the projection so the existing positions are untouched.
DROP FUNCTION IF EXISTS public.personal_feed(INTEGER, INTEGER, TEXT, TEXT);

CREATE FUNCTION public.personal_feed(
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0,
  p_category TEXT DEFAULT NULL,
  p_mood TEXT DEFAULT NULL
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
  )
  SELECT *
    FROM ranked
   ORDER BY personal_score DESC, created_at DESC
   OFFSET GREATEST(0, p_offset)
   LIMIT GREATEST(1, LEAST(p_limit, 100));
END;
$$;

REVOKE ALL ON FUNCTION public.personal_feed(INTEGER, INTEGER, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.personal_feed(INTEGER, INTEGER, TEXT, TEXT)
  TO authenticated;

-- CREATE OR REPLACE VIEW keeps existing privileges, but restate them so a
-- fresh database ends up in the same place as a repaired one.
GRANT SELECT ON public.feed_posts TO anon, authenticated;
GRANT SELECT ON public.feed_hot TO anon, authenticated;
GRANT SELECT ON public.whispers_feed TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
