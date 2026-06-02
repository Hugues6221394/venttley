-- 0031_chat_read_receipts.sql
--
-- Read receipts for DMs. chat_messages.read_at has existed since
-- migration 0001 but no client path actually populated it. This adds
-- the sanctioned write path:
--
--   mark_chat_room_read(room_id) sets read_at = now() on every message
--   in the room that wasn't sent by the caller and isn't already read.
--   Returns the count of newly-marked messages so the client can update
--   inbox-unread badges without a separate count round-trip.
--
-- SECURITY DEFINER. Verifies the caller is a participant of the room.
-- Idempotent — already-read messages are not touched (preserves the
-- original read_at timestamp, which we surface to the sender).

CREATE OR REPLACE FUNCTION public.mark_chat_room_read(p_room_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_count INT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM chat_rooms
         WHERE room_id = p_room_id
           AND (initiated_by = v_me OR received_by = v_me)
    ) THEN
        RAISE EXCEPTION 'not a participant';
    END IF;

    WITH updated AS (
        UPDATE chat_messages
           SET read_at = now()
         WHERE room_id = p_room_id
           AND sender_id <> v_me
           AND read_at IS NULL
         RETURNING message_id
    )
    SELECT count(*) INTO v_count FROM updated;
    RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.mark_chat_room_read(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_chat_room_read(UUID) TO authenticated;
