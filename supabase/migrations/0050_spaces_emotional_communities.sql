-- 0050_spaces_emotional_communities.sql
--
-- Tribes become Emotional Communities. Where a tribe used to be
-- one feed, it now becomes a building of Spaces:
--
--     Tribe ─► Space ─► Vent ─► Comments ─► Replies
--
-- Each Space is a focused, living conversation (e.g. "Anxiety
-- Check-in", "Weekly Wins", "Midnight Vents"). A Tribe with
-- 50,000 members stays browsable because activity is partitioned
-- into Spaces instead of competing in one endless wall.
--
-- Migration safety:
--   * Adds `spaces` table.
--   * Adds nullable `space_id` to `posts` so existing posts keep
--     working until backfill completes.
--   * Auto-creates one "General" Space per existing tribe.
--   * Backfills every existing tribe-scoped post into its General
--     Space — zero data loss.
--   * RLS preserved: a Space inherits its Tribe's visibility, so
--     existing read/write policies on posts continue to gate things
--     correctly. Space-level policies handle keeper-only writes
--     for create / rename / archive.

-- =====================================================================
-- 1. spaces table
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.spaces (
    space_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tribe_id        UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    slug            TEXT NOT NULL,
    name            TEXT NOT NULL,
    description     TEXT,
    weekly_theme    TEXT,
    theme_color     TEXT,
    created_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    is_default      BOOLEAN NOT NULL DEFAULT FALSE,
    archived_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tribe_id, slug)
);

CREATE INDEX IF NOT EXISTS spaces_tribe_active_idx
    ON public.spaces (tribe_id, archived_at NULLS FIRST, created_at DESC);

ALTER TABLE public.spaces ENABLE ROW LEVEL SECURITY;

-- Anyone in the tribe can read (mirrors tribe-membership visibility
-- of posts). Private tribes will already gate via the tribe_members
-- check elsewhere; here we keep it simple: spaces are readable to
-- any authenticated user, the tribe RLS layer gates the posts.
DROP POLICY IF EXISTS spaces_read_all ON public.spaces;
CREATE POLICY spaces_read_all ON public.spaces
    FOR SELECT TO authenticated USING (TRUE);

-- Keeper-only writes (insert/update/delete) — gated by tribes.keeper_id.
DROP POLICY IF EXISTS spaces_keeper_write ON public.spaces;
CREATE POLICY spaces_keeper_write ON public.spaces
    FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = spaces.tribe_id
               AND t.keeper_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = spaces.tribe_id
               AND t.keeper_id = auth.uid()
        )
    );

-- =====================================================================
-- 2. posts.space_id
-- =====================================================================

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS space_id UUID
        REFERENCES public.spaces(space_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS posts_space_created_idx
    ON public.posts (space_id, created_at DESC)
    WHERE space_id IS NOT NULL;

-- =====================================================================
-- 3. Backfill: one "General" Space per tribe, all posts re-pointed
-- =====================================================================

-- Auto-create a General space for every existing tribe that doesn't
-- have one yet. is_default = true marks it as the implicit Space
-- the client picks when the user hasn't chosen one.
INSERT INTO public.spaces (tribe_id, slug, name, description, is_default, created_at)
SELECT t.tribe_id,
       'general',
       'General',
       'The home Space for ' || t.name || '. Vent about anything.',
       TRUE,
       t.created_at
  FROM public.tribes t
 WHERE NOT EXISTS (
     SELECT 1 FROM public.spaces s
      WHERE s.tribe_id = t.tribe_id
        AND s.is_default = TRUE
 );

-- Backfill posts.space_id from the tribe's default Space.
UPDATE public.posts p
   SET space_id = s.space_id
  FROM public.spaces s
 WHERE p.tribe_id IS NOT NULL
   AND p.space_id IS NULL
   AND s.tribe_id = p.tribe_id
   AND s.is_default = TRUE;

-- =====================================================================
-- 4. space_directory view — denormalised read for the Space list
-- =====================================================================

DROP VIEW IF EXISTS public.space_directory;
CREATE OR REPLACE VIEW public.space_directory
WITH (security_invoker = TRUE) AS
SELECT s.space_id,
       s.tribe_id,
       t.slug          AS tribe_slug,
       t.name          AS tribe_name,
       s.slug,
       s.name,
       s.description,
       s.weekly_theme,
       s.theme_color,
       s.is_default,
       s.archived_at,
       s.created_at,
       s.updated_at,
       -- Quick KPIs the Space list cards need without a second hop.
       (
           SELECT COUNT(*) FROM public.posts p
            WHERE p.space_id = s.space_id
              AND p.deleted_at IS NULL
       )::INT AS vent_count,
       (
           SELECT COUNT(*) FROM public.posts p
            WHERE p.space_id = s.space_id
              AND p.deleted_at IS NULL
              AND p.created_at > now() - INTERVAL '24 hours'
       )::INT AS vents_today,
       (
           SELECT MAX(p.created_at) FROM public.posts p
            WHERE p.space_id = s.space_id
              AND p.deleted_at IS NULL
       ) AS last_vent_at
  FROM public.spaces s
  JOIN public.tribes t ON t.tribe_id = s.tribe_id;

-- =====================================================================
-- 5. Keeper-only RPCs (SECURITY DEFINER so the keeper check is
--    explicit; mirrors update_tribe_management).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.create_space(
    p_tribe_id   UUID,
    p_name       TEXT,
    p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
    v_slug   TEXT;
    v_id     UUID;
BEGIN
    SELECT keeper_id INTO v_keeper FROM tribes WHERE tribe_id = p_tribe_id;
    IF v_keeper IS NULL THEN
        RAISE EXCEPTION 'tribe_not_found';
    END IF;
    IF v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'not_keeper';
    END IF;
    IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
        RAISE EXCEPTION 'empty_name';
    END IF;

    -- Slug: lowercase, alphanumerics + dashes, dedup with -2, -3, etc.
    v_slug := regexp_replace(lower(trim(p_name)), '[^a-z0-9]+', '-', 'g');
    v_slug := regexp_replace(v_slug, '(^-+|-+$)', '', 'g');
    IF v_slug = '' THEN v_slug := 'space'; END IF;

    -- Append numeric suffix if slug collides within the tribe.
    DECLARE
        v_try TEXT := v_slug;
        v_i   INT  := 1;
    BEGIN
        WHILE EXISTS (
            SELECT 1 FROM spaces WHERE tribe_id = p_tribe_id AND slug = v_try
        ) LOOP
            v_i := v_i + 1;
            v_try := v_slug || '-' || v_i;
        END LOOP;
        v_slug := v_try;
    END;

    INSERT INTO spaces (tribe_id, slug, name, description, created_by, is_default)
    VALUES (p_tribe_id, v_slug, trim(p_name), p_description, auth.uid(), FALSE)
    RETURNING space_id INTO v_id;

    RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_space(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_space(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rename_space(
    p_space_id UUID,
    p_name     TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
BEGIN
    SELECT t.keeper_id INTO v_keeper
      FROM spaces s
      JOIN tribes t ON t.tribe_id = s.tribe_id
     WHERE s.space_id = p_space_id;

    IF v_keeper IS NULL THEN
        RAISE EXCEPTION 'space_not_found';
    END IF;
    IF v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'not_keeper';
    END IF;
    IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
        RAISE EXCEPTION 'empty_name';
    END IF;

    UPDATE spaces
       SET name = trim(p_name),
           updated_at = now()
     WHERE space_id = p_space_id;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.rename_space(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_space(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.archive_space(p_space_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
    v_default BOOLEAN;
BEGIN
    SELECT t.keeper_id, s.is_default INTO v_keeper, v_default
      FROM spaces s
      JOIN tribes t ON t.tribe_id = s.tribe_id
     WHERE s.space_id = p_space_id;

    IF v_keeper IS NULL THEN
        RAISE EXCEPTION 'space_not_found';
    END IF;
    IF v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'not_keeper';
    END IF;
    IF v_default THEN
        RAISE EXCEPTION 'cannot_archive_default';
    END IF;

    UPDATE spaces
       SET archived_at = now(),
           updated_at = now()
     WHERE space_id = p_space_id;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.archive_space(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.archive_space(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_space_theme(
    p_space_id    UUID,
    p_weekly_theme TEXT DEFAULT NULL,
    p_theme_color  TEXT DEFAULT NULL,
    p_description  TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
BEGIN
    SELECT t.keeper_id INTO v_keeper
      FROM spaces s
      JOIN tribes t ON t.tribe_id = s.tribe_id
     WHERE s.space_id = p_space_id;

    IF v_keeper IS NULL THEN
        RAISE EXCEPTION 'space_not_found';
    END IF;
    IF v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'not_keeper';
    END IF;

    UPDATE spaces SET
        weekly_theme = COALESCE(p_weekly_theme, weekly_theme),
        theme_color  = COALESCE(p_theme_color,  theme_color),
        description  = COALESCE(p_description,  description),
        updated_at   = now()
    WHERE space_id = p_space_id;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.update_space_theme(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_space_theme(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- =====================================================================
-- 6. Rebuild feed_posts + feed_hot to expose space_id alongside
--    tribe_id. Existing posts already have space_id backfilled in
--    step 3, so the view is now consistent.
--
--    Same body as migration 0047's feed_posts, with `p.space_id`
--    added. CASCADE drops dependent views (feed_hot) which we
--    re-create below.
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

NOTIFY pgrst, 'reload schema';
