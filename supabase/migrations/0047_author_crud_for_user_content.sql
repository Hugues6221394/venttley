-- 0047_author_crud_for_user_content.sql
--
-- Full CRUD for user-generated content: every surface where a user
-- creates something now has an edit + delete RPC scoped to the author.
--
-- Affected tables (all soft-delete via deleted_at, edit timestamp via
-- edited_at — adding columns where missing):
--   * posts                    (vents + stories)
--   * posts_comments
--   * whispers                 (already had deleted_at)
--   * tribe_messages           (already had both columns)
--
-- chat_messages already shipped this in migration 0043. The pattern
-- here is identical: SECURITY DEFINER + ownership check + bounded
-- edit window so people can't rewrite history days later.

-- =========================================================================
-- 1) Add missing edited_at columns
-- =========================================================================
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;
ALTER TABLE public.posts_comments
    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;
ALTER TABLE public.whispers
    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

-- Surface the new column in feed_posts so the client knows when a
-- vent was edited (post detail screen renders "edited" footer).
-- The simplest add-without-replacing approach is a CASCADE drop+create;
-- the view shape is identical to 0038 + the new edited_at column.
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
    p.edited_at,
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

-- Re-create personal_feed (same shape + edited_at). Re-using the body
-- from 0038 keeps the ranking math intact.
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
    edited_at                TIMESTAMPTZ,
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
    IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
    SELECT LOWER(home_city) INTO v_bucket FROM users WHERE user_id = v_uid;
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
        SELECT f.*, u.created_at AS author_created_at
          FROM feed_posts f
          JOIN users u ON u.user_id = f.author_id
         WHERE f.deleted_at IS NULL
           AND (f.is_whisper = FALSE OR f.created_at > v_cutoff_w)
           AND u.created_at < v_cutoff_a
           AND NOT EXISTS (SELECT 1 FROM my_blocks b WHERE b.blocked_id = f.author_id)
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
        c.crisis_level, c.created_at, c.edited_at, c.deleted_at,
        (
            LOG(GREATEST(c.likes_count + c.comments_count, 1))
            + _venttly_age_decay(c.created_at)
            + CASE WHEN c.tribe_id IN (SELECT tribe_id FROM my_tribes)  THEN 1.5 ELSE 0 END
            + CASE WHEN c.category_name IN (SELECT category_name FROM my_categories) THEN 0.8 ELSE 0 END
            + CASE WHEN v_bucket IS NOT NULL AND c.location_bucket = v_bucket THEN 0.6 ELSE 0 END
            - CASE WHEN c.comments_count > c.likes_count * 4 THEN 0.8 ELSE 0 END
        )::DOUBLE PRECISION AS personal_score
      FROM candidates c
     ORDER BY personal_score DESC, c.created_at DESC
     LIMIT GREATEST(1, LEAST(p_limit, 100));
END $$;
REVOKE ALL ON FUNCTION public.personal_feed(INT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.personal_feed(INT, TEXT, TEXT) TO authenticated;

-- =========================================================================
-- 2) edit_post / delete_post  (15-min edit window)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.edit_post(
    p_post_id UUID,
    p_content TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
    v_created TIMESTAMPTZ;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
        RAISE EXCEPTION 'empty edit not allowed';
    END IF;
    IF length(p_content) > 1000 THEN
        RAISE EXCEPTION 'content too long';
    END IF;

    SELECT author_id = v_me, created_at
      INTO v_owns, v_created
      FROM posts
     WHERE post_id = p_post_id AND deleted_at IS NULL;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'post not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your post'; END IF;
    IF now() - v_created > INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;

    UPDATE posts
       SET content   = p_content,
           edited_at = now()
     WHERE post_id = p_post_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.edit_post(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_post(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_post(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT author_id = v_me INTO v_owns FROM posts WHERE post_id = p_post_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'post not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your post'; END IF;
    UPDATE posts SET deleted_at = now() WHERE post_id = p_post_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.delete_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_post(UUID) TO authenticated;

-- =========================================================================
-- 3) edit_comment / delete_comment  (5-min edit window)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.edit_comment(
    p_comment_id UUID,
    p_content    TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
    v_created TIMESTAMPTZ;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
        RAISE EXCEPTION 'empty edit not allowed';
    END IF;
    IF length(p_content) > 1000 THEN
        RAISE EXCEPTION 'comment too long';
    END IF;
    SELECT author_id = v_me, created_at
      INTO v_owns, v_created
      FROM posts_comments
     WHERE comment_id = p_comment_id AND deleted_at IS NULL;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'comment not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your comment'; END IF;
    IF now() - v_created > INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;
    UPDATE posts_comments
       SET content   = p_content,
           edited_at = now()
     WHERE comment_id = p_comment_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.edit_comment(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_comment(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_comment(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT author_id = v_me INTO v_owns
      FROM posts_comments WHERE comment_id = p_comment_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'comment not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your comment'; END IF;
    UPDATE posts_comments SET deleted_at = now()
     WHERE comment_id = p_comment_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.delete_comment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_comment(UUID) TO authenticated;

-- =========================================================================
-- 4) edit_whisper / delete_whisper  (15-min metadata edit)
--    Note: edits only the title + description. The recorded audio is
--    immutable — if a user wants to re-record they must delete + repost.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.edit_whisper(
    p_whisper_id  UUID,
    p_title       TEXT,
    p_description TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
    v_created TIMESTAMPTZ;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_title IS NOT NULL AND length(p_title) > 80 THEN
        RAISE EXCEPTION 'title too long';
    END IF;
    IF p_description IS NOT NULL AND length(p_description) > 500 THEN
        RAISE EXCEPTION 'description too long';
    END IF;
    SELECT author_id = v_me, created_at
      INTO v_owns, v_created
      FROM whispers
     WHERE whisper_id = p_whisper_id AND deleted_at IS NULL;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'whisper not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your whisper'; END IF;
    IF now() - v_created > INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;
    UPDATE whispers
       SET title       = p_title,
           description = p_description,
           edited_at   = now()
     WHERE whisper_id = p_whisper_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.edit_whisper(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_whisper(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_whisper(p_whisper_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT author_id = v_me INTO v_owns
      FROM whispers WHERE whisper_id = p_whisper_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'whisper not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your whisper'; END IF;
    UPDATE whispers SET deleted_at = now()
     WHERE whisper_id = p_whisper_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.delete_whisper(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_whisper(UUID) TO authenticated;

-- =========================================================================
-- 5) edit_tribe_message / delete_tribe_message  (5-min edit window)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.edit_tribe_message(
    p_message_id UUID,
    p_content    TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
    v_created TIMESTAMPTZ;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
        RAISE EXCEPTION 'empty edit not allowed';
    END IF;
    IF length(p_content) > 2000 THEN
        RAISE EXCEPTION 'message too long';
    END IF;
    SELECT sender_id = v_me, created_at
      INTO v_owns, v_created
      FROM tribe_messages
     WHERE message_id = p_message_id AND deleted_at IS NULL;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;
    IF now() - v_created > INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;
    UPDATE tribe_messages
       SET content   = p_content,
           edited_at = now()
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.edit_tribe_message(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_tribe_message(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_tribe_message(p_message_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT sender_id = v_me INTO v_owns
      FROM tribe_messages WHERE message_id = p_message_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;
    UPDATE tribe_messages SET deleted_at = now()
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.delete_tribe_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_tribe_message(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
