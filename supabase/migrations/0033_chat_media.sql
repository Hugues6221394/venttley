-- 0033_chat_media.sql
--
-- Image attachments on DMs (voice deliberately out of scope).
--
-- Strategy
--   - A private Supabase Storage bucket `chat-media` holds raw image
--     bytes. Path convention: `<room_id>/<message_id>.<ext>`. The
--     room_id prefix is what RLS policies key on — only room
--     participants can SELECT or INSERT under their rooms.
--   - chat_messages gets attached_media_path + attached_media_type
--     columns. send_chat_message accepts both and stamps them into
--     the row. The send path remains the only sanctioned write.
--   - Reads use short-lived signed URLs minted client-side via the
--     storage SDK. The bucket isn't public.

-- =========================================================================
-- 1) Bucket
-- =========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'chat-media',
    'chat-media',
    false,
    8 * 1024 * 1024, -- 8 MB cap per upload; resize client-side if needed
    ARRAY['image/jpeg','image/png','image/webp','image/heic','image/gif']
)
ON CONFLICT (id) DO UPDATE
   SET public           = EXCLUDED.public,
       file_size_limit  = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

-- =========================================================================
-- 2) Storage RLS — only room participants can read/insert
-- =========================================================================
DROP POLICY IF EXISTS "chat-media room participants read"  ON storage.objects;
CREATE POLICY "chat-media room participants read"
    ON storage.objects FOR SELECT
    USING (
      bucket_id = 'chat-media'
      AND EXISTS (
        SELECT 1 FROM public.chat_rooms r
         WHERE r.room_id::text = split_part(name, '/', 1)
           AND auth.uid() IN (r.initiated_by, r.received_by)
      )
    );

DROP POLICY IF EXISTS "chat-media room participants insert" ON storage.objects;
CREATE POLICY "chat-media room participants insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'chat-media'
      AND owner = auth.uid()
      AND EXISTS (
        SELECT 1 FROM public.chat_rooms r
         WHERE r.room_id::text = split_part(name, '/', 1)
           AND auth.uid() IN (r.initiated_by, r.received_by)
      )
    );

-- =========================================================================
-- 3) chat_messages columns
-- =========================================================================
ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS attached_media_path TEXT,
    ADD COLUMN IF NOT EXISTS attached_media_type TEXT
        CHECK (attached_media_type IS NULL OR attached_media_type IN ('image'));

CREATE INDEX IF NOT EXISTS chat_messages_attached_media_idx
    ON public.chat_messages (room_id)
    WHERE attached_media_path IS NOT NULL;

-- =========================================================================
-- 4) Extend send_chat_message — same idempotent semantic, new args
-- =========================================================================
CREATE OR REPLACE FUNCTION public.send_chat_message(
    p_room_id          UUID,
    p_payload          TEXT,
    p_attached_post_id UUID  DEFAULT NULL,
    p_media_path       TEXT  DEFAULT NULL,
    p_media_type       TEXT  DEFAULT NULL
) RETURNS TABLE (
    message_id              UUID,
    room_id                 UUID,
    sender_id               UUID,
    payload                 TEXT,
    attached_post_id        UUID,
    attached_post_snapshot  JSONB,
    attached_media_path     TEXT,
    attached_media_type     TEXT,
    created_at              TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me       UUID := auth.uid();
    v_room     chat_rooms%ROWTYPE;
    v_snapshot JSONB;
    v_row      chat_messages%ROWTYPE;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT * INTO v_room FROM chat_rooms WHERE chat_rooms.room_id = p_room_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'room not found'; END IF;
    IF v_me NOT IN (v_room.initiated_by, v_room.received_by) THEN
        RAISE EXCEPTION 'not a participant';
    END IF;
    IF v_room.room_status <> 'active' THEN
        RAISE EXCEPTION 'room is not active';
    END IF;

    -- Media path sanity: must be in this room's prefix when present.
    IF p_media_path IS NOT NULL
       AND p_media_path !~ ('^' || p_room_id::text || '/') THEN
        RAISE EXCEPTION 'media path must be in room prefix';
    END IF;
    IF p_media_type IS NOT NULL AND p_media_type NOT IN ('image') THEN
        RAISE EXCEPTION 'unsupported media type';
    END IF;

    IF p_attached_post_id IS NOT NULL THEN
        SELECT jsonb_build_object(
            'post_id',     p.post_id,
            'content',     left(p.content, 400),
            'author_id',   p.author_id,
            'category',    p.category_name,
            'mood',        p.post_mood,
            'is_whisper',  p.is_whisper,
            'created_at',  p.created_at,
            'author_pseudonym',
                COALESCE('@' || pr.pseudonym, '@' || u.anonymous_pseudonym),
            'author_avatar_seed',
                COALESCE(pr.avatar_seed, u.avatar_seed)
        ) INTO v_snapshot
        FROM posts p
        LEFT JOIN users    u  ON u.user_id = p.author_id
        LEFT JOIN personas pr ON pr.persona_id = p.persona_id
                              AND pr.deleted_at IS NULL
        WHERE p.post_id = p_attached_post_id
          AND p.deleted_at IS NULL;
        IF v_snapshot IS NULL THEN
            RAISE EXCEPTION 'attached post not found or not readable';
        END IF;
    END IF;

    INSERT INTO chat_messages (
        room_id, sender_id, encrypted_payload, nonce_iv,
        attached_post_id, attached_post_snapshot,
        attached_media_path, attached_media_type
    ) VALUES (
        p_room_id, v_me, p_payload, 'v1-plaintext',
        p_attached_post_id, v_snapshot,
        p_media_path, p_media_type
    ) RETURNING * INTO v_row;

    message_id              := v_row.message_id;
    room_id                 := v_row.room_id;
    sender_id               := v_row.sender_id;
    payload                 := v_row.encrypted_payload;
    attached_post_id        := v_row.attached_post_id;
    attached_post_snapshot  := v_row.attached_post_snapshot;
    attached_media_path     := v_row.attached_media_path;
    attached_media_type     := v_row.attached_media_type;
    created_at              := v_row.created_at;
    RETURN NEXT;
END $$;

REVOKE ALL ON FUNCTION public.send_chat_message(UUID,TEXT,UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID,TEXT,UUID,TEXT,TEXT) TO authenticated;

-- Drop the prior 3-arg overload now that we've upgraded the signature.
-- All callers are migrating in lockstep with the Dart change in this same
-- commit set; keeping both signatures would cause an ambiguous-call error.
DROP FUNCTION IF EXISTS public.send_chat_message(UUID, TEXT, UUID);
