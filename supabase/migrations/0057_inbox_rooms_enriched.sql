-- 0057_inbox_rooms_enriched.sql
--
-- Enrich inbox_rooms with per-room unread counts, last-message preview,
-- activity timestamp, and read-receipt state for the caller's last message.
-- Powers inbox row accents, preview text, and delivery glyphs.

DROP VIEW IF EXISTS public.inbox_rooms;

CREATE VIEW public.inbox_rooms
WITH (security_invoker = true) AS
SELECT
    r.room_id,
    r.initiated_by,
    r.received_by,
    r.request_preview,
    r.room_status,
    r.created_at,
    r.updated_at,
    CASE WHEN r.initiated_by = auth.uid() THEN r.received_by  ELSE r.initiated_by END AS peer_id,
    CASE WHEN r.initiated_by = auth.uid() THEN peer_recv.anonymous_pseudonym
                                          ELSE peer_init.anonymous_pseudonym END AS peer_pseudonym,
    CASE WHEN r.initiated_by = auth.uid() THEN peer_recv.avatar_seed
                                          ELSE peer_init.avatar_seed END         AS peer_avatar_seed,
    CASE WHEN r.initiated_by = auth.uid() THEN true ELSE false END               AS initiated_by_me,
    COALESCE(lm.unread_count, 0)::INT                                            AS unread_count,
    lm.last_message_preview,
    lm.last_message_at,
    COALESCE(lm.last_own_message_read, false)                                      AS last_own_message_read,
    COALESCE(lm.last_message_at, r.updated_at, r.created_at)                     AS sort_activity_at
FROM public.chat_rooms r
LEFT JOIN public.users peer_init ON peer_init.user_id = r.initiated_by
LEFT JOIN public.users peer_recv ON peer_recv.user_id = r.received_by
LEFT JOIN LATERAL (
    SELECT
        (
            SELECT count(*)::INT
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.sender_id IS DISTINCT FROM auth.uid()
               AND m.read_at IS NULL
               AND m.deleted_at IS NULL
        ) AS unread_count,
        (
            SELECT left(m.encrypted_payload, 280)
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.deleted_at IS NULL
             ORDER BY m.created_at DESC
             LIMIT 1
        ) AS last_message_preview,
        (
            SELECT m.created_at
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.deleted_at IS NULL
             ORDER BY m.created_at DESC
             LIMIT 1
        ) AS last_message_at,
        (
            SELECT m.read_at IS NOT NULL
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.sender_id = auth.uid()
               AND m.deleted_at IS NULL
             ORDER BY m.created_at DESC
             LIMIT 1
        ) AS last_own_message_read
) lm ON true;

GRANT SELECT ON public.inbox_rooms TO anon, authenticated;
