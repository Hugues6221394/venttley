-- 0051_comment_moderation_and_keeper_picks.sql
--
-- Phase 2 of the Emotional Communities redesign. Three small but
-- load-bearing additions that turn a Space from "a wall of vents"
-- into a managed conversation:
--
--   1. pinned_at on posts_comments
--        A vent OWNER can pin one comment to the top of their thread.
--        Often the most helpful reply, an author note, or a content
--        warning. Pinned comments render above the chronological
--        thread.
--
--   2. locked_at on posts
--        A vent OWNER can lock further comments. The thread stays
--        readable but new replies are blocked. Used when a thread
--        gets ugly or the OP doesn't want more input.
--
--   3. is_keeper_pick + keeper_pick_at on posts
--        The Tribe keeper marks a vent as Keeper's Pick. Surfaces
--        a chip on the card and powers the "Keeper Picks" smart
--        sort inside a Space.
--
-- All mutations go through SECURITY DEFINER RPCs so authority
-- (vent owner vs keeper) is enforced once, server-side.

-- =====================================================================
-- 1. posts_comments: pinned_at
-- =====================================================================

ALTER TABLE public.posts_comments
    ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS posts_comments_pinned_idx
    ON public.posts_comments (post_id, pinned_at DESC)
    WHERE pinned_at IS NOT NULL;

-- =====================================================================
-- 2. posts: locked_at + is_keeper_pick
-- =====================================================================

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS locked_at        TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS is_keeper_pick   BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS keeper_pick_at   TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS posts_keeper_pick_idx
    ON public.posts (space_id, keeper_pick_at DESC)
    WHERE is_keeper_pick = TRUE;

-- =====================================================================
-- 3. RPCs — vent OWNER controls
-- =====================================================================

-- Pin a single comment under one of your own vents. Only one
-- comment may be pinned at a time; pinning a new one clears the
-- previous pin in the same vent.
CREATE OR REPLACE FUNCTION public.pin_comment(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_post_id UUID;
    v_owner   UUID;
BEGIN
    SELECT c.post_id, p.author_id
      INTO v_post_id, v_owner
      FROM posts_comments c
      JOIN posts p ON p.post_id = c.post_id
     WHERE c.comment_id = p_comment_id;

    IF v_post_id IS NULL THEN
        RAISE EXCEPTION 'comment_not_found';
    END IF;
    IF v_owner IS NULL OR v_owner <> auth.uid() THEN
        RAISE EXCEPTION 'not_post_owner';
    END IF;

    -- Clear any existing pin on this post.
    UPDATE posts_comments
       SET pinned_at = NULL
     WHERE post_id = v_post_id AND pinned_at IS NOT NULL;

    UPDATE posts_comments
       SET pinned_at = now()
     WHERE comment_id = p_comment_id;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.pin_comment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pin_comment(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.unpin_comment(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner UUID;
BEGIN
    SELECT p.author_id INTO v_owner
      FROM posts_comments c
      JOIN posts p ON p.post_id = c.post_id
     WHERE c.comment_id = p_comment_id;
    IF v_owner IS NULL OR v_owner <> auth.uid() THEN
        RAISE EXCEPTION 'not_post_owner';
    END IF;
    UPDATE posts_comments
       SET pinned_at = NULL
     WHERE comment_id = p_comment_id;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.unpin_comment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unpin_comment(UUID) TO authenticated;

-- Lock / unlock comments on your own vent.
CREATE OR REPLACE FUNCTION public.set_post_comments_lock(
    p_post_id UUID,
    p_locked  BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner UUID;
BEGIN
    SELECT author_id INTO v_owner FROM posts WHERE post_id = p_post_id;
    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'post_not_found';
    END IF;
    IF v_owner <> auth.uid() THEN
        RAISE EXCEPTION 'not_post_owner';
    END IF;
    UPDATE posts
       SET locked_at = CASE WHEN p_locked THEN now() ELSE NULL END
     WHERE post_id = p_post_id;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.set_post_comments_lock(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_post_comments_lock(UUID, BOOLEAN) TO authenticated;

-- Block new comments on locked vents at the data-layer too — defence
-- in depth so a stale client can't bypass the UI guard.
CREATE OR REPLACE FUNCTION public.trg_reject_locked_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_locked TIMESTAMPTZ;
BEGIN
    SELECT locked_at INTO v_locked FROM posts WHERE post_id = NEW.post_id;
    IF v_locked IS NOT NULL THEN
        RAISE EXCEPTION 'post_comments_locked';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_comments_lock_guard ON public.posts_comments;
CREATE TRIGGER posts_comments_lock_guard
    BEFORE INSERT ON public.posts_comments
    FOR EACH ROW EXECUTE FUNCTION public.trg_reject_locked_comments();

-- =====================================================================
-- 4. RPC — KEEPER control: Keeper's Pick
-- =====================================================================

CREATE OR REPLACE FUNCTION public.toggle_keeper_pick(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
    v_curr   BOOLEAN;
BEGIN
    SELECT t.keeper_id, p.is_keeper_pick
      INTO v_keeper, v_curr
      FROM posts p
      JOIN tribes t ON t.tribe_id = p.tribe_id
     WHERE p.post_id = p_post_id;

    IF v_keeper IS NULL THEN
        RAISE EXCEPTION 'post_or_tribe_not_found';
    END IF;
    IF v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'not_keeper';
    END IF;

    UPDATE posts SET
        is_keeper_pick = NOT COALESCE(v_curr, FALSE),
        keeper_pick_at = CASE WHEN NOT COALESCE(v_curr, FALSE) THEN now() ELSE NULL END
      WHERE post_id = p_post_id;
    RETURN NOT COALESCE(v_curr, FALSE);
END;
$$;

REVOKE ALL ON FUNCTION public.toggle_keeper_pick(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_keeper_pick(UUID) TO authenticated;

-- =====================================================================
-- 5. Rebuild feed_posts + feed_hot + fetch_comment_tree to expose
--    the new columns so the client can render them without extra
--    round-trips.
-- =====================================================================

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
    p.keeper_pick_at
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

-- Surface pinned_at in the comment tree so the UI can hoist pinned
-- comments to the top regardless of created_at ordering.
DROP FUNCTION IF EXISTS public.fetch_comment_tree(UUID);
CREATE OR REPLACE FUNCTION public.fetch_comment_tree(p_post_id UUID)
RETURNS TABLE (
    comment_id   UUID,
    parent_id    UUID,
    author_id    UUID,
    content      TEXT,
    path         ltree,
    depth        INT,
    likes_count  INT,
    liked_by_me  BOOLEAN,
    created_at   TIMESTAMPTZ,
    edited_at    TIMESTAMPTZ,
    deleted_at   TIMESTAMPTZ,
    pinned_at    TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.comment_id,
           c.parent_id,
           c.author_id,
           c.content,
           c.path,
           (nlevel(c.path) - 1) AS depth,
           c.likes_count,
           EXISTS (
               SELECT 1 FROM comment_likes l
                WHERE l.comment_id = c.comment_id
                  AND l.user_id    = auth.uid()
           ) AS liked_by_me,
           c.created_at,
           c.edited_at,
           c.deleted_at,
           c.pinned_at
    FROM   posts_comments c
    WHERE  c.post_id = p_post_id
    ORDER BY c.path ASC, c.created_at ASC;
$$;

NOTIFY pgrst, 'reload schema';
