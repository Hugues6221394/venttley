-- 0053_space_summaries.sql
--
-- Cache layer for the Space summary assistant. Each Space gets one
-- summary per day, computed by the `space-summary-batch` edge
-- function and persisted here. The client reads from this table
-- directly. The current worker sees aggregate mood counts only.
--
-- Scale-oriented structure (capacity still requires sustained-load evidence):
--
--   * Read path: one round trip via the `latest_space_summary`
--     view, indexed by `space_id`. O(log n).
--   * Write path: a background batch worker processes up to N
--     spaces per tick. The unique constraint on (space_id, for_date)
--     makes concurrent workers safe — at worst they race on the
--     same row and the second insert is a no-op.
--   * Idempotency: callers re-running the same date are silently
--     skipped via `ON CONFLICT DO NOTHING`.
--   * Work guard: only Spaces with at least one new vent in the
--     last 24 hours are eligible (see view below).

CREATE TABLE IF NOT EXISTS public.space_summaries (
    summary_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    space_id          UUID NOT NULL REFERENCES public.spaces(space_id) ON DELETE CASCADE,
    for_date          DATE NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')::date,
    summary           TEXT,
    top_topics        JSONB NOT NULL DEFAULT '[]'::jsonb,
    suggested_prompt  TEXT,
    vents_analyzed    INT  NOT NULL DEFAULT 0,
    model             TEXT,
    generated_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (space_id, for_date)
);

CREATE INDEX IF NOT EXISTS space_summaries_date_idx
    ON public.space_summaries (for_date DESC);

CREATE INDEX IF NOT EXISTS space_summaries_space_recent_idx
    ON public.space_summaries (space_id, for_date DESC);

ALTER TABLE public.space_summaries ENABLE ROW LEVEL SECURITY;

-- Everyone in the tribe can read — RLS on Spaces already gates tribe
-- visibility at one layer up, and a Space summary doesn't leak any
-- author-attributable data. Writes are reserved to the service-role
-- key the edge function uses.
DROP POLICY IF EXISTS space_summaries_read ON public.space_summaries;
CREATE POLICY space_summaries_read ON public.space_summaries
    FOR SELECT TO authenticated USING (TRUE);

-- Latest summary per space, used by the client.
DROP VIEW IF EXISTS public.latest_space_summary;
CREATE VIEW public.latest_space_summary
WITH (security_invoker = TRUE) AS
SELECT DISTINCT ON (s.space_id)
       s.summary_id,
       s.space_id,
       s.for_date,
       s.summary,
       s.top_topics,
       s.suggested_prompt,
       s.vents_analyzed,
       s.model,
       s.generated_at,
       s.created_at
  FROM public.space_summaries s
 WHERE s.generated_at IS NOT NULL
 ORDER BY s.space_id, s.for_date DESC;

GRANT SELECT ON public.latest_space_summary TO authenticated, anon;

-- =====================================================================
-- Worker helper RPCs — invoked from the edge function.
-- =====================================================================

-- Pick up to N spaces that:
--   * Had at least one non-deleted vent in the last 24h
--   * Don't already have a summary row for today (UTC date)
-- The edge function reads aggregate mood counts for each row and UPSERTs a
-- deterministic summary into space_summaries. Vent bodies are not exported.
CREATE OR REPLACE FUNCTION public.pick_spaces_for_summary(p_batch INT DEFAULT 50)
RETURNS TABLE (
    space_id   UUID,
    tribe_id   UUID,
    name       TEXT,
    vents_today INT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT s.space_id,
           s.tribe_id,
           s.name,
           (
             SELECT COUNT(*) FROM posts p
              WHERE p.space_id = s.space_id
                AND p.deleted_at IS NULL
                AND p.created_at > now() - INTERVAL '24 hours'
           )::INT AS vents_today
      FROM spaces s
     WHERE s.archived_at IS NULL
       AND EXISTS (
           SELECT 1 FROM posts p
            WHERE p.space_id = s.space_id
              AND p.deleted_at IS NULL
              AND p.created_at > now() - INTERVAL '24 hours'
       )
       AND NOT EXISTS (
           SELECT 1 FROM space_summaries ss
            WHERE ss.space_id = s.space_id
              AND ss.for_date = (now() AT TIME ZONE 'UTC')::date
       )
     ORDER BY (
       SELECT COUNT(*) FROM posts p
        WHERE p.space_id = s.space_id
          AND p.deleted_at IS NULL
          AND p.created_at > now() - INTERVAL '24 hours'
     ) DESC
     LIMIT p_batch;
$$;

REVOKE ALL ON FUNCTION public.pick_spaces_for_summary(INT) FROM PUBLIC;
-- Only the service role calls this; no grant to authenticated.

-- Fetch the prompt material for one space: the latest N vents'
-- moods + content snippets. Kept compact so we stay inside the
-- token budget at scale.
CREATE OR REPLACE FUNCTION public.collect_space_vent_corpus(
    p_space_id UUID,
    p_limit    INT DEFAULT 25
)
RETURNS TABLE (
    post_id    UUID,
    content    TEXT,
    post_mood  TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p.post_id,
           LEFT(p.content, 280) AS content,
           p.post_mood::TEXT,
           p.created_at
      FROM posts p
     WHERE p.space_id = p_space_id
       AND p.deleted_at IS NULL
       AND p.created_at > now() - INTERVAL '24 hours'
     ORDER BY p.created_at DESC
     LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.collect_space_vent_corpus(UUID, INT) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
