-- 0058_personal_feed_offset.sql
--
-- Add p_offset to personal_feed so the For You tab can paginate.

DROP FUNCTION IF EXISTS public.personal_feed(INT, TEXT, TEXT);

CREATE FUNCTION public.personal_feed(
    p_limit     INT  DEFAULT 50,
    p_offset    INT  DEFAULT 0,
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
    ),
    ranked AS (
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
    )
    SELECT *
      FROM ranked
     ORDER BY personal_score DESC, created_at DESC
     OFFSET GREATEST(0, p_offset)
     LIMIT GREATEST(1, LEAST(p_limit, 100));
END $$;

REVOKE ALL ON FUNCTION public.personal_feed(INT, INT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.personal_feed(INT, INT, TEXT, TEXT) TO authenticated;
