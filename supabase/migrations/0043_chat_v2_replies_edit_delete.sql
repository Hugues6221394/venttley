-- 0043_chat_v2_replies_edit_delete.sql
--
-- Chat V2 essentials: quoted replies, edit-in-place, delete-for-me.
-- Adds three columns to chat_messages and three SECURITY DEFINER RPCs
-- that gate ownership / room membership.

-- =========================================================================
-- 1) chat_messages: parent_message_id + edited_at + deleted_for_sender
-- =========================================================================
ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS parent_message_id UUID REFERENCES public.chat_messages(message_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS edited_at         TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deleted_at        TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS chat_messages_parent_idx
    ON public.chat_messages (parent_message_id)
    WHERE parent_message_id IS NOT NULL;

-- =========================================================================
-- 2) send_chat_message wrapper that accepts a parent_message_id
--    The existing send_chat_message RPC stays — we add a new entrypoint
--    that includes the reply pointer + falls through to the same insert.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.send_chat_message_v2(
    p_room_id            UUID,
    p_plaintext          TEXT,
    p_attached_post_id   UUID DEFAULT NULL,
    p_media_path         TEXT DEFAULT NULL,
    p_media_type         TEXT DEFAULT NULL,
    p_parent_message_id  UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_is_member BOOLEAN;
    v_msg_id UUID;
    v_snapshot JSONB;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM chat_rooms
         WHERE room_id = p_room_id
           AND (initiated_by = v_me OR received_by = v_me)
    ) INTO v_is_member;
    IF NOT v_is_member THEN RAISE EXCEPTION 'not a room participant'; END IF;

    -- If a parent is set, sanity-check it belongs to the same room so
    -- callers can't quote messages across rooms.
    IF p_parent_message_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM chat_messages
             WHERE message_id = p_parent_message_id AND room_id = p_room_id
        ) THEN
            RAISE EXCEPTION 'parent message does not belong to this room';
        END IF;
    END IF;

    -- If a post is attached, snapshot it for posterity.
    IF p_attached_post_id IS NOT NULL THEN
        SELECT jsonb_build_object(
            'post_id',          p.post_id,
            'content',          p.content,
            'author_pseudonym', COALESCE(u.anonymous_pseudonym, 'anonymous'),
            'author_avatar_seed', COALESCE(u.avatar_seed, 'default-orb'),
            'category',         p.category_name,
            'mood',             p.post_mood,
            'is_whisper',       p.is_whisper,
            'created_at',       p.created_at
        )
          INTO v_snapshot
          FROM posts p
          LEFT JOIN users u ON u.user_id = p.author_id
         WHERE p.post_id = p_attached_post_id;
    END IF;

    INSERT INTO chat_messages (
        room_id, sender_id, encrypted_payload,
        attached_post_id, attached_post_snapshot,
        attached_media_path, attached_media_type,
        parent_message_id
    ) VALUES (
        p_room_id, v_me, p_plaintext,
        p_attached_post_id, v_snapshot,
        p_media_path, p_media_type,
        p_parent_message_id
    ) RETURNING message_id INTO v_msg_id;

    RETURN v_msg_id;
END $$;

REVOKE ALL ON FUNCTION public.send_chat_message_v2(UUID, TEXT, UUID, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_chat_message_v2(UUID, TEXT, UUID, TEXT, TEXT, UUID) TO authenticated;

-- =========================================================================
-- 3) edit_chat_message — author-only, sets edited_at, 5-minute window
-- =========================================================================
CREATE OR REPLACE FUNCTION public.edit_chat_message(
    p_message_id UUID,
    p_plaintext  TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
    v_created TIMESTAMPTZ;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_plaintext IS NULL OR length(trim(p_plaintext)) = 0 THEN
        RAISE EXCEPTION 'empty edit not allowed';
    END IF;
    IF length(p_plaintext) > 4000 THEN
        RAISE EXCEPTION 'message too long';
    END IF;

    SELECT sender_id = v_me, created_at
      INTO v_owns, v_created
      FROM chat_messages
     WHERE message_id = p_message_id AND deleted_at IS NULL;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;
    IF now() - v_created > INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;

    UPDATE chat_messages
       SET encrypted_payload = p_plaintext,
           edited_at         = now()
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.edit_chat_message(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(UUID, TEXT) TO authenticated;

-- =========================================================================
-- 4) delete_chat_message — author-only, soft-delete via deleted_at
-- =========================================================================
CREATE OR REPLACE FUNCTION public.delete_chat_message(p_message_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_owns BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT sender_id = v_me INTO v_owns
      FROM chat_messages
     WHERE message_id = p_message_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;

    UPDATE chat_messages
       SET deleted_at = now(),
           encrypted_payload = ''
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.delete_chat_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_chat_message(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
