-- 0063_tribe_chat_hub.sql
-- WhatsApp-style tribe chat hub: presence, prompt edit/delete, chat settings,
-- tribe avatar RPC, online member roster.

-- =========================================================================
-- 1) Presence on tribe_members
-- =========================================================================
ALTER TABLE public.tribe_members
    ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_tribe_members_last_seen
    ON public.tribe_members (tribe_id, last_seen_at DESC NULLS LAST);

-- =========================================================================
-- 2) Chat settings on tribes (JSONB)
-- =========================================================================
ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS chat_settings JSONB NOT NULL DEFAULT '{
        "members_can_invite": false,
        "slow_mode_seconds": 0,
        "announce_joins": true
    }'::jsonb;

-- =========================================================================
-- 3) Heartbeat — mark member active in this tribe chat
-- =========================================================================
CREATE OR REPLACE FUNCTION public.tribe_chat_heartbeat(p_tribe_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    UPDATE tribe_members
       SET last_seen_at = now()
     WHERE tribe_id = p_tribe_id AND user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_chat_heartbeat(UUID) TO authenticated;

-- =========================================================================
-- 4) Presence count (active in last 5 minutes)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.tribe_chat_presence(p_tribe_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*)::INT
      INTO v_count
      FROM tribe_members tm
     WHERE tm.tribe_id = p_tribe_id
       AND tm.last_seen_at IS NOT NULL
       AND tm.last_seen_at > now() - interval '5 minutes';
    IF COALESCE(v_count, 0) = 0 THEN
        SELECT LEAST(COUNT(*)::INT, 3)
          INTO v_count
          FROM tribe_members tm
         WHERE tm.tribe_id = p_tribe_id;
    END IF;
    RETURN COALESCE(v_count, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_chat_presence(UUID) TO authenticated;

-- =========================================================================
-- 5) Online member roster (for hub avatars row)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.tribe_online_members(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe_id AND user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'not a tribe member';
    END IF;

    RETURN COALESCE((
        SELECT jsonb_agg(row_to_json(x) ORDER BY x.last_seen_at DESC NULLS LAST)
          FROM (
            SELECT
                u.user_id,
                u.anonymous_pseudonym AS pseudonym,
                u.avatar_seed,
                u.profile_photo_url,
                tm.role,
                tm.last_seen_at,
                (tm.last_seen_at IS NOT NULL
                 AND tm.last_seen_at > now() - interval '5 minutes') AS is_online
            FROM tribe_members tm
            JOIN users u ON u.user_id = tm.user_id
            WHERE tm.tribe_id = p_tribe_id
            ORDER BY
                CASE WHEN tm.last_seen_at > now() - interval '5 minutes' THEN 0 ELSE 1 END,
                tm.last_seen_at DESC NULLS LAST
            LIMIT 50
          ) x
    ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_online_members(UUID) TO authenticated;

-- =========================================================================
-- 6) Tribe avatar (keeper / mod)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.tribe_set_avatar(
    p_tribe_id UUID,
    p_avatar_url TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    UPDATE tribes SET avatar_url = p_avatar_url WHERE tribe_id = p_tribe_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_set_avatar(UUID, TEXT) TO authenticated;

-- =========================================================================
-- 7) Chat settings
-- =========================================================================
CREATE OR REPLACE FUNCTION public.tribe_set_chat_settings(
    p_tribe_id UUID,
    p_settings JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    UPDATE tribes
       SET chat_settings = COALESCE(chat_settings, '{}'::jsonb) || p_settings
     WHERE tribe_id = p_tribe_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_set_chat_settings(UUID, JSONB) TO authenticated;

-- =========================================================================
-- 8) Prompt edit + delete (keeper / mod)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.tribe_update_prompt(
    p_tribe_id      UUID,
    p_prompt_id     UUID,
    p_prompt_text   TEXT,
    p_scheduled_for TIMESTAMPTZ DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF length(trim(p_prompt_text)) < 4 THEN
        RAISE EXCEPTION 'prompt too short';
    END IF;
    UPDATE plug_prompts
       SET prompt_text   = trim(p_prompt_text),
           scheduled_for = COALESCE(p_scheduled_for, scheduled_for)
     WHERE prompt_id = p_prompt_id
       AND tribe_id  = p_tribe_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'prompt not found'; END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_update_prompt(UUID, UUID, TEXT, TIMESTAMPTZ) TO authenticated;

CREATE OR REPLACE FUNCTION public.tribe_delete_prompt(
    p_tribe_id  UUID,
    p_prompt_id UUID
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    UPDATE plug_prompts
       SET is_active = false
     WHERE prompt_id = p_prompt_id
       AND tribe_id  = p_tribe_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'prompt not found'; END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_delete_prompt(UUID, UUID) TO authenticated;

-- =========================================================================
-- 9) Extend tribe_directory with chat_settings
-- =========================================================================
-- CREATE OR REPLACE VIEW can only append columns; the older tribe_directory
-- has a different column layout, so replacing in place fails with 42P16
-- ("cannot drop columns from view"). Drop then recreate. Nothing depends on
-- this view (every reference is a redefinition), so CASCADE is a no-op safety.
DROP VIEW IF EXISTS public.tribe_directory CASCADE;
CREATE VIEW public.tribe_directory
WITH (security_invoker = true)
AS
SELECT
    t.tribe_id,
    t.name,
    t.slug,
    t.description,
    t.category,
    t.member_count,
    t.is_private,
    t.created_at,
    t.rules,
    t.avatar_url,
    t.banner_url,
    t.is_featured,
    t.is_suspended,
    t.keeper_id,
    u.anonymous_pseudonym AS keeper_pseudonym,
    u.avatar_seed         AS keeper_avatar_seed,
    u.is_verified         AS keeper_is_verified,
    u.karma_points        AS keeper_karma,
    t.welcome_message,
    t.theme_color,
    t.spotlight_user_id,
    sp.anonymous_pseudonym AS spotlight_pseudonym,
    sp.avatar_seed         AS spotlight_avatar_seed,
    t.spotlight_note,
    t.spotlight_set_at,
    t.chat_settings
FROM public.tribes t
LEFT JOIN public.users u  ON u.user_id  = t.keeper_id
LEFT JOIN public.users sp ON sp.user_id = t.spotlight_user_id;

GRANT SELECT ON public.tribe_directory TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
