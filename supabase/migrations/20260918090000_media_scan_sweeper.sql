-- Nothing was retrying an image scan, so a missed scan veiled a photo for ever.
--
-- The scan is dispatched by the client, immediately after upload:
--
--     await _client.functions.invoke('media-scan', body: {...});   // best effort
--
-- and the catch block only logs. That is the right shape for the happy path
-- and completely undefended everywhere else. If the app is killed, put in the
-- background, or loses signal in the second after posting; if the classifier
-- on Render was asleep and the call timed out; if the function was briefly
-- erroring — the scan never happens, and media_status stays 'pending'.
--
-- Pending means veiled, which is the correct and safe failure. But it is also
-- permanent, because nothing ever tries again. The person sees "Checking this
-- image…" for ever on an ordinary holiday photo, with no error and nothing to
-- retry. Meanwhile media_scan_jobs already has leases and an attempts cap of 8,
-- built to support retries that were never actually driven by anything.
--
-- So: a sweeper. Every minute, find media that has been pending longer than a
-- moment and is not currently being scanned, and ask media-scan to look at it
-- again. It authenticates with the cron secret, and the function takes the
-- author from the row rather than from a token it cannot have.
--
-- WHAT IT WILL NOT DO
--
-- It never writes a verdict, and there is no attempt count at which media
-- becomes clean. After 8 attempts the row stays pending — veiled — and raises
-- a platform_alert instead. Giving up in the direction of "probably fine" is
-- how an unscanned image ends up on a feed, and this app's whole reason for
-- scanning is that some of those images will be pornography posted where
-- thirteen-year-olds can see it. The only safe direction to fail is closed.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.sweep_media_scans(p_limit INT DEFAULT 20)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_secret TEXT;
  v_row    RECORD;
  v_sent   INT := 0;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'account_purge_cron_secret';
  IF v_secret IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    -- Both kinds in one pass, so one cron job covers everything that can carry
    -- an image. Ordered oldest first: the person who has been staring at a
    -- veiled photo longest gets served first.
    SELECT 'post' AS kind, p.post_id AS content_id, p.created_at
      FROM public.posts AS p
     WHERE p.media_status = 'pending'
       AND p.deleted_at IS NULL
       -- A grace period, so the sweeper does not race the client's own call
       -- for every single upload and burn an attempt doing it.
       AND p.created_at < now() - INTERVAL '90 seconds'
       AND NOT EXISTS (
         SELECT 1 FROM public.media_scan_jobs AS j
          WHERE j.kind = 'post' AND j.content_id = p.post_id
            AND (
              -- Someone is scanning it right now.
              (j.completed_at IS NULL AND j.lease_expires_at > now())
              -- Or it is finished, or it has exhausted its attempts and is
              -- now a case for a human rather than another retry.
              OR j.completed_at IS NOT NULL
              OR j.attempts >= 8
            )
       )
    UNION ALL
    SELECT 'whisper', w.whisper_id, w.created_at
      FROM public.whispers AS w
     WHERE w.media_status = 'pending'
       AND w.deleted_at IS NULL
       AND w.created_at < now() - INTERVAL '90 seconds'
       AND NOT EXISTS (
         SELECT 1 FROM public.media_scan_jobs AS j
          WHERE j.kind = 'whisper' AND j.content_id = w.whisper_id
            AND (
              (j.completed_at IS NULL AND j.lease_expires_at > now())
              OR j.completed_at IS NOT NULL
              OR j.attempts >= 8
            )
       )
     ORDER BY 3
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 200)
  LOOP
    PERFORM net.http_post(
      url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/media-scan',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'x-cron-secret', v_secret
      ),
      body    := jsonb_build_object('kind', v_row.kind, 'id', v_row.content_id)
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END $$;

COMMENT ON FUNCTION public.sweep_media_scans(INT) IS
  'Re-dispatches image scans for media stuck pending. Never writes a verdict and never gives up towards clean — exhausted media stays veiled and raises an alert.';

REVOKE ALL ON FUNCTION public.sweep_media_scans(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sweep_media_scans(INT) TO service_role;

-- ---------------------------------------------------------------------------
-- Media that has run out of attempts is a human's problem, not a silent veil
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.check_media_scan_stalled()
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_stuck  INT;
  v_oldest INT;
  v_recent BOOLEAN;
BEGIN
  -- Pending for over an hour is not a slow scan. Either every attempt failed,
  -- or nothing ever picked it up.
  SELECT count(*),
         COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at)))::INT, 0)
    INTO v_stuck, v_oldest
    FROM (
      SELECT p.created_at FROM public.posts AS p
       WHERE p.media_status = 'pending' AND p.deleted_at IS NULL
         AND p.created_at < now() - INTERVAL '1 hour'
      UNION ALL
      SELECT w.created_at FROM public.whispers AS w
       WHERE w.media_status = 'pending' AND w.deleted_at IS NULL
         AND w.created_at < now() - INTERVAL '1 hour'
    ) AS stuck;

  IF v_stuck = 0 THEN RETURN 0; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.platform_alerts
     WHERE subsystem = 'media_scan'
       AND created_at > now() - INTERVAL '1 hour'
  ) INTO v_recent;
  IF v_recent THEN RETURN 0; END IF;

  INSERT INTO public.platform_alerts (subsystem, severity, problem, context)
  VALUES (
    'media_scan', 'critical',
    'images stuck pending — they are veiled, and nobody can see their own photo',
    jsonb_build_object(
      'stuck', v_stuck,
      'oldest_seconds', v_oldest,
      'likely_cause', 'the NSFW classifier is unreachable, MEDIA_SCAN_ENABLED is off, or CRON_SECRET is not set on the media-scan function',
      'check', 'select public.sweep_media_scans(1)'
    )
  );

  RETURN v_stuck;
END $$;

COMMENT ON FUNCTION public.check_media_scan_stalled() IS
  'Alerts when images have been pending over an hour. Veiled is safe; veiled for ever with nobody told is not.';

REVOKE ALL ON FUNCTION public.check_media_scan_stalled()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_media_scan_stalled() TO service_role;

-- Supporting indexes. Both sweep and alert filter on exactly this predicate,
-- and without them each run is a sequential scan of every post ever written.
CREATE INDEX IF NOT EXISTS posts_media_pending_idx
  ON public.posts (created_at)
  WHERE media_status = 'pending' AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS whispers_media_pending_idx
  ON public.whispers (created_at)
  WHERE media_status = 'pending' AND deleted_at IS NULL;

COMMIT;

DO $$
DECLARE v_jobid INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION 'pg_cron is not installed; media scans would never be retried.';
  END IF;

  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'media_scan_sweep';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;
  PERFORM cron.schedule(
    'media_scan_sweep', '* * * * *',
    $cron$ SELECT public.sweep_media_scans(20); $cron$
  );

  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'media_scan_watchdog';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;
  PERFORM cron.schedule(
    'media_scan_watchdog', '*/15 * * * *',
    $cron$ SELECT public.check_media_scan_stalled(); $cron$
  );
END $$;

SELECT jobname, schedule, active FROM cron.job
 WHERE jobname IN ('media_scan_sweep', 'media_scan_watchdog')
 ORDER BY jobname;

SELECT public.record_migration('20260918090000', 'media_scan_sweeper');

NOTIFY pgrst, 'reload schema';
