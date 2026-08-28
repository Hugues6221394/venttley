-- Whispers feed: skip what this listener has already heard.
--
-- Refresh could not bring anything new. Ordering was `created_at DESC` and
-- nothing else, so pulling to refresh returned an identical list unless somebody
-- had posted in the meantime. whisper_listens (0073) already records every
-- distinct listener, so the cheapest real improvement is to stop showing people
-- whispers they have finished listening to — no ranking model, nothing to tune,
-- and explainable to a user in one sentence.
--
-- Deliberately NOT engagement-weighted. Ordering trauma and self-harm-adjacent
-- disclosures by plays_count would select for whatever provokes the most
-- reaction, which on this platform means amplifying its most distressing
-- content to exactly the people least able to handle it. Recency is honest and
-- cannot quietly become something else.
--
-- SECURITY INVOKER on purpose. whispers_feed is itself `security_invoker = true`,
-- so the caller's RLS keeps applying to whispers; a SECURITY DEFINER wrapper
-- would run the view as the owner and bypass it. whisper_listens is readable
-- under its own policy (0073, `USING (true)`), so no elevation is needed.

-- ---------------------------------------------------------------------------
-- Keyset support. The client seeks on (created_at, whisper_id); without a
-- matching index that ordering is a sort over the whole table, which defeats
-- the point of moving off OFFSET.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS whispers_created_keyset_idx
    ON public.whispers (created_at DESC, whisper_id DESC)
    WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION public.list_unheard_whispers(
    p_limit             INT         DEFAULT 12,
    p_category          TEXT        DEFAULT NULL,
    p_before_created_at TIMESTAMPTZ DEFAULT NULL,
    p_before_whisper_id UUID        DEFAULT NULL
)
RETURNS SETOF public.whispers_feed
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    -- Guard the page size so a caller cannot ask for the table.
    IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 12; END IF;
    IF p_limit > 50 THEN p_limit := 50; END IF;

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
     LIMIT p_limit;

    -- Never show an empty feed. Someone who has heard everything recent must not
    -- open Whispers to nothing — on a support platform that reads as
    -- abandonment, not as "you are caught up".
    --
    -- Only on the first page. Running out mid-scroll is a genuine end of list,
    -- and re-showing heard whispers there would loop the feed forever.
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
-- anon is granted too: signed-out callers have no auth.uid(), so the listener
-- filter is skipped and they get the plain recency feed.
GRANT EXECUTE ON FUNCTION public.list_unheard_whispers(INT, TEXT, TIMESTAMPTZ, UUID)
    TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
