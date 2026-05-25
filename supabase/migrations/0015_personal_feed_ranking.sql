-- =====================================================================
-- Migration 0015 — Sprint 3: personal feed ranking
-- =====================================================================
-- Adds the "For You" feed: a SECURITY DEFINER function that blends
-- engagement, recency, tribe affinity, category affinity, and local
-- affinity into a personalized score, then returns feed_posts rows
-- ordered by that score.
--
-- Anti-manipulation guards baked in:
--   - posts from accounts < 1 hour old are suppressed
--   - users on the caller's user_blocks list are suppressed
--   - whispers older than 24h are suppressed (mirrors feed())
--   - the caller's own posts are de-emphasized (small negative bias)
--     so the feed doesn't echo back what they just posted
-- =====================================================================

-- A small helper: age-decay component that matches mv_hot_posts.
CREATE OR REPLACE FUNCTION public._venttly_age_decay(p_created TIMESTAMPTZ)
RETURNS DOUBLE PRECISION
LANGUAGE sql IMMUTABLE
AS $$
    SELECT EXTRACT(EPOCH FROM (p_created - TIMESTAMPTZ '2024-01-01')) / 45000.0;
$$;

CREATE OR REPLACE FUNCTION public.personal_feed(
    p_limit     INT  DEFAULT 50,
    p_category  TEXT DEFAULT NULL,
    p_mood      TEXT DEFAULT NULL
) RETURNS TABLE (
    post_id            UUID,
    author_id          UUID,
    author_pseudonym   TEXT,
    author_avatar_seed VARCHAR,
    author_is_verified BOOLEAN,
    author_karma       INTEGER,
    tribe_name         VARCHAR,
    tribe_slug         TEXT,
    tribe_id           UUID,
    category_name      VARCHAR,
    post_type          VARCHAR,
    content            TEXT,
    post_mood          mood_badge_type,
    is_whisper         BOOLEAN,
    location_bucket    TEXT,
    likes_count        INTEGER,
    comments_count     INTEGER,
    created_at         TIMESTAMPTZ,
    deleted_at         TIMESTAMPTZ,
    personal_score     DOUBLE PRECISION
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
        -- A category the caller has liked in the last 30 days counts
        -- as an interest signal.
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
           AND u.created_at < v_cutoff_a            -- new-account dampening
           AND NOT EXISTS (
                 SELECT 1 FROM my_blocks b WHERE b.blocked_id = f.author_id
               )
           AND (p_category IS NULL OR f.category_name = p_category)
           AND (p_mood IS NULL OR f.post_mood = p_mood::mood_badge_type)
    )
    SELECT
        c.post_id, c.author_id, c.author_pseudonym, c.author_avatar_seed,
        c.author_is_verified, c.author_karma,
        c.tribe_name, c.tribe_slug, c.tribe_id,
        c.category_name, c.post_type, c.content, c.post_mood, c.is_whisper,
        c.location_bucket, c.likes_count, c.comments_count,
        c.created_at, c.deleted_at,
        (
            -- engagement (Reddit-ish): log scale on combined signal
            LOG(GREATEST(c.likes_count + c.comments_count, 1))
            -- recency: same axis as the hot view so scores are comparable
            + _venttly_age_decay(c.created_at)
            -- tribe affinity: large kick when the post is in a joined tribe
            + CASE WHEN c.tribe_id IN (SELECT tribe_id FROM my_tribes)
                   THEN 1.5 ELSE 0 END
            -- category affinity: gentler nudge based on like history
            + CASE WHEN c.category_name IN (SELECT category_name FROM my_categories)
                   THEN 0.8 ELSE 0 END
            -- local affinity: matches user's home city
            + CASE WHEN v_bucket IS NOT NULL AND c.location_bucket = v_bucket
                   THEN 0.6 ELSE 0 END
            -- unanswered boost: nudge fresh threads that have <3 replies
            + CASE WHEN c.comments_count < 3
                       AND c.created_at > NOW() - INTERVAL '12 hours'
                   THEN 0.4 ELSE 0 END
            -- self-author bias: small negative so the feed doesn't echo
            + CASE WHEN c.author_id = v_uid THEN -0.5 ELSE 0 END
        )::DOUBLE PRECISION AS personal_score
      FROM candidates c
     ORDER BY personal_score DESC, c.created_at DESC
     LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.personal_feed(INT, TEXT, TEXT) TO authenticated;

-- =====================================================================
-- 0015 done.
-- =====================================================================
