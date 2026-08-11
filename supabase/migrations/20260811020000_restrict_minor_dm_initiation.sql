-- Enforce "restricted minors do not initiate DMs" on the server.
--
-- Until now safety_tier was stored and propagated but never gated anything.
-- The existing protection was the friendship requirement in can_dm(), which
-- already stops cold-DMing a stranger — so this closes the remaining gap
-- rather than being the only line of defence.
--
-- Scope is deliberately "initiation", matching the documented contract. A
-- restricted minor can still reply in a conversation that already exists;
-- sending runs through send_chat_message, not this function. The check is
-- placed AFTER the existing-room lookup so an already-open thread keeps
-- resolving normally and only the INSERT path is refused.

CREATE OR REPLACE FUNCTION public.is_restricted_minor(p_user UUID DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE(
        (SELECT u.safety_tier = 'restricted_minor'
           FROM public.users AS u
          WHERE u.user_id = COALESCE(p_user, auth.uid())),
        -- No row / no session reads as restricted: unknown fails closed.
        TRUE
    );
$$;

REVOKE ALL ON FUNCTION public.is_restricted_minor(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_restricted_minor(UUID) TO authenticated;

-- UI gate. Kept separate from can_dm() so the CTA can be hidden without
-- changing the meaning of can_dm (friendship + no block), which other call
-- sites rely on.
CREATE OR REPLACE FUNCTION public.can_initiate_dm(p_target UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT public.can_dm(p_target) AND NOT public.is_restricted_minor();
$$;

REVOKE ALL ON FUNCTION public.can_initiate_dm(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_initiate_dm(UUID) TO authenticated;

-- Signature and return shape unchanged so no coordinated client release is
-- needed (same contract the 20260718181541 repair preserved).
CREATE OR REPLACE FUNCTION public.start_chat_room(
  p_target UUID,
  p_preview TEXT,
  p_origin_post_id UUID DEFAULT NULL
) RETURNS TABLE (
  room_id UUID,
  request_preview TEXT,
  room_status TEXT,
  created_at TIMESTAMPTZ,
  initiated_by_me BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_row public.chat_rooms%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_target IS NULL OR p_target = v_me THEN
    RAISE EXCEPTION 'invalid target';
  END IF;
  IF NOT public.can_dm(p_target) THEN
    RAISE EXCEPTION 'DM blocked: send a friend request first';
  END IF;

  SELECT cr.* INTO v_row
    FROM public.chat_rooms AS cr
   WHERE (cr.initiated_by = v_me AND cr.received_by = p_target)
      OR (cr.initiated_by = p_target AND cr.received_by = v_me)
   ORDER BY cr.created_at ASC
   LIMIT 1;

  IF FOUND THEN
    IF v_row.room_status = 'declined' THEN
      UPDATE public.chat_rooms AS cr
         SET room_status = 'active', updated_at = now()
       WHERE cr.room_id = v_row.room_id
       RETURNING cr.* INTO v_row;
    END IF;
    room_id := v_row.room_id;
    request_preview := v_row.request_preview;
    room_status := v_row.room_status;
    created_at := v_row.created_at;
    initiated_by_me := v_row.initiated_by = v_me;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Only new conversations are refused; the lookup above already returned for
  -- every thread that exists.
  IF public.is_restricted_minor() THEN
    RAISE EXCEPTION 'minor_dm_initiation_blocked'
      USING HINT = 'Accounts registered as 13-17 cannot start new chats.';
  END IF;

  INSERT INTO public.chat_rooms (
    initiated_by, received_by, origin_post_id, request_preview, room_status
  ) VALUES (
    v_me, p_target, p_origin_post_id, p_preview, 'active'
  ) RETURNING * INTO v_row;

  room_id := v_row.room_id;
  request_preview := v_row.request_preview;
  room_status := v_row.room_status;
  created_at := v_row.created_at;
  initiated_by_me := TRUE;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.start_chat_room(UUID, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_chat_room(UUID, TEXT, UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
