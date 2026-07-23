-- 0114_presence_and_receipts.sql
--
--  * Presence: users.last_seen_at heartbeat + show_last_seen privacy toggle,
--    touch_last_seen() heartbeat RPC, peer_presence() display RPC with the
--    tiers Online / Active recently / Last seen Xh / hidden.
--  * Read receipts: chat_messages.delivered_at + mark_room_delivered(), so
--    DM bubbles can show sent (one check) → delivered (two) → seen (blue).
--  * Fixes "and 1 others" pluralization in _notify (0113).

-- ---------------------------------------------------------------------------
-- 1. Presence
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS last_seen_at   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS show_last_seen BOOLEAN NOT NULL DEFAULT TRUE;

-- Heartbeat — client calls on resume + every ~60s while foregrounded.
CREATE OR REPLACE FUNCTION public.touch_last_seen()
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE users SET last_seen_at = now() WHERE user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.touch_last_seen() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_last_seen() TO authenticated;

-- Presence for a peer, respecting their privacy toggle.
--   state: online | recent | offline | hidden
CREATE OR REPLACE FUNCTION public.peer_presence(p_user_id UUID)
RETURNS TABLE (state TEXT, last_seen TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_seen TEXT;
    v_at   TIMESTAMPTZ;
    v_show BOOLEAN;
BEGIN
    SELECT u.last_seen_at, u.show_last_seen INTO v_at, v_show
      FROM users u WHERE u.user_id = p_user_id;

    IF v_show IS DISTINCT FROM TRUE OR v_at IS NULL THEN
        RETURN QUERY SELECT 'hidden'::TEXT, NULL::TIMESTAMPTZ;
    ELSIF v_at > now() - INTERVAL '70 seconds' THEN
        RETURN QUERY SELECT 'online'::TEXT, v_at;
    ELSIF v_at > now() - INTERVAL '5 minutes' THEN
        RETURN QUERY SELECT 'recent'::TEXT, v_at;
    ELSE
        RETURN QUERY SELECT 'offline'::TEXT, v_at;
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.peer_presence(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.peer_presence(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Delivered receipts
-- ---------------------------------------------------------------------------
ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;

-- Recipient stamps delivery when their client receives the room's messages
-- (chat open or realtime arrival). Idempotent.
CREATE OR REPLACE FUNCTION public.mark_room_delivered(p_room_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_count INT;
BEGIN
    IF v_me IS NULL THEN RETURN 0; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM chat_rooms
         WHERE room_id = p_room_id AND v_me IN (initiated_by, received_by)
    ) THEN
        RETURN 0;
    END IF;

    UPDATE chat_messages
       SET delivered_at = now()
     WHERE room_id = p_room_id
       AND sender_id <> v_me
       AND delivered_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.mark_room_delivered(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_room_delivered(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. _notify pluralization ("and 1 other", "and 2 others")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._notify(
    p_user         UUID,
    p_actor        UUID,
    p_kind         TEXT,
    p_subject_type TEXT,
    p_subject_id   UUID,
    p_action       TEXT,
    p_preview      TEXT DEFAULT NULL,
    p_window       INTERVAL DEFAULT NULL,
    p_extra        JSONB DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor_name TEXT;
    v_row        notifications%ROWTYPE;
    v_actors     JSONB;
    v_names      TEXT;
    v_count      INT;
    v_extra_n    INT;
BEGIN
    IF p_user IS NULL OR p_user = p_actor THEN RETURN; END IF;

    SELECT COALESCE(anonymous_pseudonym, 'Someone') INTO v_actor_name
      FROM users WHERE user_id = p_actor;
    v_actor_name := COALESCE(v_actor_name, 'Someone');

    IF p_window IS NOT NULL THEN
        SELECT * INTO v_row
          FROM notifications
         WHERE user_id = p_user
           AND kind = p_kind
           AND subject_id = p_subject_id
           AND NOT is_read
           AND updated_at > now() - p_window
         ORDER BY updated_at DESC
         LIMIT 1
         FOR UPDATE;

        IF FOUND THEN
            v_actors := COALESCE(v_row.payload->'actors', '[]'::jsonb);
            IF NOT v_actors @> to_jsonb(v_actor_name) THEN
                v_actors := to_jsonb(v_actor_name) || v_actors;
            END IF;
            v_actors := (
                SELECT COALESCE(jsonb_agg(x), '[]'::jsonb)
                  FROM (SELECT value AS x FROM jsonb_array_elements(v_actors) LIMIT 3) s
            );
            v_count := v_row.group_count + 1;
            v_names := (
                SELECT string_agg(value #>> '{}', ', ')
                  FROM jsonb_array_elements(v_actors)
            );
            v_extra_n := v_count - jsonb_array_length(v_actors);
            UPDATE notifications
               SET group_count = v_count,
                   actor_id    = p_actor,
                   updated_at  = now(),
                   payload     = v_row.payload || p_extra || jsonb_build_object(
                       'actors', v_actors,
                       'title',  CASE
                                     WHEN v_extra_n > 0 THEN
                                         v_names || ' and ' || v_extra_n::TEXT ||
                                         CASE WHEN v_extra_n = 1
                                              THEN ' other' ELSE ' others' END
                                     ELSE v_names
                                 END,
                       'body',   p_action ||
                                 COALESCE(' "' || left(p_preview, 60) || '"', ''),
                       'count',  v_count
                   )
             WHERE notification_id = v_row.notification_id;
            RETURN;
        END IF;
    END IF;

    INSERT INTO notifications (user_id, kind, actor_id, subject_type, subject_id, payload)
    VALUES (
        p_user, p_kind, p_actor, p_subject_type, p_subject_id,
        p_extra || jsonb_build_object(
            'title',  v_actor_name,
            'body',   p_action || COALESCE(' "' || left(p_preview, 60) || '"', ''),
            'actors', jsonb_build_array(v_actor_name),
            'count',  1
        )
    );
END $$;
