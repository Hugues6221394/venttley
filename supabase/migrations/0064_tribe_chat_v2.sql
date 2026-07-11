-- 0064_tribe_chat_v2.sql
-- Chat hub v2: unread, reply, pin, reactions, media feed, wallpaper settings.

-- =========================================================================
-- 1) Schema extensions
-- =========================================================================
ALTER TABLE public.tribe_members
    ADD COLUMN IF NOT EXISTS last_read_at TIMESTAMPTZ;

ALTER TABLE public.tribe_messages
    ADD COLUMN IF NOT EXISTS reply_to_message_id UUID
        REFERENCES public.tribe_messages(message_id) ON DELETE SET NULL;

ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS pinned_message_id UUID
        REFERENCES public.tribe_messages(message_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tribe_messages_reply
    ON public.tribe_messages (reply_to_message_id)
    WHERE reply_to_message_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.tribe_message_hugs (
    message_id UUID NOT NULL REFERENCES public.tribe_messages(message_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id)
);

ALTER TABLE public.tribe_message_hugs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tribe message hugs member read" ON public.tribe_message_hugs;
CREATE POLICY "tribe message hugs member read"
    ON public.tribe_message_hugs FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM tribe_messages m
        JOIN tribe_members tm ON tm.tribe_id = m.tribe_id
         WHERE m.message_id = tribe_message_hugs.message_id
           AND tm.user_id = auth.uid()
      )
    );

DROP POLICY IF EXISTS "tribe message hugs own insert" ON public.tribe_message_hugs;
CREATE POLICY "tribe message hugs own insert"
    ON public.tribe_message_hugs FOR INSERT
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "tribe message hugs own delete" ON public.tribe_message_hugs;
CREATE POLICY "tribe message hugs own delete"
    ON public.tribe_message_hugs FOR DELETE
    USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.tribe_message_hugs TO authenticated;

-- Extend default chat_settings with wallpaper keys
UPDATE public.tribes
   SET chat_settings = COALESCE(chat_settings, '{}'::jsonb) || '{
        "wallpaper_url": null,
        "wallpaper_style": "gradient",
        "members_can_send_media": true
    }'::jsonb
 WHERE chat_settings IS NULL
    OR NOT (chat_settings ? 'wallpaper_style');

-- =========================================================================
-- 2) send_tribe_message — reply support
-- =========================================================================
CREATE OR REPLACE FUNCTION public.send_tribe_message(
    p_tribe_id               UUID,
    p_content                TEXT  DEFAULT NULL,
    p_persona_id             UUID  DEFAULT NULL,
    p_image_url              TEXT  DEFAULT NULL,
    p_image_path             TEXT  DEFAULT NULL,
    p_audio_url              TEXT  DEFAULT NULL,
    p_audio_path             TEXT  DEFAULT NULL,
    p_audio_duration_seconds INT   DEFAULT NULL,
    p_reply_to_message_id    UUID  DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_is_member BOOLEAN;
    v_msg_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe_id AND user_id = v_me
    ) INTO v_is_member;
    IF NOT v_is_member THEN RAISE EXCEPTION 'not a tribe member'; END IF;

    IF p_content IS NULL AND p_image_url IS NULL AND p_audio_url IS NULL THEN
        RAISE EXCEPTION 'message must have content, image, or audio';
    END IF;

    IF p_reply_to_message_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM tribe_messages
             WHERE message_id = p_reply_to_message_id
               AND tribe_id = p_tribe_id
               AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'reply target not found';
        END IF;
    END IF;

    INSERT INTO tribe_messages (
        tribe_id, sender_id, sender_persona_id,
        content, image_url, image_path,
        audio_url, audio_path, audio_duration_seconds,
        reply_to_message_id
    ) VALUES (
        p_tribe_id, v_me, p_persona_id,
        p_content, p_image_url, p_image_path,
        p_audio_url, p_audio_path, p_audio_duration_seconds,
        p_reply_to_message_id
    ) RETURNING message_id INTO v_msg_id;

    UPDATE tribe_members
       SET last_read_at = now()
     WHERE tribe_id = p_tribe_id AND user_id = v_me;

    RETURN v_msg_id;
END $$;

GRANT EXECUTE ON FUNCTION public.send_tribe_message(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, INT, UUID) TO authenticated;

-- =========================================================================
-- 3) Mark read + inbox summaries
-- =========================================================================
CREATE OR REPLACE FUNCTION public.mark_tribe_chat_read(p_tribe_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    UPDATE tribe_members
       SET last_read_at = now()
     WHERE tribe_id = p_tribe_id AND user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_tribe_chat_read(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.tribe_chat_inbox()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
BEGIN
    IF auth.uid() IS NULL THEN RETURN '[]'::jsonb; END IF;

    RETURN COALESCE((
        SELECT jsonb_agg(row_to_json(x) ORDER BY x.last_message_at DESC NULLS LAST)
          FROM (
            SELECT
                t.tribe_id,
                t.name,
                t.slug,
                t.avatar_url,
                (
                    SELECT COUNT(*)::INT
                      FROM tribe_messages m
                     WHERE m.tribe_id = t.tribe_id
                       AND m.deleted_at IS NULL
                       AND m.sender_id IS DISTINCT FROM auth.uid()
                       AND m.created_at > COALESCE(tm.last_read_at, '1970-01-01'::timestamptz)
                ) AS unread_count,
                (
                    SELECT LEFT(COALESCE(m.content, 'Media'), 80)
                      FROM tribe_messages m
                     WHERE m.tribe_id = t.tribe_id
                       AND m.deleted_at IS NULL
                     ORDER BY m.created_at DESC
                     LIMIT 1
                ) AS last_message_preview,
                (
                    SELECT m.created_at
                      FROM tribe_messages m
                     WHERE m.tribe_id = t.tribe_id
                       AND m.deleted_at IS NULL
                     ORDER BY m.created_at DESC
                     LIMIT 1
                ) AS last_message_at
            FROM tribe_members tm
            JOIN tribes t ON t.tribe_id = tm.tribe_id
            WHERE tm.user_id = auth.uid()
          ) x
    ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.tribe_chat_inbox() TO authenticated;

-- =========================================================================
-- 4) Pin / unpin + hug toggle
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pin_tribe_message(
    p_tribe_id UUID,
    p_message_id UUID
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM tribe_messages
         WHERE message_id = p_message_id
           AND tribe_id = p_tribe_id
           AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'message not found';
    END IF;
    UPDATE tribes SET pinned_message_id = p_message_id WHERE tribe_id = p_tribe_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.pin_tribe_message(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.unpin_tribe_message(p_tribe_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    UPDATE tribes SET pinned_message_id = NULL WHERE tribe_id = p_tribe_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unpin_tribe_message(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.toggle_tribe_message_hug(p_message_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_tribe_id UUID;
    v_hugged BOOLEAN;
    v_count INT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT tribe_id INTO v_tribe_id
      FROM tribe_messages
     WHERE message_id = p_message_id AND deleted_at IS NULL;
    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = v_tribe_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'not a tribe member';
    END IF;

    IF EXISTS (
        SELECT 1 FROM tribe_message_hugs
         WHERE message_id = p_message_id AND user_id = v_me
    ) THEN
        DELETE FROM tribe_message_hugs
         WHERE message_id = p_message_id AND user_id = v_me;
        v_hugged := false;
    ELSE
        INSERT INTO tribe_message_hugs (message_id, user_id)
        VALUES (p_message_id, v_me);
        v_hugged := true;
    END IF;

    SELECT COUNT(*)::INT INTO v_count
      FROM tribe_message_hugs WHERE message_id = p_message_id;

    UPDATE tribe_messages SET hugs_count = v_count WHERE message_id = p_message_id;

    RETURN jsonb_build_object('hugged', v_hugged, 'hugs_count', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_tribe_message_hug(UUID) TO authenticated;

-- =========================================================================
-- 5) Feed view — reply + hugged_by_me + is_pinned
-- =========================================================================
-- Column layout changes vs 0041, so replace-in-place fails (42P16). Drop
-- first, matching the pattern 0065/0066 already use for this same view.
DROP VIEW IF EXISTS public.tribe_messages_feed CASCADE;
CREATE VIEW public.tribe_messages_feed
WITH (security_invoker = true) AS
SELECT
    m.message_id,
    m.tribe_id,
    m.sender_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS sender_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')      AS sender_avatar_seed,
    CASE WHEN m.sender_persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
                                                                AS sender_profile_photo_url,
    m.sender_persona_id,
    m.content,
    m.image_url,
    m.audio_url,
    m.audio_duration_seconds,
    m.hugs_count,
    m.created_at,
    m.edited_at,
    m.deleted_at,
    m.reply_to_message_id,
    rm.content AS reply_content,
    COALESCE(rpr.pseudonym, ru.anonymous_pseudonym) AS reply_sender_pseudonym,
    EXISTS (
        SELECT 1 FROM tribe_message_hugs h
         WHERE h.message_id = m.message_id AND h.user_id = auth.uid()
    ) AS hugged_by_me,
    (t.pinned_message_id = m.message_id) AS is_pinned
FROM public.tribe_messages m
JOIN public.tribes t ON t.tribe_id = m.tribe_id
LEFT JOIN public.users    u   ON u.user_id     = m.sender_id
LEFT JOIN public.personas pr  ON pr.persona_id = m.sender_persona_id
                              AND pr.deleted_at IS NULL
LEFT JOIN public.tribe_messages rm ON rm.message_id = m.reply_to_message_id
LEFT JOIN public.users ru ON ru.user_id = rm.sender_id
LEFT JOIN public.personas rpr ON rpr.persona_id = rm.sender_persona_id;

GRANT SELECT ON public.tribe_messages_feed TO authenticated;

-- =========================================================================
-- 6) Media gallery feed
-- =========================================================================
-- Same reason: drop-then-create so a column change can't trip 42P16.
DROP VIEW IF EXISTS public.tribe_chat_media CASCADE;
CREATE VIEW public.tribe_chat_media
WITH (security_invoker = true) AS
SELECT
    m.message_id,
    m.tribe_id,
    m.sender_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS sender_pseudonym,
    m.image_url,
    m.audio_url,
    m.audio_duration_seconds,
    m.created_at,
    CASE
        WHEN m.image_url IS NOT NULL THEN 'image'
        WHEN m.audio_url IS NOT NULL THEN 'audio'
        ELSE 'other'
    END AS media_kind
FROM public.tribe_messages m
LEFT JOIN public.users u ON u.user_id = m.sender_id
LEFT JOIN public.personas pr ON pr.persona_id = m.sender_persona_id
WHERE m.deleted_at IS NULL
  AND (m.image_url IS NOT NULL OR m.audio_url IS NOT NULL);

GRANT SELECT ON public.tribe_chat_media TO authenticated;

-- =========================================================================
-- 7) tribe_directory — pinned_message_id
-- =========================================================================
-- Drop-then-create for the same reason as 0063: the column layout changes,
-- and CREATE OR REPLACE VIEW cannot drop/reorder existing columns (42P16).
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
    t.chat_settings,
    t.pinned_message_id
FROM public.tribes t
LEFT JOIN public.users u  ON u.user_id  = t.keeper_id
LEFT JOIN public.users sp ON sp.user_id = t.spotlight_user_id;

GRANT SELECT ON public.tribe_directory TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
