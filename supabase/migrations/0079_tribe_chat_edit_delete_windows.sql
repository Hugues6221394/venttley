-- ---------------------------------------------------------------------------
-- Venttly | Migration 0079 — Tribe chat: 30-min edit, tiered delete, hide-for-me
-- ---------------------------------------------------------------------------
-- Mirror of 0078 for tribe hub chat (tribe_messages):
--   * Edit window 5 min -> 30 min (author only).
--   * "Delete for everyone" capped to 24h after sending (author only).
--   * "Delete for me" is new: any tribe member can hide any message from their
--     own view via a per-user hide row; everyone else still sees it. Filtered
--     client-side (also covers realtime).
-- ---------------------------------------------------------------------------

-- 1) edit_tribe_message — widen window to 30 minutes ------------------------
CREATE OR REPLACE FUNCTION public.edit_tribe_message(
    p_message_id UUID,
    p_content    TEXT
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
    IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
        RAISE EXCEPTION 'empty edit not allowed';
    END IF;
    IF length(p_content) > 2000 THEN
        RAISE EXCEPTION 'message too long';
    END IF;
    SELECT sender_id = v_me, created_at
      INTO v_owns, v_created
      FROM tribe_messages
     WHERE message_id = p_message_id AND deleted_at IS NULL;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;
    IF now() - v_created > INTERVAL '30 minutes' THEN
        RAISE EXCEPTION 'edit window expired';
    END IF;
    UPDATE tribe_messages
       SET content   = p_content,
           edited_at = now()
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

-- 2) delete_tribe_message — "for everyone", now capped at 24h ---------------
CREATE OR REPLACE FUNCTION public.delete_tribe_message(p_message_id UUID)
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
      FROM tribe_messages WHERE message_id = p_message_id;
    IF v_owns IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF NOT v_owns THEN RAISE EXCEPTION 'not your message'; END IF;
    IF now() - v_created > INTERVAL '24 hours' THEN
        RAISE EXCEPTION 'delete-for-everyone window expired';
    END IF;
    UPDATE tribe_messages SET deleted_at = now()
     WHERE message_id = p_message_id;
    RETURN TRUE;
END $$;

-- 3) tribe_message_hides — per-user "delete for me" ------------------------
CREATE TABLE IF NOT EXISTS public.tribe_message_hides (
    message_id UUID NOT NULL REFERENCES public.tribe_messages(message_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(user_id)          ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS tribe_message_hides_user_idx
    ON public.tribe_message_hides (user_id);

ALTER TABLE public.tribe_message_hides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tribe hides self" ON public.tribe_message_hides;
CREATE POLICY "tribe hides self"
    ON public.tribe_message_hides FOR SELECT
    USING (user_id = auth.uid());

GRANT SELECT ON public.tribe_message_hides TO authenticated;

-- hide_tribe_message — record a delete-for-me. Verifies the caller is a
-- member of the message's tribe.
CREATE OR REPLACE FUNCTION public.hide_tribe_message(p_message_id UUID)
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
          FROM tribe_messages m
          JOIN tribe_members tm ON tm.tribe_id = m.tribe_id
         WHERE m.message_id = p_message_id
           AND tm.user_id = v_me
    ) INTO v_ok;
    IF NOT v_ok THEN RAISE EXCEPTION 'message not found'; END IF;

    INSERT INTO tribe_message_hides (message_id, user_id)
    VALUES (p_message_id, v_me)
    ON CONFLICT (message_id, user_id) DO NOTHING;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.hide_tribe_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hide_tribe_message(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
