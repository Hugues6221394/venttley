-- =====================================================================
-- Migration 0014 — schedule refresh_hot_posts() on pg_cron
-- =====================================================================
-- Sprint 2 left the materialized view + refresh function in place but
-- nothing was calling refresh. This wires a 2-minute pg_cron job so
-- the Hot feed stays fresh without anyone clicking anything.
--
-- pg_cron lives in the `extensions` schema on Supabase. cron.schedule
-- returns the job id; we re-use the same job_name to make this
-- migration idempotent (re-running drops + reschedules cleanly).
-- =====================================================================

DO $$
BEGIN
    -- pg_cron requires superuser-ish privileges. In Supabase the
    -- service role can manage it; in a stripped-down environment we
    -- skip rather than fail the whole migration.
    BEGIN
        CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'pg_cron not installable in this role; skipping schedule.';
        RETURN;
    END;

    -- Drop any prior schedule with the same name so the migration is
    -- safe to re-run.
    PERFORM cron.unschedule(jobid)
       FROM cron.job
      WHERE jobname = 'refresh_hot_posts_every_2_min';

    PERFORM cron.schedule(
        'refresh_hot_posts_every_2_min',
        '*/2 * * * *',
        $job$ SELECT public.refresh_hot_posts(); $job$
    );

    RAISE NOTICE 'refresh_hot_posts scheduled every 2 minutes.';
END $$;

-- =====================================================================
-- 0014 done.
-- =====================================================================
