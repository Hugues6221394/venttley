-- 0038_premium_feed_media_and_stats.sql
--
-- Wires the design-spec premium feed end-to-end:
--   1. posts.image_url / image_path / audio_url / audio_path / audio_duration_seconds
--   2. post-media storage bucket (author-owned, signed-URL-friendly)
--   3. feed_posts view surfaces media columns + story view count
--   4. story_views table + mark_story_viewed + denormalised view_count
--   5. home_stats RPC backs the 4-tile hero (vents today / supporters /
--      daily hugs / streak)
--   6. trending_categories RPC backs the Global Pulse hashtag chips
--   7. trending_voices RPC backs the Discover "Rising Voices" section
--
-- Naming convention matches the prior migrations: SECURITY DEFINER for
-- author-gated mutations; SECURITY INVOKER views for read paths so RLS
-- on the underlying tables is honoured.

-- =========================================================================
-- 1) posts.media columns
-- =========================================================================
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS image_url               TEXT,
    ADD COLUMN IF NOT EXISTS image_path              TEXT,
    ADD COLUMN IF NOT EXISTS audio_url               TEXT,
    ADD COLUMN IF NOT EXISTS audio_path              TEXT,
    ADD COLUMN IF NOT EXISTS audio_duration_seconds  INT
        CHECK (audio_duration_seconds IS NULL OR audio_duration_seconds BETWEEN 1 AND 600);

COMMENT ON COLUMN public.posts.image_url IS
  'Public URL of the optional attached image. Author-owned object in post-media bucket.';
COMMENT ON COLUMN public.posts.audio_url IS
  'Public URL of the optional attached voice note. Cap of 600s enforced server-side.';

-- =========================================================================
-- 2) Storage bucket + RLS for post media
-- =========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'post-media',
    'post-media',
    true,
    20 * 1024 * 1024,
    ARRAY[
      'image/jpeg','image/png','image/webp','image/heic','image/gif',
      'audio/mpeg','audio/mp4','audio/aac','audio/ogg','audio/webm','audio/wav','audio/x-m4a'
    ]
)
ON CONFLICT (id) DO UPDATE
   SET public             = EXCLUDED.public,
       file_size_limit    = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "post media owner insert" ON storage.objects;
CREATE POLICY "post media owner insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

DROP POLICY IF EXISTS "post media owner delete" ON storage.objects;
CREATE POLICY "post media owner delete"
    ON storage.objects FOR DELETE
    USING (
      bucket_id = 'post-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

-- Public read so feed_posts can hand out the URL without signing each fetch.
DROP POLICY IF EXISTS "post media public read" ON storage.objects;
CREATE POLICY "post media public read"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'post-media');

-- =========================================================================
-- 3) story_views — per-(story, viewer) timestamp + denormalised view_count
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.story_views (
    post_id     UUID NOT NULL REFERENCES public.posts(post_id) ON DELETE CASCADE,
    viewer_id   UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    viewed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, viewer_id)
);

CREATE INDEX IF NOT EXISTS story_views_post_idx
    ON public.story_views(post_id);

ALTER TABLE public.story_views ENABLE ROW LEVEL SECURITY;

-- A viewer can record / inspect their own row. RPC bypasses anyway.
DROP POLICY IF EXISTS "story view self read"   ON public.story_views;
CREATE POLICY "story view self read"
    ON public.story_views FOR SELECT
    USING (viewer_id = auth.uid());

DROP POLICY IF EXISTS "story view self insert" ON public.story_views;
CREATE POLICY "story view self insert"
    ON public.story_views FOR INSERT
    WITH CHECK (viewer_id = auth.uid());

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS view_count INT NOT NULL DEFAULT 0
        CHECK (view_count >= 0);

CREATE OR REPLACE FUNCTION public._bump_post_view_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.posts
       SET view_count = view_count + 1
     WHERE post_id = NEW.post_id;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS story_views_bump_count ON public.story_views;
CREATE TRIGGER story_views_bump_count
    AFTER INSERT ON public.story_views
    FOR EACH ROW EXECUTE FUNCTION public._bump_post_view_count();

-- Idempotent: silently skips when the viewer has already seen this story.
CREATE OR REPLACE FUNCTION public.mark_story_viewed(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_inserted INT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    INSERT INTO story_views (post_id, viewer_id)
    VALUES (p_post_id, v_me)
    ON CONFLICT (post_id, viewer_id) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted > 0;
END $$;

REVOKE ALL ON FUNCTION public.mark_story_viewed(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_story_viewed(UUID) TO authenticated;

-- =========================================================================
-- 4) feed_posts: surface media + view count, drop & recreate
-- =========================================================================
DROP VIEW IF EXISTS public.feed_hot   CASCADE;
DROP VIEW IF EXISTS public.feed_posts CASCADE;

CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE(
        '@' || pr.pseudonym,
        '@' || u.anonymous_pseudonym,
        '@anonymous'
    ) AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS author_avatar_seed,
    CASE
      WHEN p.persona_id IS NULL THEN u.profile_photo_url
      ELSE NULL
    END AS author_profile_photo_url,
    COALESCE(u.is_verified, false) AS author_is_verified,
    COALESCE(u.karma_points, 0)    AS author_karma,
    p.persona_id,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
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
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users    u  ON u.user_id     = p.author_id
LEFT JOIN public.personas pr ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
LEFT JOIN public.tribes   t  ON t.tribe_id    = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

CREATE VIEW public.feed_hot WITH (security_invoker = true) AS
SELECT f.*, h.hot_score
  FROM public.feed_posts f
  JOIN public.mv_hot_posts h ON h.post_id = f.post_id;
GRANT SELECT ON public.feed_hot TO authenticated, anon;

-- Refresh personal_feed to project the new shape (image_url / audio_url /
-- audio_duration_seconds / view_count) the same way feed_posts now does.
DROP FUNCTION IF EXISTS public.personal_feed(INT, TEXT, TEXT);

CREATE FUNCTION public.personal_feed(
    p_limit     INT  DEFAULT 50,
    p_category  TEXT DEFAULT NULL,
    p_mood      TEXT DEFAULT NULL
) RETURNS TABLE (
    post_id                  UUID,
    author_id                UUID,
    author_pseudonym         TEXT,
    author_avatar_seed       VARCHAR,
    author_profile_photo_url TEXT,
    author_is_verified       BOOLEAN,
    author_karma             INTEGER,
    tribe_name               VARCHAR,
    tribe_slug               TEXT,
    tribe_id                 UUID,
    category_name            VARCHAR,
    post_type                VARCHAR,
    content                  TEXT,
    post_mood                mood_badge_type,
    is_whisper               BOOLEAN,
    location_bucket          TEXT,
    likes_count              INTEGER,
    comments_count           INTEGER,
    view_count               INTEGER,
    image_url                TEXT,
    audio_url                TEXT,
    audio_duration_seconds   INTEGER,
    crisis_level             TEXT,
    created_at               TIMESTAMPTZ,
    deleted_at               TIMESTAMPTZ,
    personal_score           DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
#variable_conflict use_column
DECLARE
    v_uid       UUID := auth.uid();
    v_bucket    TEXT;
    v_cutoff_w  TIMESTAMPTZ := NOW() - INTERVAL '24 hours';
    v_cutoff_a  TIMESTAMPTZ := NOW() - INTERVAL '1 hour';
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated';
    END IF;

    SELECT LOWER(home_city) INTO v_bucket
      FROM users WHERE user_id = v_uid;

    RETURN QUERY
    WITH
    my_tribes AS (
        SELECT tribe_id FROM tribe_members WHERE user_id = v_uid
    ),
    my_categories AS (
        SELECT DISTINCT p.category_name
          FROM post_likes l
          JOIN posts p ON p.post_id = l.post_id
         WHERE l.user_id = v_uid
           AND l.created_at > NOW() - INTERVAL '30 days'
    ),
    my_blocks AS (
        SELECT blocked_id FROM user_blocks WHERE blocker_id = v_uid
    ),
    candidates AS (
        SELECT
            f.*,
            u.created_at AS author_created_at
          FROM feed_posts f
          JOIN users u ON u.user_id = f.author_id
         WHERE f.deleted_at IS NULL
           AND (f.is_whisper = FALSE OR f.created_at > v_cutoff_w)
           AND u.created_at < v_cutoff_a
           AND NOT EXISTS (
                 SELECT 1 FROM my_blocks b WHERE b.blocked_id = f.author_id
               )
           AND (p_category IS NULL OR f.category_name = p_category)
           AND (p_mood IS NULL OR f.post_mood = p_mood::mood_badge_type)
    )
    SELECT
        c.post_id, c.author_id, c.author_pseudonym, c.author_avatar_seed,
        c.author_profile_photo_url, c.author_is_verified, c.author_karma,
        c.tribe_name, c.tribe_slug, c.tribe_id,
        c.category_name, c.post_type, c.content, c.post_mood, c.is_whisper,
        c.location_bucket, c.likes_count, c.comments_count, c.view_count,
        c.image_url, c.audio_url, c.audio_duration_seconds,
        c.crisis_level, c.created_at, c.deleted_at,
        (
            LOG(GREATEST(c.likes_count + c.comments_count, 1))
            + _venttly_age_decay(c.created_at)
            + CASE WHEN c.tribe_id IN (SELECT tribe_id FROM my_tribes)
                   THEN 1.5 ELSE 0 END
            + CASE WHEN c.category_name IN (SELECT category_name FROM my_categories)
                   THEN 0.8 ELSE 0 END
            + CASE WHEN v_bucket IS NOT NULL AND c.location_bucket = v_bucket
                   THEN 0.6 ELSE 0 END
            - CASE WHEN c.comments_count > c.likes_count * 4
                   THEN 0.8 ELSE 0 END
        )::DOUBLE PRECISION AS personal_score
      FROM candidates c
     ORDER BY personal_score DESC, c.created_at DESC
     LIMIT GREATEST(1, LEAST(p_limit, 100));
END $$;

REVOKE ALL ON FUNCTION public.personal_feed(INT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.personal_feed(INT, TEXT, TEXT) TO authenticated;

-- =========================================================================
-- 5) home_stats — backs the 4 hero KPIs in one round-trip
--    Returns: vents_today, supporters (friend count), daily_hugs (likes the
--    caller's vents received in the last 24h), streak (current posting
--    streak in days).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.home_stats()
RETURNS TABLE (
    vents_today   INT,
    supporters    INT,
    daily_hugs    INT,
    streak_days   INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    RETURN QUERY
    SELECT
        (SELECT COUNT(*)::INT
           FROM posts p
          WHERE p.deleted_at IS NULL
            AND p.created_at > now() - INTERVAL '24 hours'
            AND (p.is_whisper = FALSE OR p.created_at > now() - INTERVAL '24 hours')
        ) AS vents_today,
        (SELECT COUNT(*)::INT
           FROM friendships f
          WHERE f.status = 'accepted'
            AND (f.user_a = v_me OR f.user_b = v_me)
        ) AS supporters,
        (SELECT COUNT(*)::INT
           FROM post_likes l
           JOIN posts p ON p.post_id = l.post_id
          WHERE p.author_id = v_me
            AND l.created_at > now() - INTERVAL '24 hours'
        ) AS daily_hugs,
        COALESCE((
          SELECT current_count
            FROM user_streaks s
           WHERE s.user_id = v_me
             AND s.streak_kind = 'posting'
        ), 0) AS streak_days;
END $$;

REVOKE ALL ON FUNCTION public.home_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.home_stats() TO authenticated;

-- =========================================================================
-- 6) trending_categories — Global Pulse hashtags
--    Returns category_name + 24h post count, ordered by activity.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.trending_categories(p_limit INT DEFAULT 6)
RETURNS TABLE (
    category_name VARCHAR,
    post_count    INT,
    reaction_sum  INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.category_name,
        COUNT(*)::INT                              AS post_count,
        COALESCE(SUM(p.likes_count), 0)::INT       AS reaction_sum
      FROM posts p
     WHERE p.deleted_at IS NULL
       AND p.created_at > now() - INTERVAL '24 hours'
     GROUP BY p.category_name
     ORDER BY (COUNT(*) * 1.0 + COALESCE(SUM(p.likes_count), 0) * 0.4) DESC,
              COUNT(*) DESC
     LIMIT GREATEST(1, LEAST(p_limit, 20));
END $$;

REVOKE ALL ON FUNCTION public.trending_categories(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trending_categories(INT) TO authenticated, anon;

-- =========================================================================
-- 7) trending_voices — top authors by 7d engagement (likes + comments).
--    Powers Discover "Rising Voices". Excludes the caller, excludes
--    personas, excludes restricted-minor authors, prefers authors with
--    >=1 public (non-whisper) post in the last 7d.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.trending_voices(p_limit INT DEFAULT 6)
RETURNS TABLE (
    user_id           UUID,
    pseudonym         TEXT,
    avatar_seed       VARCHAR,
    profile_photo_url TEXT,
    is_verified       BOOLEAN,
    top_quote         TEXT,
    top_category      VARCHAR,
    top_mood          mood_badge_type,
    engagement_score  INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    RETURN QUERY
    WITH author_stats AS (
        SELECT
            p.author_id,
            SUM(p.likes_count + p.comments_count)::INT AS engagement,
            (ARRAY_AGG(p.post_id ORDER BY (p.likes_count + p.comments_count) DESC))[1] AS top_post_id
          FROM posts p
          JOIN users u ON u.user_id = p.author_id
         WHERE p.deleted_at IS NULL
           AND p.is_whisper = FALSE
           AND p.persona_id IS NULL
           AND p.author_id IS NOT NULL
           AND p.author_id IS DISTINCT FROM v_me
           AND p.created_at > now() - INTERVAL '7 days'
           AND COALESCE(u.safety_tier, 'standard') <> 'restricted_minor'
           AND u.account_status = 'active'
         GROUP BY p.author_id
        HAVING SUM(p.likes_count + p.comments_count) > 0
    )
    SELECT
        u.user_id,
        u.anonymous_pseudonym::TEXT                            AS pseudonym,
        COALESCE(u.avatar_seed, 'default-orb')::VARCHAR        AS avatar_seed,
        u.profile_photo_url::TEXT                              AS profile_photo_url,
        COALESCE(u.is_verified, false)                         AS is_verified,
        LEFT(tp.content, 220)::TEXT                            AS top_quote,
        tp.category_name::VARCHAR                              AS top_category,
        tp.post_mood                                           AS top_mood,
        a.engagement                                           AS engagement_score
      FROM author_stats a
      JOIN users u ON u.user_id = a.author_id
      JOIN posts tp ON tp.post_id = a.top_post_id
     ORDER BY a.engagement DESC, u.karma_points DESC
     LIMIT GREATEST(1, LEAST(p_limit, 12));
END $$;

REVOKE ALL ON FUNCTION public.trending_voices(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trending_voices(INT) TO authenticated;

-- =========================================================================
-- 8) Reload PostgREST so the new RPCs + view columns are visible
-- =========================================================================
NOTIFY pgrst, 'reload schema';
