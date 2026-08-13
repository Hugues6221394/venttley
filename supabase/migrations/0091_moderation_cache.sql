-- 0091_moderation_cache.sql
-- Server-owned advisory moderation verdict cache. Production does not use an
-- off-platform text classifier; this table remains available for an approved
-- in-boundary classifier and is never client-writable.
--
-- CRITICAL: this table has NO RLS policies and NO grants to authenticated/anon,
-- so it is reachable ONLY by the service role — i.e. the `moderate` edge
-- function. A client-writable verdict cache would be POISONABLE (a modified app
-- could cache harmful content as 'safe'); keeping writes server-side makes the
-- verdict trustworthy.

CREATE TABLE IF NOT EXISTS public.moderation_verdicts (
    content_hash TEXT PRIMARY KEY,           -- sha256 hex of normalized text
    verdict      TEXT NOT NULL CHECK (verdict IN ('safe','warn','block')),
    categories   TEXT[] NOT NULL DEFAULT '{}',
    reason       TEXT,
    crisis       BOOLEAN NOT NULL DEFAULT false,
    hit_count    INT NOT NULL DEFAULT 1,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_moderation_verdicts_last_seen
    ON public.moderation_verdicts (last_seen_at);

-- RLS on with zero policies = deny all for anon/authenticated. Service role
-- bypasses RLS, so only the edge function can read/write. Explicitly revoke to
-- be safe against any default grant.
ALTER TABLE public.moderation_verdicts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderation_verdicts FROM anon, authenticated;

-- Housekeeping: drop entries unused for 30 days so the cache reflects the
-- current classifier and stays small.
CREATE OR REPLACE FUNCTION public.purge_stale_moderation_verdicts()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
    DELETE FROM public.moderation_verdicts
     WHERE last_seen_at < now() - interval '30 days';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.unschedule('purge_moderation_verdicts')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge_moderation_verdicts');
SELECT cron.schedule('purge_moderation_verdicts', '40 3 * * *',
                     $$ SELECT public.purge_stale_moderation_verdicts(); $$);

NOTIFY pgrst, 'reload schema';
