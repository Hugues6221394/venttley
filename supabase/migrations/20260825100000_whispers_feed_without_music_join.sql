-- Undo the music_tracks join I put on whispers_feed.
--
-- Joining it looked tidier than hydrating client-side and was wrong twice
-- over. whispers_feed is security_invoker, so the join made every whisper read
-- evaluate music_tracks' RLS, which calls music_enabled_for_me and the private
-- feature-flag helper beneath it: a per-row feature-flag check on the busiest
-- whisper query. Worse, it broke list_unheard_whispers outright with 42501
-- "permission denied for function feature_enabled_for", so the already-heard
-- filter silently stopped working and every listener started seeing whispers
-- they had finished.
--
-- Track title, artist and preview are hydrated by the client through
-- music_tracks_by_ids, which is SECURITY DEFINER and batched — the same route
-- posts have always taken.
--
-- This has to DROP rather than CREATE OR REPLACE: replacing a view can add
-- columns but never remove them, and the deployed shape has three to remove.
-- list_unheard_whispers returns SETOF whispers_feed so it must go first and
-- come back after; it is the view's only dependent.

DROP FUNCTION IF EXISTS public.list_unheard_whispers(
  INT, TEXT, TIMESTAMPTZ, UUID
);
DROP VIEW IF EXISTS public.whispers_feed;

CREATE VIEW public.whispers_feed WITH (security_invoker = true) AS
SELECT
    w.whisper_id,
    w.author_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')      AS author_avatar_seed,
    CASE WHEN w.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
                                                                AS author_profile_photo_url,
    COALESCE(u.is_verified, false) AS author_is_verified,
    w.persona_id,
    w.audio_url,
    w.audio_duration_seconds,
    w.background_image_url,
    w.voice_filter,
    w.category_name,
    w.title,
    w.description,
    w.plays_count,
    w.likes_count,
    w.comments_count,
    w.crisis_level,
    w.created_at,
    w.deleted_at,
    w.media_status,
    -- No music_duration_ms here on purpose: 20260816130000 leaves it off
    -- because a bed loops for however long the whisper runs, so a duration
    -- would be meaningless. Selecting it would fail — the column does not exist.
    -- The reference only. Track title, artist and preview are hydrated by the
    -- client through music_tracks_by_ids, exactly as posts already do.
    --
    -- Joining public.music_tracks here instead looked tidier and was wrong:
    -- whispers_feed is security_invoker, so the join makes every whisper read
    -- evaluate that table's RLS, which calls music_enabled_for_me and the
    -- private feature-flag helper underneath it. That turned a hot feed query
    -- into a per-row feature-flag check and made list_unheard_whispers fail
    -- outright with 42501, silently dropping the whole already-heard filter.
    w.music_track_id,
    w.music_start_ms,
    w.music_volume
FROM public.whispers w
LEFT JOIN public.users    u  ON u.user_id     = w.author_id
LEFT JOIN public.personas pr ON pr.persona_id = w.persona_id
                            AND pr.deleted_at IS NULL;

-- DROP discards privileges, so restate them.
GRANT SELECT ON public.whispers_feed TO anon, authenticated;

CREATE FUNCTION public.list_unheard_whispers(
    p_limit             INT         DEFAULT 12,
    p_category          TEXT        DEFAULT NULL,
    p_before_created_at TIMESTAMPTZ DEFAULT NULL,
    p_before_whisper_id UUID        DEFAULT NULL
)
RETURNS SETOF public.whispers_feed
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_me     UUID := auth.uid();
    v_window CONSTANT INT := 120;   -- ten pages of recent whispers to draw from
    v_pool   INT;
    v_offset INT := 0;
BEGIN
    IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 12; END IF;
    IF p_limit > 50 THEN p_limit := 50; END IF;

    -- Only the first page is randomised. Mid-scroll must stay strictly
    -- sequential or the same whisper reappears a few swipes later.
    IF p_before_created_at IS NULL THEN
        SELECT count(*) INTO v_pool
          FROM (
            SELECT 1
              FROM public.whispers_feed f
             WHERE f.deleted_at IS NULL
               AND (p_category IS NULL OR f.category_name = p_category)
               AND (
                     v_me IS NULL
                     OR NOT EXISTS (
                          SELECT 1
                            FROM public.whisper_listens l
                           WHERE l.whisper_id  = f.whisper_id
                             AND l.listener_id = v_me
                        )
                   )
             ORDER BY f.created_at DESC, f.whisper_id DESC
             LIMIT v_window
          ) AS recent;

        IF v_pool > p_limit THEN
            v_offset := floor(random() * (v_pool - p_limit + 1))::INT;
        END IF;
    END IF;

    RETURN QUERY
    SELECT f.*
      FROM public.whispers_feed f
     WHERE f.deleted_at IS NULL
       AND (p_category IS NULL OR f.category_name = p_category)
       AND (
             p_before_created_at IS NULL
             OR f.created_at < p_before_created_at
             OR (
                  f.created_at = p_before_created_at
                  AND p_before_whisper_id IS NOT NULL
                  AND f.whisper_id < p_before_whisper_id
                )
           )
       AND (
             v_me IS NULL
             OR NOT EXISTS (
                  SELECT 1
                    FROM public.whisper_listens l
                   WHERE l.whisper_id  = f.whisper_id
                     AND l.listener_id = v_me
                )
           )
     ORDER BY f.created_at DESC, f.whisper_id DESC
     OFFSET v_offset
     LIMIT p_limit;

    -- Never show an empty feed. Someone who has heard everything recent must not
    -- open Whispers to nothing — on a support platform that reads as
    -- abandonment, not as "you are caught up".
    --
    -- First page only. Running out mid-scroll is a genuine end of list, and
    -- re-showing heard whispers there would loop the feed forever.
    IF NOT FOUND AND p_before_created_at IS NULL THEN
        RETURN QUERY
        SELECT f.*
          FROM public.whispers_feed f
         WHERE f.deleted_at IS NULL
           AND (p_category IS NULL OR f.category_name = p_category)
         ORDER BY f.created_at DESC, f.whisper_id DESC
         LIMIT p_limit;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.list_unheard_whispers(INT, TEXT, TIMESTAMPTZ, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_unheard_whispers(INT, TEXT, TIMESTAMPTZ, UUID)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
