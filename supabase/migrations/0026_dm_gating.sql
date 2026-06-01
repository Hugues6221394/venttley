-- 0026_dm_gating.sql
--
-- DM gating: a new chat room can only be created between two users who
-- are accepted friends. Per the social spec, this prevents harassment
-- and forces intentional communication: friend request → accept → DM.
--
-- Mechanism
--
--   1. start_chat_room(target, preview, origin_post_id) SECURITY DEFINER
--      is the only sanctioned path for clients to create a room. It
--      checks friend_status = 'friends' and the absence of a block in
--      either direction. If a room already exists between the pair it
--      returns that room's id (idempotent).
--
--   2. The existing "chat_rooms initiator insert" RLS WITH CHECK is
--      tightened to also require the friendship (defence in depth — if
--      the client bypasses the RPC and tries a direct INSERT, RLS still
--      rejects). The RPC runs as SECURITY DEFINER so it bypasses RLS
--      and is the only friendly path.
--
--   3. can_dm(target) helper returns boolean for UI gating of DM CTAs.
--
-- Existing rooms are NOT affected — unfriending later does not erase
-- the history, but new room creation requires re-friending. (A block
-- already tears down friendships via block_user, so blocked pairs lose
-- DM eligibility automatically.)

CREATE OR REPLACE FUNCTION public.can_dm(p_target UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM friendships
         WHERE status = 'accepted'
           AND (
             (user_a = auth.uid() AND user_b = p_target)
             OR
             (user_a = p_target AND user_b = auth.uid())
           )
    )
    AND NOT EXISTS (
        SELECT 1 FROM user_blocks
         WHERE (blocker_id = auth.uid() AND blocked_id = p_target)
            OR (blocker_id = p_target AND blocked_id = auth.uid())
    );
$$;

REVOKE ALL ON FUNCTION public.can_dm(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_dm(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- start_chat_room — sanctioned room-creation path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_chat_room(
    p_target         UUID,
    p_preview        TEXT,
    p_origin_post_id UUID DEFAULT NULL
) RETURNS TABLE (
    room_id          UUID,
    request_preview  TEXT,
    room_status      TEXT,
    created_at       TIMESTAMPTZ,
    initiated_by_me  BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me  UUID := auth.uid();
    v_row chat_rooms%ROWTYPE;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_target IS NULL OR p_target = v_me THEN
        RAISE EXCEPTION 'invalid target';
    END IF;
    IF NOT can_dm(p_target) THEN
        RAISE EXCEPTION 'DM blocked: send a friend request first';
    END IF;

    -- Reuse existing room if present in either direction. Idempotent
    -- behavior matches what callers want — they invoke this from a
    -- "Message" button and expect "open or create".
    SELECT * INTO v_row
      FROM chat_rooms
     WHERE (initiated_by = v_me AND received_by = p_target)
        OR (initiated_by = p_target AND received_by = v_me)
     ORDER BY created_at ASC
     LIMIT 1;

    IF FOUND THEN
        -- If the existing room was previously declined, reopen it now
        -- that the two are friends (a more deliberate "we paused this"
        -- interaction; the room itself never died).
        IF v_row.room_status = 'declined' THEN
            UPDATE chat_rooms
               SET room_status = 'active', updated_at = now()
             WHERE room_id = v_row.room_id
             RETURNING * INTO v_row;
        END IF;
        room_id          := v_row.room_id;
        request_preview  := v_row.request_preview;
        room_status      := v_row.room_status;
        created_at       := v_row.created_at;
        initiated_by_me  := v_row.initiated_by = v_me;
        RETURN NEXT;
        RETURN;
    END IF;

    -- New room. Friends → start in 'active' (no need for the legacy
    -- request-preview accept/decline gate since friend acceptance
    -- already proved consent).
    INSERT INTO chat_rooms (
        initiated_by, received_by, origin_post_id, request_preview, room_status
    ) VALUES (
        v_me, p_target, p_origin_post_id, p_preview, 'active'
    ) RETURNING * INTO v_row;

    room_id          := v_row.room_id;
    request_preview  := v_row.request_preview;
    room_status      := v_row.room_status;
    created_at       := v_row.created_at;
    initiated_by_me  := true;
    RETURN NEXT;
END $$;

REVOKE ALL ON FUNCTION public.start_chat_room(UUID,TEXT,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_chat_room(UUID,TEXT,UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Defence in depth: tighten the INSERT RLS so direct client inserts also
-- require friendship. The SECURITY DEFINER RPC bypasses this, so the UX
-- path keeps working; only off-path bypasses are blocked.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "chat_rooms initiator insert" ON public.chat_rooms;
CREATE POLICY "chat_rooms initiator insert"
    ON public.chat_rooms FOR INSERT
    WITH CHECK (
      initiated_by = auth.uid()
      AND EXISTS (
        SELECT 1 FROM friendships
         WHERE status = 'accepted'
           AND (
             (user_a = auth.uid() AND user_b = received_by)
             OR
             (user_a = received_by AND user_b = auth.uid())
           )
      )
      AND NOT EXISTS (
        SELECT 1 FROM user_blocks
         WHERE (blocker_id = auth.uid() AND blocked_id = received_by)
            OR (blocker_id = received_by AND blocked_id = auth.uid())
      )
    );
