-- 0099_disappearing_messages.sql
-- Real, server-side disappearing messages for DMs. The 0098 version stored a
-- PER-USER TTL and only HID messages client-side — the rows still existed and
-- the peer still saw them. This makes it a CONVERSATION-level agreement (either
-- participant turns it on, like Instagram/WhatsApp) and HARD-DELETES expired
-- messages via pg_cron, so they're truly gone for both people.

-- 1) Room-level TTL (0 = off).
ALTER TABLE public.chat_rooms
    ADD COLUMN IF NOT EXISTS disappearing_seconds INT NOT NULL DEFAULT 0;

-- 2) Either participant sets the conversation TTL.
CREATE OR REPLACE FUNCTION public.set_room_disappearing(
    p_room_id UUID,
    p_seconds INT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_seconds < 0 THEN RAISE EXCEPTION 'invalid ttl'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.chat_rooms r
         WHERE r.room_id = p_room_id
           AND (r.initiated_by = v_me OR r.received_by = v_me)
    ) THEN
        RAISE EXCEPTION 'not a room participant';
    END IF;
    UPDATE public.chat_rooms
       SET disappearing_seconds = p_seconds, updated_at = now()
     WHERE room_id = p_room_id;
END $$;

GRANT EXECUTE ON FUNCTION public.set_room_disappearing(UUID, INT) TO authenticated;

-- 3) Sweep: hard-delete messages past their room's TTL. Runs as the cron owner
--    (bypasses RLS); chat_messages has no delete triggers so this is safe.
CREATE OR REPLACE FUNCTION public.expire_disappearing_dms()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
    DELETE FROM public.chat_messages m
     USING public.chat_rooms r
     WHERE m.room_id = r.room_id
       AND r.disappearing_seconds > 0
       AND m.created_at < now() - make_interval(secs => r.disappearing_seconds);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.unschedule('expire_disappearing_dms')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire_disappearing_dms');
-- Every 10 minutes: TTL granularity is ~10 min, fine for 1h/24h/7d options.
SELECT cron.schedule('expire_disappearing_dms', '*/10 * * * *',
                     $$ SELECT public.expire_disappearing_dms(); $$);

NOTIFY pgrst, 'reload schema';
