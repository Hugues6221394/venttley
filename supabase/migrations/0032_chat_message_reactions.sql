-- 0032_chat_message_reactions.sql
--
-- Emoji reactions on chat messages — same six-emotion palette used on
-- posts (migration 0016). One reaction per user per message; tapping
-- the same emoji again clears the reaction; tapping a different emoji
-- swaps it. This matches the established `set_reaction` post semantic.
--
-- Routed through SECURITY DEFINER RPC `set_chat_message_reaction` so
-- room participation is verified server-side and clients can't write
-- reactions on rooms they aren't in.

CREATE TABLE IF NOT EXISTS public.chat_message_reactions (
    message_id    UUID         NOT NULL REFERENCES public.chat_messages(message_id) ON DELETE CASCADE,
    user_id       UUID         NOT NULL REFERENCES public.users(user_id)           ON DELETE CASCADE,
    reaction_type TEXT         NOT NULL CHECK (
        reaction_type IN ('like','relate','hug','stay_strong','been_there','crazy')
    ),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS chat_message_reactions_msg_idx
    ON public.chat_message_reactions (message_id);

ALTER TABLE public.chat_message_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "chat_reactions participant read" ON public.chat_message_reactions;
CREATE POLICY "chat_reactions participant read"
    ON public.chat_message_reactions FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM chat_messages m
        JOIN chat_rooms r ON r.room_id = m.room_id
        WHERE m.message_id = chat_message_reactions.message_id
          AND auth.uid() IN (r.initiated_by, r.received_by)
      )
    );

GRANT SELECT ON public.chat_message_reactions TO authenticated;

-- ---------------------------------------------------------------------------
-- set_chat_message_reaction — toggle / swap / clear semantics
-- ---------------------------------------------------------------------------
--   reaction_type = NULL                → clears caller's reaction
--   reaction_type = current one         → clears (toggle off)
--   reaction_type = different           → swaps to the new one
--
-- Returns the resulting reaction_type (or NULL if cleared) so the
-- client can update its optimistic state without re-fetching.
CREATE OR REPLACE FUNCTION public.set_chat_message_reaction(
    p_message_id    UUID,
    p_reaction_type TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me      UUID := auth.uid();
    v_room    UUID;
    v_current TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT room_id INTO v_room
      FROM chat_messages
     WHERE message_id = p_message_id;
    IF v_room IS NULL THEN
        RAISE EXCEPTION 'message not found';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM chat_rooms
         WHERE room_id = v_room
           AND auth.uid() IN (initiated_by, received_by)
    ) THEN
        RAISE EXCEPTION 'not a participant';
    END IF;

    SELECT reaction_type INTO v_current
      FROM chat_message_reactions
     WHERE message_id = p_message_id AND user_id = v_me;

    -- Null arg, or same emoji → clear.
    IF p_reaction_type IS NULL
       OR (v_current IS NOT NULL AND v_current = p_reaction_type) THEN
        DELETE FROM chat_message_reactions
         WHERE message_id = p_message_id AND user_id = v_me;
        RETURN NULL;
    END IF;

    INSERT INTO chat_message_reactions (message_id, user_id, reaction_type)
    VALUES (p_message_id, v_me, p_reaction_type)
    ON CONFLICT (message_id, user_id)
      DO UPDATE SET reaction_type = EXCLUDED.reaction_type,
                    created_at = now();
    RETURN p_reaction_type;
END $$;

REVOKE ALL ON FUNCTION public.set_chat_message_reaction(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_chat_message_reaction(UUID,TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Summary view — aggregated reaction counts per message, plus the
-- caller's own current reaction. Keeps the client read to one query.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.chat_message_reactions_summary;
CREATE VIEW public.chat_message_reactions_summary
WITH (security_invoker = true) AS
SELECT
    r.message_id,
    jsonb_object_agg(r.reaction_type, c) AS reaction_counts,
    (
        SELECT reaction_type FROM chat_message_reactions
         WHERE message_id = r.message_id AND user_id = auth.uid()
    ) AS my_reaction
FROM (
    SELECT message_id, reaction_type, count(*)::int AS c
      FROM chat_message_reactions
     GROUP BY message_id, reaction_type
) r
GROUP BY r.message_id;

GRANT SELECT ON public.chat_message_reactions_summary TO authenticated;
