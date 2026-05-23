-- ============================================================================
-- Venttly | Migration 0010 — Engagement bundle (Phase 13)
--
-- Powers the next batch of mobile features per the founder's extended spec:
--   • Polls (schema already exists in 0001 — wired in app code this round)
--   • Karma / Vibe Points — a simple anonymous reputation score
--   • Tribe avatars + banners
--
-- Karma is incremented for the *author* of a post when someone likes it, and
-- decremented when the like is removed. We use a trigger so the source of
-- truth lives next to the data and survives backend rewrites.
-- ============================================================================

-- 1) Karma column ----------------------------------------------------------
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS karma_points INT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_users_karma
    ON public.users(karma_points DESC);

-- Trigger functions: bump / un-bump the post author's karma when a like is
-- inserted / deleted. We don't touch karma when the author likes their own
-- post — that would let users self-inflate.
CREATE OR REPLACE FUNCTION public.trg_inc_author_karma()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    author UUID;
BEGIN
    SELECT author_id INTO author FROM public.posts
     WHERE post_id = NEW.post_id;
    IF author IS NOT NULL AND author <> NEW.user_id THEN
        UPDATE public.users
           SET karma_points = karma_points + 1
         WHERE user_id = author;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.trg_dec_author_karma()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    author UUID;
BEGIN
    SELECT author_id INTO author FROM public.posts
     WHERE post_id = OLD.post_id;
    IF author IS NOT NULL AND author <> OLD.user_id THEN
        UPDATE public.users
           SET karma_points = GREATEST(karma_points - 1, 0)
         WHERE user_id = author;
    END IF;
    RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS post_likes_karma_inc ON public.post_likes;
DROP TRIGGER IF EXISTS post_likes_karma_dec ON public.post_likes;
CREATE TRIGGER post_likes_karma_inc
    AFTER INSERT ON public.post_likes
    FOR EACH ROW EXECUTE FUNCTION public.trg_inc_author_karma();
CREATE TRIGGER post_likes_karma_dec
    AFTER DELETE ON public.post_likes
    FOR EACH ROW EXECUTE FUNCTION public.trg_dec_author_karma();

-- Backfill: count existing likes so karma reflects historical engagement.
WITH counts AS (
    SELECT p.author_id, COUNT(*) AS n
      FROM public.post_likes pl
      JOIN public.posts p ON p.post_id = pl.post_id
     WHERE p.author_id <> pl.user_id
     GROUP BY p.author_id
)
UPDATE public.users u
   SET karma_points = COALESCE(c.n, 0)
  FROM counts c
 WHERE c.author_id = u.user_id;

-- 2) Tribe imagery --------------------------------------------------------
ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS avatar_url TEXT,
    ADD COLUMN IF NOT EXISTS banner_url TEXT;

-- Refresh the tribe_directory view so the client gets these in one fetch.
DROP VIEW IF EXISTS public.tribe_directory;
CREATE VIEW public.tribe_directory WITH (security_invoker = true) AS
SELECT
    t.tribe_id, t.name, t.slug, t.description, t.category,
    t.member_count, t.is_private, t.created_at, t.rules,
    t.avatar_url, t.banner_url,
    t.is_featured, t.is_suspended,
    t.keeper_id,
    u.anonymous_pseudonym AS keeper_pseudonym,
    u.avatar_seed         AS keeper_avatar_seed,
    u.is_verified         AS keeper_is_verified,
    u.karma_points        AS keeper_karma
FROM public.tribes t
LEFT JOIN public.users u ON u.user_id = t.keeper_id;
GRANT SELECT ON public.tribe_directory TO anon, authenticated;

-- 3) feed_posts view — surface author karma so the post-card author chip
--    can show "@user · 1.2K karma" without an extra round trip.
DROP VIEW IF EXISTS public.feed_posts;
CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(u.avatar_seed, 'default-orb')               AS author_avatar_seed,
    COALESCE(u.is_verified, false)                       AS author_is_verified,
    COALESCE(u.karma_points, 0)                          AS author_karma,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users  u ON u.user_id  = p.author_id
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
