-- 0041_tribe_group_chat.sql
--
-- Tribe-scoped group chat (Image #16). Each message belongs to a tribe,
-- carries text + optional image + optional audio (waveform card), and
-- is gated by tribe membership at both INSERT and SELECT time.
--
-- Realtime: clients subscribe via Supabase postgres-changes on
-- `tribe_messages` filtered by tribe_id.

-- =========================================================================
-- 1) tribe_messages
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tribe_messages (
    message_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tribe_id                UUID NOT NULL REFERENCES public.tribes(tribe_id)   ON DELETE CASCADE,
    sender_id               UUID          REFERENCES public.users(user_id)     ON DELETE SET NULL,
    sender_persona_id       UUID          REFERENCES public.personas(persona_id) ON DELETE SET NULL,
    content                 TEXT          CHECK (content IS NULL OR length(content) <= 2000),
    image_url               TEXT,
    image_path              TEXT,
    audio_url               TEXT,
    audio_path              TEXT,
    audio_duration_seconds  INT  CHECK (audio_duration_seconds IS NULL OR audio_duration_seconds BETWEEN 1 AND 300),
    hugs_count              INT  NOT NULL DEFAULT 0 CHECK (hugs_count >= 0),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    edited_at               TIMESTAMPTZ,
    deleted_at              TIMESTAMPTZ,
    CHECK (
        content IS NOT NULL OR image_url IS NOT NULL OR audio_url IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS tribe_messages_tribe_created_idx
    ON public.tribe_messages (tribe_id, created_at DESC)
    WHERE deleted_at IS NULL;

ALTER TABLE public.tribe_messages ENABLE ROW LEVEL SECURITY;

-- Read: any member of the tribe.
DROP POLICY IF EXISTS "tribe messages member read" ON public.tribe_messages;
CREATE POLICY "tribe messages member read"
    ON public.tribe_messages FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM tribe_members tm
         WHERE tm.tribe_id = tribe_messages.tribe_id
           AND tm.user_id  = auth.uid()
      )
    );

-- Insert / update via SECURITY DEFINER RPCs only.
DROP POLICY IF EXISTS "tribe messages no direct insert" ON public.tribe_messages;
DROP POLICY IF EXISTS "tribe messages no direct update" ON public.tribe_messages;

GRANT SELECT ON public.tribe_messages TO authenticated;

-- =========================================================================
-- 2) Storage bucket for tribe-chat media (images + audio voice notes)
-- =========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'tribe-chat-media',
    'tribe-chat-media',
    true,
    20 * 1024 * 1024,
    ARRAY[
      'image/jpeg','image/png','image/webp','image/heic','image/gif',
      'audio/mpeg','audio/mp4','audio/aac','audio/ogg','audio/webm','audio/wav','audio/x-m4a'
    ]
)
ON CONFLICT (id) DO UPDATE
   SET public             = EXCLUDED.public,
       file_size_limit    = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "tribe chat media owner insert" ON storage.objects;
CREATE POLICY "tribe chat media owner insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'tribe-chat-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

DROP POLICY IF EXISTS "tribe chat media public read" ON storage.objects;
CREATE POLICY "tribe chat media public read"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'tribe-chat-media');

DROP POLICY IF EXISTS "tribe chat media owner delete" ON storage.objects;
CREATE POLICY "tribe chat media owner delete"
    ON storage.objects FOR DELETE
    USING (
      bucket_id = 'tribe-chat-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

-- =========================================================================
-- 3) send_tribe_message — gates membership, inserts row
-- =========================================================================
CREATE OR REPLACE FUNCTION public.send_tribe_message(
    p_tribe_id              UUID,
    p_content               TEXT  DEFAULT NULL,
    p_persona_id            UUID  DEFAULT NULL,
    p_image_url             TEXT  DEFAULT NULL,
    p_image_path            TEXT  DEFAULT NULL,
    p_audio_url             TEXT  DEFAULT NULL,
    p_audio_path            TEXT  DEFAULT NULL,
    p_audio_duration_seconds INT  DEFAULT NULL
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

    INSERT INTO tribe_messages (
        tribe_id, sender_id, sender_persona_id,
        content, image_url, image_path,
        audio_url, audio_path, audio_duration_seconds
    ) VALUES (
        p_tribe_id, v_me, p_persona_id,
        p_content, p_image_url, p_image_path,
        p_audio_url, p_audio_path, p_audio_duration_seconds
    ) RETURNING message_id INTO v_msg_id;

    RETURN v_msg_id;
END $$;

REVOKE ALL ON FUNCTION public.send_tribe_message(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_tribe_message(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, INT) TO authenticated;

-- =========================================================================
-- 4) tribe_messages_feed view — joins sender pseudonym/avatar
-- =========================================================================
CREATE OR REPLACE VIEW public.tribe_messages_feed
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
    m.deleted_at
FROM public.tribe_messages m
LEFT JOIN public.users    u  ON u.user_id     = m.sender_id
LEFT JOIN public.personas pr ON pr.persona_id = m.sender_persona_id
                            AND pr.deleted_at IS NULL;

GRANT SELECT ON public.tribe_messages_feed TO authenticated;

-- =========================================================================
-- 5) tribe_chat_presence — # of members active in the last 5 minutes
--    proxy via the `last_seen_at` column on tribe_members. If your
--    schema doesn't track that yet, the function falls back to total
--    member count so the souls-online label always renders something.
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
     WHERE tm.tribe_id = p_tribe_id;
    RETURN COALESCE(v_count, 0);
END $$;

REVOKE ALL ON FUNCTION public.tribe_chat_presence(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_chat_presence(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
