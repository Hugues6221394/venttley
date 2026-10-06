-- External heartbeat for the background workers.
--
-- Every minute pg_cron calls the monitor-heartbeat edge function, which asks
-- public.platform_heartbeat_status() whether the platform's scheduled work is
-- on time and then pings the external uptime monitor (HEARTBEAT_URL, an edge
-- secret) -- or its /fail endpoint with the failing check names.
--
-- The monitor alerts when pings stop, so a dead database, scheduler, pg_net
-- worker or edge function is caught by silence; this function only has to
-- catch the cases where everything is up but a job is late or failing.
--
-- The status carries job names and fixed codes only: no member data, SQL
-- error text or credentials leave the database.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net;

DO $$
DECLARE v_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets WHERE name = 'account_purge_cron_secret';
  IF v_secret IS NULL OR length(btrim(v_secret)) = 0 THEN
    -- Empty database: the chain is being replayed from zero (CI, a new
    -- laptop, a rebuild) and no secret can exist yet because nothing has been
    -- deployed. Refusing there makes the chain unreplayable, which is the one
    -- property the migration-replay job exists to check. On a database with
    -- people in it the refusal stands, because there it means somebody
    -- deployed without configuring the secret.
    IF EXISTS (SELECT 1 FROM auth.users LIMIT 1) THEN
      RAISE EXCEPTION 'vault secret account_purge_cron_secret is missing; the heartbeat job authenticates with it.';
    END IF;

    PERFORM vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'account_purge_cron_secret',
      'Placeholder minted while replaying migrations on an empty database.'
    );
    RAISE WARNING
      'account_purge_cron_secret was missing on an empty database, so a placeholder was minted to keep the migration chain replayable.';
  END IF;
END $$;

-- Expected minutes between runs for the schedule shapes this project uses.
-- NULL means "unknown shape": such a job is checked for failures, not lateness.
CREATE OR REPLACE FUNCTION private.cron_interval_minutes(p_schedule TEXT)
RETURNS INT
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_schedule = '* * * * *' THEN 1
    WHEN p_schedule ~ '^\*/[0-9]+ \* \* \* \*$'
      THEN substring(p_schedule FROM '^\*/([0-9]+)')::INT
    WHEN p_schedule ~ '^[0-9]+ \* \* \* \*$' THEN 60
    WHEN p_schedule ~ '^[0-9]+ [0-9]+ \* \* \*$' THEN 1440
  END;
$$;

-- Problem code for one job, or NULL when it is healthy.
CREATE OR REPLACE FUNCTION private.cron_job_problem(
  p_every INT, p_last_start TIMESTAMPTZ, p_last_success TIMESTAMPTZ,
  p_last_status TEXT, p_now TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_last_status = 'failed' AND (
           p_every IS NULL OR p_every >= 60
           -- Frequent jobs get a few ticks to recover from a transient error.
           OR p_last_success IS NULL
           OR p_last_success < p_now - make_interval(mins => p_every * 3 + 3)
         ) THEN 'failed'
    WHEN p_every IS NULL THEN NULL
    WHEN p_last_start IS NULL THEN CASE WHEN p_every < 60 THEN 'not_running' END
    WHEN p_last_start < p_now - make_interval(mins => p_every * 2 + 3) THEN 'late'
  END;
$$;

CREATE OR REPLACE FUNCTION public.platform_heartbeat_status()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  problems TEXT[] := '{}';
  checked  INT := 0;
  r        RECORD;
  problem  TEXT;
  mail_age INT;
BEGIN
  -- job_run_details is never purged, so read only the newest rows through its
  -- primary key (runid grows with time). 40,000 rows is over two days at the
  -- current schedule, enough to see the last run of every daily job.
  FOR r IN
    WITH recent AS (
      SELECT d.jobid, d.status, d.start_time
        FROM cron.job_run_details d
       ORDER BY d.runid DESC
       LIMIT 40000
    )
    SELECT j.jobname,
           private.cron_interval_minutes(j.schedule) AS every,
           max(x.start_time) AS last_start,
           max(x.start_time) FILTER (WHERE x.status = 'succeeded') AS last_success,
           (SELECT y.status FROM recent y
             WHERE y.jobid = j.jobid AND y.status IN ('succeeded', 'failed')
             ORDER BY y.start_time DESC LIMIT 1) AS last_status
      FROM cron.job j
      LEFT JOIN recent x ON x.jobid = j.jobid
     WHERE j.active AND j.jobname <> 'monitor_heartbeat'
     GROUP BY j.jobid, j.jobname, j.schedule
  LOOP
    checked := checked + 1;
    problem := private.cron_job_problem(r.every, r.last_start, r.last_success, r.last_status, now());
    IF problem IS NOT NULL THEN
      problems := problems || (r.jobname || ':' || problem);
    END IF;
  END LOOP;

  SELECT EXTRACT(EPOCH FROM now() - min(created_at))::INT INTO mail_age
    FROM public.email_outbox WHERE status = 'queued';
  IF mail_age > 600 THEN
    problems := problems || 'email_outbox:stalled'::TEXT;
  END IF;

  RETURN jsonb_build_object(
    'healthy', cardinality(problems) = 0,
    'jobs_checked', checked,
    'problems', to_jsonb(problems),
    'measured_at', now()
  );
END;
$$;

COMMENT ON FUNCTION public.platform_heartbeat_status() IS
  'Background-worker health for the external heartbeat: late or failing active cron jobs and a stalled email outbox. Fixed codes only.';

REVOKE ALL ON FUNCTION private.cron_interval_minutes(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.cron_job_problem(INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.platform_heartbeat_status() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.platform_heartbeat_status() TO service_role;

DO $$
DECLARE v_jobid BIGINT;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'monitor_heartbeat';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;
  PERFORM cron.schedule(
    'monitor_heartbeat',
    '* * * * *',
    $cron$
    SELECT net.http_post(
      url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/monitor-heartbeat',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'x-cron-secret', (
          SELECT decrypted_secret FROM vault.decrypted_secrets
           WHERE name = 'account_purge_cron_secret'
        )
      ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 15000
    );
    $cron$
  );
END $$;

COMMIT;

SELECT public.record_migration('20261073090000', 'monitor_heartbeat');
NOTIFY pgrst, 'reload schema';
