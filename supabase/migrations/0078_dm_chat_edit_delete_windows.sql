-- ---------------------------------------------------------------------------
-- Venttly | Migration 0078 — DM chat: 30-min edit, tiered delete, delete-for-me
-- ---------------------------------------------------------------------------
-- Brings direct-message chat (chat_messages) in line with WhatsApp/Instagram
-- semantics:
--
--   * Edit window widened 5 min -> 30 min (author only).
--   * "Delete for everyone" is now capped to 24h after sending (author only) —
--     the existing deleted_at tombstone, just time-boxed.
--   * "Delete for me" is new: any room participant can hide any message (their
--     own or the other person's, at any age) from *their own* view only. This
--     is a per-user hide row, never a tombstone, so the other participant is
--     unaffected. The client filters these out (which also covers realtime,
--     where the row still streams).
-- ---------------------------------------------------------------------------

-- 1) edit_chat_message — widen window to 30 minutes -------------------------
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
    IF now() - v_created > INTERVAL '30 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;

    UPDATE chat_messages
       SET encrypted_payload = p_plaintext,
           edited_at         = now()
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

-- 2) delete_chat_message — "for everyone", now capped at 24h ----------------
CREATE OR REPLACE FUNCTION public.delete_chat_message(p_message_id UUID)
RETURNS BOOLEAN
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

    SELECT sender_id = v_me, created_at INTO v_owns, v_created
      FROM chat_messages
     WHERE message_id = p_message_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;
    IF now() - v_created > INTERVAL '24 hours' THEN
        RAISE EXCEPTION 'delete-for-everyone window expired';
    END IF;

    UPDATE chat_messages
       SET deleted_at = now(),
           encrypted_payload = ''
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

-- 3) chat_message_hides — per-user "delete for me" -------------------------
CREATE TABLE IF NOT EXISTS public.chat_message_hides (
    message_id UUID NOT NULL REFERENCES public.chat_messages(message_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(user_id)        ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS chat_message_hides_user_idx
    ON public.chat_message_hides (user_id);

ALTER TABLE public.chat_message_hides ENABLE ROW LEVEL SECURITY;

-- A member only ever sees / manages their own hide rows.
DROP POLICY IF EXISTS "chat hides self" ON public.chat_message_hides;
CREATE POLICY "chat hides self"
    ON public.chat_message_hides FOR SELECT
    USING (user_id = auth.uid());

GRANT SELECT ON public.chat_message_hides TO authenticated;

-- hide_chat_message — record a delete-for-me. Verifies the caller is a
-- participant of the message's room so you can't hide messages you can't see.
CREATE OR REPLACE FUNCTION public.hide_chat_message(p_message_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_ok BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT EXISTS (
        SELECT 1
          FROM chat_messages m
          JOIN chat_rooms r ON r.room_id = m.room_id
         WHERE m.message_id = p_message_id
           AND (r.initiated_by = v_me OR r.received_by = v_me)
    ) INTO v_ok;
    IF NOT v_ok THEN RAISE EXCEPTION 'message not found'; END IF;

    INSERT INTO chat_message_hides (message_id, user_id)
    VALUES (p_message_id, v_me)
    ON CONFLICT (message_id, user_id) DO NOTHING;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.hide_chat_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hide_chat_message(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
