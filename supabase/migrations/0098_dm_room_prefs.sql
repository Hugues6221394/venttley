-- 0098_dm_room_prefs.sql
-- Per-user, per-room DM preferences powering the Instagram-style chat options
-- sheet: mute, a nickname for the peer, disappearing-message TTL, and a chat
-- theme. Keyed by (room_id, user_id) so each participant has their own view
-- (your nickname/theme/mute are yours alone). Block + report already exist
-- (block_user / reportChat); this only covers the new prefs.

CREATE TABLE IF NOT EXISTS public.dm_room_prefs (
    room_id              UUID NOT NULL REFERENCES public.chat_rooms(room_id) ON DELETE CASCADE,
    user_id              UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    muted                BOOLEAN NOT NULL DEFAULT FALSE,
    peer_nickname        TEXT CHECK (peer_nickname IS NULL OR char_length(peer_nickname) <= 40),
    disappearing_seconds INT NOT NULL DEFAULT 0,   -- 0 = off
    theme                TEXT NOT NULL DEFAULT 'default',
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (room_id, user_id)
);

ALTER TABLE public.dm_room_prefs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "dm prefs self" ON public.dm_room_prefs;
CREATE POLICY "dm prefs self"
    ON public.dm_room_prefs FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.dm_room_prefs TO authenticated;

-- Upsert the caller's prefs for a room. Only the provided (non-null) fields
-- change; verifies the caller participates in the room.
CREATE OR REPLACE FUNCTION public.set_dm_room_pref(
    p_room_id            UUID,
    p_muted              BOOLEAN DEFAULT NULL,
    p_peer_nickname      TEXT    DEFAULT NULL,
    p_clear_nickname     BOOLEAN DEFAULT FALSE,
    p_disappearing       INT     DEFAULT NULL,
    p_theme              TEXT    DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.chat_rooms r
         WHERE r.room_id = p_room_id
           AND (r.initiated_by = v_me OR r.received_by = v_me)
    ) THEN
        RAISE EXCEPTION 'not a room participant';
    END IF;

    INSERT INTO public.dm_room_prefs (room_id, user_id) VALUES (p_room_id, v_me)
    ON CONFLICT (room_id, user_id) DO NOTHING;

    UPDATE public.dm_room_prefs
       SET muted                = COALESCE(p_muted, muted),
           peer_nickname        = CASE WHEN p_clear_nickname THEN NULL
                                       ELSE COALESCE(p_peer_nickname, peer_nickname) END,
           disappearing_seconds = COALESCE(p_disappearing, disappearing_seconds),
           theme                = COALESCE(p_theme, theme),
           updated_at           = now()
     WHERE room_id = p_room_id AND user_id = v_me;
END $$;

GRANT EXECUTE ON FUNCTION public.set_dm_room_pref(UUID, BOOLEAN, TEXT, BOOLEAN, INT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
