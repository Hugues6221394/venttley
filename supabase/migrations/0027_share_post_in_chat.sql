-- 0027_share_post_in_chat.sql
--
-- Confession sharing in DMs. A chat message can now carry an attached
-- post id plus a JSONB snapshot of the post (content + author identity
-- + created_at) captured at send time.
--
-- Why a snapshot, not just a FK
--   - Posts can be soft-deleted by the author or moderators. The shared
--     card should still render in the recipient's chat (with a "post
--     deleted" affordance) so the conversation remains coherent.
--   - Whisper posts (24h expiry) disappear from the public feed but the
--     friend who received the share should still see what was discussed.
--   - The snapshot is a few hundred bytes — cheap vs. losing context.
--
-- All chat-message INSERTs route through send_chat_message (SECURITY
-- DEFINER). The existing direct-insert RLS keeps working for backwards
-- compat; new clients use the RPC because it returns the inserted row
-- shape we want (including the freshly-captured snapshot).

ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS attached_post_id UUID
        REFERENCES public.posts(post_id) ON DELETE SET NULL;
ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS attached_post_snapshot JSONB;

CREATE INDEX IF NOT EXISTS chat_messages_attached_post_idx
    ON public.chat_messages (attached_post_id)
    WHERE attached_post_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- send_chat_message — one path for both plain text and share-with-post
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_chat_message(
    p_room_id          UUID,
    p_payload          TEXT,
    p_attached_post_id UUID DEFAULT NULL
) RETURNS TABLE (
    message_id              UUID,
    room_id                 UUID,
    sender_id               UUID,
    payload                 TEXT,
    attached_post_id        UUID,
    attached_post_snapshot  JSONB,
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

    IF p_attached_post_id IS NOT NULL THEN
        -- Snapshot the post NOW so the card survives later deletion.
        -- Only allow sharing posts the sender can read (live or own).
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
        attached_post_id, attached_post_snapshot
    ) VALUES (
        p_room_id, v_me, p_payload, 'v1-plaintext',
        p_attached_post_id, v_snapshot
    ) RETURNING * INTO v_row;

    message_id              := v_row.message_id;
    room_id                 := v_row.room_id;
    sender_id               := v_row.sender_id;
    payload                 := v_row.encrypted_payload;
    attached_post_id        := v_row.attached_post_id;
    attached_post_snapshot  := v_row.attached_post_snapshot;
    created_at              := v_row.created_at;
    RETURN NEXT;
END $$;

REVOKE ALL ON FUNCTION public.send_chat_message(UUID,TEXT,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID,TEXT,UUID) TO authenticated;
