-- Whispers feed: vary where the first page starts, so refresh brings something
-- different even when nothing new has been posted.
--
-- Shuffling the feed outright is not an option: `ORDER BY random()` cannot be
-- paged with a keyset cursor, and dropping back to OFFSET is what
-- 20260813200000 and its index exist to avoid. What CAN vary without touching
-- the ordering is the *entry point* — pick a random start inside a bounded
-- window of recent unheard whispers, then page forward exactly as before.
--
-- The window is bounded (WINDOW_ROWS below) for two reasons. It keeps the OFFSET
-- small enough to be free — the pathology of OFFSET is unbounded depth, not a
-- hundred rows — and it keeps the entry point inside "recent", so a refresh
-- cannot drop someone into content from months ago.
--
-- Offset zero remains a possible draw, so the newest whispers still surface
-- regularly rather than being permanently skipped past.
--
-- Now VOLATILE rather than STABLE: it calls random(), and a STABLE function's
-- result may be cached within a statement, which would defeat the point.

CREATE OR REPLACE FUNCTION public.list_unheard_whispers(
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
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_unheard_whispers(INT, TEXT, TIMESTAMPTZ, UUID)
    TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
