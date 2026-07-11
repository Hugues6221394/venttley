-- 0055_inbox_unread_count.sql
--
-- Single RPC for the Inbox tab badge: counts unread peer messages
-- across all active chat rooms for the signed-in user.

CREATE OR REPLACE FUNCTION public.unread_chat_message_count()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RETURN 0; END IF;

    RETURN (
        SELECT count(*)::INT
          FROM chat_messages m
          JOIN chat_rooms r ON r.room_id = m.room_id
         WHERE r.room_status = 'active'
           AND (r.initiated_by = v_me OR r.received_by = v_me)
           AND m.sender_id IS DISTINCT FROM v_me
           AND m.read_at IS NULL
           AND m.deleted_at IS NULL
    );
END $$;

REVOKE ALL ON FUNCTION public.unread_chat_message_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unread_chat_message_count() TO authenticated;
