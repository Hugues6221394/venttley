-- 0112_enable_realtime_publication.sql
--
-- THE realtime fix. The client has subscribed to postgres_changes on
-- posts, chat_rooms, chat_messages, chat_message_reactions and
-- tribe_messages since the chat features shipped — but none of those
-- tables were ever added to the supabase_realtime publication, so no
-- event has ever been delivered. Messages only appeared on re-fetch
-- (screen open / pull-to-refresh), which is why the app never felt live.
--
-- postgres_changes respects RLS per subscriber (WALRUS), so adding a
-- table here exposes nothing beyond what its SELECT policies allow.
--
-- friendships joins the set for the friends badge + live accept flow.

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'posts',
        'chat_rooms',
        'chat_messages',
        'chat_message_reactions',
        'tribe_messages',
        'friendships',
        'whisper_reactions'
    ]
    LOOP
        BEGIN
            EXECUTE format(
                'ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
        EXCEPTION
            WHEN duplicate_object THEN NULL;
        END;
    END LOOP;
END $$;
