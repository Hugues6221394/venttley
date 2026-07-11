-- 0087_media_safety.sql
-- Media safety: BLOCK nudity/NSFW so users never see it, and VEIL sensitive
-- (borderline but allowed) media behind a "tap to reveal" warning.
--
-- Flow: on image upload the client sets media_status='pending' and fires the
-- `media-scan` edge function, which classifies the image and writes the verdict
-- back via the service role:
--   * blocked   → nudity/explicit → a trigger sets deleted_at, so the post is
--                 never served by feed_posts (which already filters deleted).
--   * sensitive → borderline → stays visible but the client shows a warning veil.
--   * clean     → shown normally.
--
-- Safe-by-default: unscanned image posts sit at 'pending', which the client
-- veils — so nudity is never shown before it's cleared. CSAM hash-matching +
-- NCMEC reporting is a further step the edge function is structured for but
-- which needs a vendor (PhotoDNA / Thorn) — see the edge function comments.

-- =========================================================================
-- 1) Status columns on the two media-bearing tables
-- =========================================================================
DO $$ BEGIN
    ALTER TABLE public.posts
        ADD COLUMN IF NOT EXISTS media_status TEXT NOT NULL DEFAULT 'clean'
            CHECK (media_status IN ('clean','pending','sensitive','blocked')),
        ADD COLUMN IF NOT EXISTS media_labels JSONB;
    ALTER TABLE public.whispers
        ADD COLUMN IF NOT EXISTS media_status TEXT NOT NULL DEFAULT 'clean'
            CHECK (media_status IN ('clean','pending','sensitive','blocked')),
        ADD COLUMN IF NOT EXISTS media_labels JSONB;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_posts_media_pending
    ON public.posts (media_status) WHERE media_status = 'pending';

-- =========================================================================
-- 2) Blocked media is auto-hidden (reuses the existing deleted_at filter so
--    no feed change is needed to make it disappear).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.enforce_blocked_media()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.media_status = 'blocked' AND NEW.deleted_at IS NULL THEN
        NEW.deleted_at := now();
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS posts_enforce_blocked_media ON public.posts;
CREATE TRIGGER posts_enforce_blocked_media
    BEFORE INSERT OR UPDATE OF media_status ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.enforce_blocked_media();

DROP TRIGGER IF EXISTS whispers_enforce_blocked_media ON public.whispers;
CREATE TRIGGER whispers_enforce_blocked_media
    BEFORE INSERT OR UPDATE OF media_status ON public.whispers
    FOR EACH ROW EXECUTE FUNCTION public.enforce_blocked_media();

-- =========================================================================
-- 3) Surface media_status in the feed so the client can veil sensitive posts.
--    CREATE OR REPLACE keeps every existing column (same order) and appends
--    the new one; feed_hot (SELECT f.*) inherits it automatically.
-- =========================================================================
CREATE OR REPLACE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || pr.pseudonym, '@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS author_avatar_seed,
    CASE WHEN p.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END AS author_profile_photo_url,
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
    p.keeper_pick_at,
    p.media_status
FROM public.posts p
LEFT JOIN public.users    u  ON u.user_id     = p.author_id
LEFT JOIN public.personas pr ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
LEFT JOIN public.tribes   t  ON t.tribe_id    = p.tribe_id;

-- =========================================================================
-- 4) Staff override — manually reclassify media (audited). Also used to
--    un-block a false positive.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_set_media_status(
    p_kind   TEXT,           -- 'post' | 'whisper'
    p_id     UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF p_status NOT IN ('clean','pending','sensitive','blocked') THEN
        RAISE EXCEPTION 'invalid status %', p_status;
    END IF;

    IF p_kind = 'post' THEN
        UPDATE posts SET media_status = p_status,
               deleted_at = CASE WHEN p_status = 'clean' THEN NULL ELSE deleted_at END
         WHERE post_id = p_id;
    ELSIF p_kind = 'whisper' THEN
        UPDATE whispers SET media_status = p_status,
               deleted_at = CASE WHEN p_status = 'clean' THEN NULL ELSE deleted_at END
         WHERE whisper_id = p_id;
    ELSE
        RAISE EXCEPTION 'invalid kind %', p_kind;
    END IF;

    PERFORM admin_log('media.set_status', p_kind, p_id, NULL,
                      NULL, jsonb_build_object('media_status', p_status),
                      p_reason, '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.admin_set_media_status(TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_media_status(TEXT, UUID, TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
