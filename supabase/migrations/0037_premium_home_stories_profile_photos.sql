-- 0037_premium_home_stories_profile_photos.sql
--
-- Premium Home foundation:
--   * optional profile photos for the main account identity
--   * feed views surface profile photos only for default-profile posts
--   * 24h stories continue to use posts.is_whisper, reactions, comments,
--     and friend-gated DMs rather than introducing a parallel story stack

-- =========================================================================
-- 1) Users: optional profile photo metadata
-- =========================================================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS profile_photo_path TEXT,
    ADD COLUMN IF NOT EXISTS profile_photo_url  TEXT;

COMMENT ON COLUMN public.users.profile_photo_path IS
  'Supabase Storage path for the optional main-profile photo.';
COMMENT ON COLUMN public.users.profile_photo_url IS
  'Public URL for the optional main-profile photo. Null keeps the abstract avatar.';

REVOKE SELECT (profile_photo_path) ON public.users FROM authenticated, anon;
GRANT SELECT (profile_photo_url) ON public.users TO authenticated, anon;

-- =========================================================================
-- 2) Storage bucket + RLS for optional profile photos
-- =========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'profile-photos',
    'profile-photos',
    true,
    6 * 1024 * 1024,
    ARRAY['image/jpeg','image/png','image/webp','image/heic','image/gif']
)
ON CONFLICT (id) DO UPDATE
   SET public             = EXCLUDED.public,
       file_size_limit    = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "profile photos owner insert" ON storage.objects;
CREATE POLICY "profile photos owner insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'profile-photos'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

DROP POLICY IF EXISTS "profile photos owner update" ON storage.objects;
CREATE POLICY "profile photos owner update"
    ON storage.objects FOR UPDATE
    USING (
      bucket_id = 'profile-photos'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    )
    WITH CHECK (
      bucket_id = 'profile-photos'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

DROP POLICY IF EXISTS "profile photos owner delete" ON storage.objects;
CREATE POLICY "profile photos owner delete"
    ON storage.objects FOR DELETE
    USING (
      bucket_id = 'profile-photos'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

-- Public bucket URLs are world-readable, but authenticated clients may still
-- select their own storage rows for SDK bookkeeping.
DROP POLICY IF EXISTS "profile photos owner read" ON storage.objects;
CREATE POLICY "profile photos owner read"
    ON storage.objects FOR SELECT
    USING (
      bucket_id = 'profile-photos'
      AND owner = auth.uid()
    );

-- =========================================================================
-- 3) Avatar RPC: allow the new outfit axis in v2 seeds
-- =========================================================================
CREATE OR REPLACE FUNCTION public.update_user_avatar(p_seed TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_seed IS NULL OR length(p_seed) = 0 OR length(p_seed) > 320 THEN
        RAISE EXCEPTION 'invalid seed length';
    END IF;
    IF p_seed !~ '^(v2:[a-z0-9=;]+|[a-z0-9_-]+)$' THEN
        RAISE EXCEPTION 'invalid seed format';
    END IF;
    UPDATE public.users SET avatar_seed = p_seed, updated_at = now()
     WHERE user_id = v_me;
END $$;

REVOKE ALL ON FUNCTION public.update_user_avatar(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_avatar(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_user_profile_photo(
    p_path TEXT,
    p_url  TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_previous TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_path IS NULL OR p_path !~ ('^' || v_me::text || '/[A-Za-z0-9._-]+$') THEN
        RAISE EXCEPTION 'invalid profile photo path';
    END IF;
    IF p_url IS NULL OR length(p_url) > 2048 THEN
        RAISE EXCEPTION 'invalid profile photo url';
    END IF;

    SELECT profile_photo_path INTO v_previous
      FROM public.users
     WHERE user_id = v_me;

    UPDATE public.users
       SET profile_photo_path = p_path,
           profile_photo_url  = p_url,
           updated_at         = now()
     WHERE user_id = v_me;

    RETURN v_previous;
END $$;

CREATE OR REPLACE FUNCTION public.clear_user_profile_photo()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_previous TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT profile_photo_path INTO v_previous
      FROM public.users
     WHERE user_id = v_me;

    UPDATE public.users
       SET profile_photo_path = NULL,
           profile_photo_url  = NULL,
           updated_at         = now()
     WHERE user_id = v_me;

    RETURN v_previous;
END $$;

REVOKE ALL ON FUNCTION public.set_user_profile_photo(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_user_profile_photo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_user_profile_photo(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_user_profile_photo() TO authenticated;

-- =========================================================================
-- 4) Feed views: profile photo for default-profile authors only
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

-- =========================================================================
-- 5) Personal feed: same shape as feed_posts plus personal_score
-- =========================================================================
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
        c.location_bucket, c.likes_count, c.comments_count, c.crisis_level,
        c.created_at, c.deleted_at,
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
