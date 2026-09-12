-- Mail was queueing and never sending, and nothing anywhere said so.
--
-- Measured, not guessed. Calling the dispatcher by hand:
--
--     POST /functions/v1/email-dispatcher
--     {"ok":true,"claimed":4,"sent":4,"skipped":0,"retried":0,"failed":0}
--
-- Four verification codes had been sitting in email_outbox as 'queued'. Resend
-- was fine, the dispatcher was fine, the recipient's inbox was fine. Nothing
-- was INVOKING the dispatcher. 0077 schedules 'email_dispatch_every_minute' to
-- do exactly that, and it was either never applied to this database or is
-- sitting there with active = false — 0077's own trailing comment suggests how:
--
--     update cron.job set active = false where jobname = 'email_dispatch_every_minute';
--
-- offered as a way to pause things while Resend was unconfigured.
--
-- Either way the observable behaviour was the worst possible shape: a person
-- taps "send code", the app truthfully says a code is on its way, a row is
-- correctly written with the right recipient, and then nothing happens for
-- ever. No error, no retry, no alert, no log line. Precisely the silent
-- failure class as `?? 'clean'`, `DEFAULT 'clean'`, terminal 'skipped', and
-- media_status missing from a feed's RETURNS TABLE.
--
-- Two parts here, and the second matters more than the first.
--
--   1. Reschedule the job, and force active = true. Re-running 0077 alone
--      would not have fixed an inactive job: cron.schedule on an existing
--      jobname updates the command, not the active flag.
--
--   2. A watchdog. Fixing this instance is not the same as being able to
--      notice the next one. Mail that has been queued and unsent for longer
--      than a few minutes is now recorded as a platform-level security event,
--      so the failure has a voice even when nobody is looking at the outbox.
--
-- The migration deliberately RAISEs if the vault secret is missing rather than
-- scheduling a job that would post a null header and be rejected every minute
-- in silence. A migration that fails loudly is worth far more than one that
-- succeeds and leaves the pipeline dead.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net;

-- ---------------------------------------------------------------------------
-- 1. The secret has to exist before scheduling anything that depends on it
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'account_purge_cron_secret';

  IF v_secret IS NULL OR length(btrim(v_secret)) = 0 THEN
    RAISE EXCEPTION
      'vault secret account_purge_cron_secret is missing or empty. The email dispatch job authenticates with it; scheduling without it would post a null x-cron-secret header and be rejected every minute with nothing to show for it. Add the secret, then re-run this migration.';
  END IF;

  RAISE NOTICE 'vault secret present, length %', length(v_secret);
END $$;

-- ---------------------------------------------------------------------------
-- 2. Reschedule, and make it active
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_jobid  INT;
  v_active BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION 'pg_cron is not installed. Without it no mail is ever sent, so this cannot be skipped quietly.';
  END IF;

  SELECT jobid, active INTO v_jobid, v_active
    FROM cron.job WHERE jobname = 'email_dispatch_every_minute';

  IF v_jobid IS NULL THEN
    RAISE NOTICE 'email_dispatch_every_minute did not exist — 0077 was never applied here. Creating it.';
  ELSE
    RAISE NOTICE 'email_dispatch_every_minute existed with active = %. Recreating.', v_active;
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'email_dispatch_every_minute',
    '* * * * *',
    $cron$
    SELECT net.http_post(
      url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/email-dispatcher',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'x-cron-secret', (
          SELECT decrypted_secret
            FROM vault.decrypted_secrets
           WHERE name = 'account_purge_cron_secret'
        )
      ),
      body    := '{}'::jsonb
    );
    $cron$
  );

  -- Activation, without touching cron.job directly.
  --
  -- cron.job is owned by supabase_admin: the migration role can SELECT it but
  -- not UPDATE it, and trying returns 42501 and aborts the whole migration.
  --
  -- The unschedule/schedule pair above is what actually fixes a paused job —
  -- cron.job.active defaults to true, so a freshly created job is active even
  -- if the one it replaced was not. cron.alter_job is belt and braces for any
  -- pg_cron version where that is not the case, and it is wrapped because it
  -- is a nice-to-have: failing the migration over it would leave the pipeline
  -- broken for the sake of a redundant call.
  BEGIN
    PERFORM cron.alter_job(
      (SELECT jobid FROM cron.job WHERE jobname = 'email_dispatch_every_minute'),
      active := TRUE
    );
  EXCEPTION WHEN insufficient_privilege OR undefined_function THEN
    RAISE NOTICE 'cron.alter_job unavailable; relying on the fresh schedule being active';
  END;

  SELECT active INTO v_active FROM cron.job
   WHERE jobname = 'email_dispatch_every_minute';
  IF v_active IS NOT TRUE THEN
    RAISE EXCEPTION
      'email_dispatch_every_minute is still not active. Nothing will be sent. Run: select cron.alter_job((select jobid from cron.job where jobname = ''email_dispatch_every_minute''), active := true);';
  END IF;

  RAISE NOTICE 'email_dispatch_every_minute scheduled and active';
END $$;

-- ---------------------------------------------------------------------------
-- 3. The watchdog: give a stalled queue a voice
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.email_outbox_health()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'queued',        count(*) FILTER (WHERE status = 'queued'),
    'sending',       count(*) FILTER (WHERE status = 'sending'),
    'failed',        count(*) FILTER (WHERE status = 'failed'),
    'skipped',       count(*) FILTER (WHERE status = 'skipped'),
    'sent',          count(*) FILTER (WHERE status = 'sent'),
    -- The number that matters. Anything beyond a couple of minutes means the
    -- pipeline is not moving, whatever the individual row statuses say.
    'oldest_queued_seconds',
      COALESCE(
        EXTRACT(EPOCH FROM (now() - min(created_at)
          FILTER (WHERE status = 'queued')))::INT,
        0
      )
  )
  FROM public.email_outbox;
$$;

COMMENT ON FUNCTION public.email_outbox_health() IS
  'Queue depth and the age of the oldest unsent message. oldest_queued_seconds above ~300 means mail is not being dispatched at all.';

REVOKE ALL ON FUNCTION public.email_outbox_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.email_outbox_health() TO service_role;

-- security_events is the wrong home for this: user_id is NOT NULL and its kind
-- CHECK enumerates per-account events. A stalled mail queue belongs to nobody
-- in particular, and widening a security constraint to fit an ops alarm would
-- be the wrong trade. Its own table also means alerts can be resolved without
-- touching anyone's security history.
CREATE TABLE IF NOT EXISTS public.platform_alerts (
  alert_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subsystem    TEXT NOT NULL,
  severity     TEXT NOT NULL DEFAULT 'critical'
                 CHECK (severity IN ('info', 'warning', 'critical')),
  problem      TEXT NOT NULL,
  context      JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at  TIMESTAMPTZ
);

COMMENT ON TABLE public.platform_alerts IS
  'Infrastructure problems that belong to the platform rather than to a user. Written by watchdog cron jobs so a silent pipeline failure leaves a trace.';

CREATE INDEX IF NOT EXISTS platform_alerts_open_idx
  ON public.platform_alerts (subsystem, created_at DESC)
  WHERE resolved_at IS NULL;

ALTER TABLE public.platform_alerts ENABLE ROW LEVEL SECURITY;

-- No client policy at all: nothing here is for an end user, and an empty
-- policy set with RLS on means authenticated and anon see nothing.
REVOKE ALL ON TABLE public.platform_alerts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.platform_alerts TO service_role;

CREATE OR REPLACE FUNCTION public.check_email_dispatch_stalled()
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_age     INT;
  v_backlog INT;
  v_recent  BOOLEAN;
BEGIN
  SELECT COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at)))::INT, 0),
         count(*)
    INTO v_age, v_backlog
    FROM public.email_outbox
   WHERE status = 'queued';

  -- Ten minutes. Long enough that a slow Resend call or a single missed cron
  -- tick does not cry wolf, short enough that somebody waiting on a login code
  -- has not yet given up on the app.
  IF v_backlog = 0 OR v_age < 600 THEN
    RETURN 0;
  END IF;

  -- One alert per hour, not one per minute. An alert that repeats sixty times
  -- an hour is an alert nobody reads, and the backlog is already recorded in
  -- the payload for whoever looks.
  SELECT EXISTS (
    SELECT 1 FROM public.platform_alerts
     WHERE subsystem = 'email_dispatch'
       AND created_at > now() - INTERVAL '1 hour'
  ) INTO v_recent;
  IF v_recent THEN RETURN 0; END IF;

  INSERT INTO public.platform_alerts (subsystem, severity, problem, context)
  VALUES (
    'email_dispatch', 'critical', 'mail queued but not dispatched',
    jsonb_build_object(
      'oldest_queued_seconds', v_age,
      'backlog', v_backlog,
      'likely_cause', 'the email_dispatch_every_minute cron job is missing, inactive, or its vault secret lookup returns null',
      'check', 'select jobname, active from cron.job'
    )
  );

  RETURN v_backlog;
END $$;

COMMENT ON FUNCTION public.check_email_dispatch_stalled() IS
  'Records a critical platform_alert when mail has been queued and undispatched for over ten minutes. Exists because this failure was previously completely silent: verification codes queued correctly and were never sent, with no error anywhere.';

REVOKE ALL ON FUNCTION public.check_email_dispatch_stalled()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_email_dispatch_stalled() TO service_role;

DO $$
DECLARE v_jobid INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RETURN;
  END IF;

  SELECT jobid INTO v_jobid FROM cron.job
   WHERE jobname = 'email_dispatch_watchdog';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  -- Every five minutes is plenty for a ten-minute threshold, and the query it
  -- runs is a single indexed aggregate over a small table.
  PERFORM cron.schedule(
    'email_dispatch_watchdog',
    '*/5 * * * *',
    $cron$ SELECT public.check_email_dispatch_stalled(); $cron$
  );
END $$;

COMMIT;

-- Confirm both jobs, right here, so applying this migration answers the
-- question rather than requiring a follow-up query.
SELECT jobname, schedule, active
  FROM cron.job
 WHERE jobname IN ('email_dispatch_every_minute', 'email_dispatch_watchdog')
 ORDER BY jobname;

SELECT public.record_migration(
  '20260915090000', 'email_dispatch_watchdog'
);

NOTIFY pgrst, 'reload schema';
