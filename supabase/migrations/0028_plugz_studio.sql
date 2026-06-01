-- 0028_plugz_studio.sql
--
-- Plugz Creator Studio backend (social-spec §13). Layers four new
-- capabilities on top of the existing tribe management:
--
--   1. Pinned posts — a tribe can have any number of pinned posts.
--      The keeper / mods curate the top of the tribe feed.
--   2. Scheduled prompts — keepers compose "Question of the Day"-style
--      prompts that go live at a chosen time. Reuses plug_prompts.
--   3. Branding — welcome_message + theme_color land on tribes so the
--      public tribe page can read like the keeper's voice.
--   4. Spotlight member — a single user the keeper wants to celebrate
--      this week. Stored on tribes for simplicity.
--
-- All writes route through SECURITY DEFINER RPCs scoped to roles
-- 'keeper' and 'mod' on the target tribe. Reads are public.

-- =========================================================================
-- 1) Tribe columns
-- =========================================================================
ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS welcome_message TEXT,
    ADD COLUMN IF NOT EXISTS theme_color     TEXT,
    ADD COLUMN IF NOT EXISTS spotlight_user_id UUID
        REFERENCES public.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS spotlight_note  TEXT,
    ADD COLUMN IF NOT EXISTS spotlight_set_at TIMESTAMPTZ;

-- Hex color sanity check (#RRGGBB). NULL means "use brand default".
ALTER TABLE public.tribes
    DROP CONSTRAINT IF EXISTS tribes_theme_color_chk;
ALTER TABLE public.tribes
    ADD  CONSTRAINT tribes_theme_color_chk
    CHECK (theme_color IS NULL OR theme_color ~* '^#[0-9a-f]{6}$');

-- =========================================================================
-- 2) Pinned posts
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tribe_pinned_posts (
    tribe_id  UUID         NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    post_id   UUID         NOT NULL REFERENCES public.posts(post_id)   ON DELETE CASCADE,
    pinned_by UUID         REFERENCES public.users(user_id) ON DELETE SET NULL,
    pinned_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    sort_idx  INT          NOT NULL DEFAULT 0,
    PRIMARY KEY (tribe_id, post_id)
);

CREATE INDEX IF NOT EXISTS tribe_pinned_posts_tribe_idx
    ON public.tribe_pinned_posts (tribe_id, sort_idx, pinned_at DESC);

ALTER TABLE public.tribe_pinned_posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tribe_pinned_posts public read" ON public.tribe_pinned_posts;
CREATE POLICY "tribe_pinned_posts public read"
    ON public.tribe_pinned_posts FOR SELECT USING (true);

GRANT SELECT ON public.tribe_pinned_posts TO authenticated, anon;

-- =========================================================================
-- 3) plug_prompts extension — tribe-scoped + schedulable
-- =========================================================================
ALTER TABLE public.plug_prompts
    ADD COLUMN IF NOT EXISTS tribe_id      UUID
        REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS scheduled_for TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS published_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS plug_prompts_tribe_schedule_idx
    ON public.plug_prompts (tribe_id, scheduled_for)
    WHERE tribe_id IS NOT NULL;

-- A prompt is "live" when scheduled_for has passed and is_active is true.
-- Keepers can edit/cancel before then. Public reads are unchanged.

-- =========================================================================
-- 4) Helper: is_tribe_keeper_or_mod
-- =========================================================================
CREATE OR REPLACE FUNCTION public.is_tribe_keeper_or_mod(p_tribe UUID, p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe AND user_id = p_user
           AND role IN ('keeper','mod')
    );
$$;

CREATE OR REPLACE FUNCTION public.is_tribe_keeper(p_tribe UUID, p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe AND user_id = p_user
           AND role = 'keeper'
    );
$$;

-- =========================================================================
-- 5) RPCs
-- =========================================================================

-- Pin a post to the tribe feed.
CREATE OR REPLACE FUNCTION public.tribe_pin_post(
    p_tribe UUID,
    p_post  UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_post_tribe UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT is_tribe_keeper_or_mod(p_tribe, v_me) THEN
        RAISE EXCEPTION 'forbidden: keeper or mod only';
    END IF;
    SELECT tribe_id INTO v_post_tribe FROM posts WHERE post_id = p_post;
    IF v_post_tribe IS NULL OR v_post_tribe <> p_tribe THEN
        RAISE EXCEPTION 'post must belong to the same tribe';
    END IF;
    INSERT INTO tribe_pinned_posts (tribe_id, post_id, pinned_by)
    VALUES (p_tribe, p_post, v_me)
    ON CONFLICT (tribe_id, post_id) DO NOTHING;
END $$;

REVOKE ALL ON FUNCTION public.tribe_pin_post(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_pin_post(UUID,UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.tribe_unpin_post(
    p_tribe UUID,
    p_post  UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT is_tribe_keeper_or_mod(p_tribe, v_me) THEN
        RAISE EXCEPTION 'forbidden: keeper or mod only';
    END IF;
    DELETE FROM tribe_pinned_posts
     WHERE tribe_id = p_tribe AND post_id = p_post;
END $$;

REVOKE ALL ON FUNCTION public.tribe_unpin_post(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_unpin_post(UUID,UUID) TO authenticated;

-- Schedule (or post immediately) a tribe-scoped prompt.
CREATE OR REPLACE FUNCTION public.tribe_schedule_prompt(
    p_tribe         UUID,
    p_prompt_text   TEXT,
    p_scheduled_for TIMESTAMPTZ DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT is_tribe_keeper_or_mod(p_tribe, v_me) THEN
        RAISE EXCEPTION 'forbidden: keeper or mod only';
    END IF;
    IF length(trim(p_prompt_text)) < 4 THEN
        RAISE EXCEPTION 'prompt text too short';
    END IF;

    -- plug_prompts.plug_id is nullable for tribe-scoped prompts. The
    -- keeper isn't necessarily a registered Plug profile; the tribe_id
    -- linkage is enough provenance for our needs.
    INSERT INTO plug_prompts (
        plug_id, prompt_text, tribe_id, scheduled_for,
        is_active, published_at
    ) VALUES (
        NULL, p_prompt_text, p_tribe, p_scheduled_for,
        true,
        CASE WHEN p_scheduled_for IS NULL OR p_scheduled_for <= now()
             THEN COALESCE(p_scheduled_for, now())
             ELSE NULL
        END
    ) RETURNING prompt_id INTO v_id;

    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.tribe_schedule_prompt(UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_schedule_prompt(UUID,TEXT,TIMESTAMPTZ) TO authenticated;

-- Cancel a scheduled prompt (only if it hasn't gone live yet).
CREATE OR REPLACE FUNCTION public.tribe_cancel_prompt(
    p_tribe  UUID,
    p_prompt UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT is_tribe_keeper_or_mod(p_tribe, v_me) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    DELETE FROM plug_prompts
     WHERE prompt_id = p_prompt AND tribe_id = p_tribe
       AND published_at IS NULL;
END $$;

REVOKE ALL ON FUNCTION public.tribe_cancel_prompt(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_cancel_prompt(UUID,UUID) TO authenticated;

-- Set branding (welcome message + theme color). Keeper-only.
CREATE OR REPLACE FUNCTION public.tribe_set_branding(
    p_tribe           UUID,
    p_welcome_message TEXT,
    p_theme_color     TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT is_tribe_keeper(p_tribe, v_me) THEN
        RAISE EXCEPTION 'forbidden: keeper only';
    END IF;
    UPDATE tribes
       SET welcome_message = NULLIF(trim(COALESCE(p_welcome_message, '')), ''),
           theme_color     = NULLIF(trim(COALESCE(p_theme_color, '')), '')
     WHERE tribe_id = p_tribe;
END $$;

REVOKE ALL ON FUNCTION public.tribe_set_branding(UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_set_branding(UUID,TEXT,TEXT) TO authenticated;

-- Spotlight a member.
CREATE OR REPLACE FUNCTION public.tribe_spotlight_member(
    p_tribe UUID,
    p_user  UUID,
    p_note  TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT is_tribe_keeper_or_mod(p_tribe, v_me) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF p_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe AND user_id = p_user
    ) THEN
        RAISE EXCEPTION 'spotlight target must be a tribe member';
    END IF;
    UPDATE tribes
       SET spotlight_user_id = p_user,
           spotlight_note    = NULLIF(trim(COALESCE(p_note, '')), ''),
           spotlight_set_at  = CASE WHEN p_user IS NULL THEN NULL ELSE now() END
     WHERE tribe_id = p_tribe;
END $$;

REVOKE ALL ON FUNCTION public.tribe_spotlight_member(UUID,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_spotlight_member(UUID,UUID,TEXT) TO authenticated;

-- =========================================================================
-- 6) Aggregated read for the studio dashboard
-- =========================================================================
DROP VIEW IF EXISTS public.tribe_studio_stats;
CREATE VIEW public.tribe_studio_stats WITH (security_invoker = true) AS
SELECT
    t.tribe_id,
    t.member_count,
    (SELECT count(*) FROM tribe_members tm
      WHERE tm.tribe_id = t.tribe_id
        AND tm.joined_at > now() - interval '7 days')       AS members_7d,
    (SELECT count(*) FROM tribe_members tm
      WHERE tm.tribe_id = t.tribe_id
        AND tm.joined_at > now() - interval '30 days')      AS members_30d,
    (SELECT count(*) FROM posts p
      WHERE p.tribe_id = t.tribe_id
        AND p.deleted_at IS NULL
        AND p.created_at > now() - interval '24 hours')     AS posts_24h,
    (SELECT count(*) FROM posts p
      WHERE p.tribe_id = t.tribe_id
        AND p.deleted_at IS NULL
        AND p.created_at > now() - interval '7 days')       AS posts_7d,
    (SELECT count(*) FROM posts_comments c
      JOIN posts p ON p.post_id = c.post_id
      WHERE p.tribe_id = t.tribe_id
        AND c.created_at > now() - interval '7 days')       AS comments_7d,
    (SELECT count(DISTINCT p.author_id) FROM posts p
      WHERE p.tribe_id = t.tribe_id
        AND p.created_at > now() - interval '7 days')       AS active_posters_7d,
    (SELECT count(*) FROM tribe_pinned_posts pp
      WHERE pp.tribe_id = t.tribe_id)                       AS pinned_count,
    (SELECT count(*) FROM plug_prompts pr
      WHERE pr.tribe_id = t.tribe_id
        AND pr.scheduled_for IS NOT NULL
        AND pr.published_at IS NULL)                        AS scheduled_prompts,
    (SELECT count(*) FROM reports r
      JOIN posts p ON p.post_id = r.post_id
      WHERE p.tribe_id = t.tribe_id
        AND r.is_resolved = false)                          AS open_reports
FROM tribes t;

GRANT SELECT ON public.tribe_studio_stats TO authenticated, anon;
