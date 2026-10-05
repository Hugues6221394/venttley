-- External heartbeat status: grants, schedule parsing and job health rules.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(14);

SELECT ok(NOT has_function_privilege('anon', 'public.platform_heartbeat_status()', 'EXECUTE'), 'anon cannot read heartbeat status');
SELECT ok(NOT has_function_privilege('authenticated', 'public.platform_heartbeat_status()', 'EXECUTE'), 'members and staff cannot read heartbeat status');
SELECT ok(has_function_privilege('service_role', 'public.platform_heartbeat_status()', 'EXECUTE'), 'service role reads heartbeat status');

SELECT is(private.cron_interval_minutes('* * * * *'), 1, 'every minute');
SELECT is(private.cron_interval_minutes('*/5 * * * *'), 5, 'every five minutes');
SELECT is(private.cron_interval_minutes('17 * * * *'), 60, 'hourly');
SELECT is(private.cron_interval_minutes('15 3 * * *'), 1440, 'daily');
SELECT is(private.cron_interval_minutes('0 0 * * 1'), NULL, 'unknown shapes are not checked for lateness');

SELECT isnt((SELECT active FROM cron.job WHERE jobname = 'monitor_heartbeat'), false, 'heartbeat job is scheduled and active');

UPDATE cron.job SET active = false;
DELETE FROM public.email_outbox WHERE status = 'queued';
SELECT cron.schedule('hb_probe', '* * * * *', 'SELECT 1');

CREATE FUNCTION pg_temp.problems() RETURNS JSONB LANGUAGE sql AS
  $$SELECT public.platform_heartbeat_status()->'problems'$$;
CREATE FUNCTION pg_temp.run(p_status TEXT, p_minutes_ago INT) RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO cron.job_run_details(jobid, command, status, start_time)
  SELECT jobid, 'SELECT 1', p_status, now() - make_interval(mins => p_minutes_ago)
    FROM cron.job WHERE jobname = 'hb_probe';
$$;

SELECT is(pg_temp.problems(), '["hb_probe:not_running"]'::jsonb, 'a frequent job that never ran is reported');

SELECT pg_temp.run('succeeded', 8);
SELECT is(pg_temp.problems(), '["hb_probe:late"]'::jsonb, 'a frequent job past twice its interval is late');

SELECT pg_temp.run('failed', 0);
SELECT is(pg_temp.problems(), '["hb_probe:failed"]'::jsonb, 'a failure with no recent success is reported');

DELETE FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'hb_probe');
SELECT pg_temp.run('succeeded', 2);
SELECT pg_temp.run('failed', 1);
SELECT is(pg_temp.problems(), '[]'::jsonb, 'one transient failure after a recent success is tolerated');

SELECT is((public.platform_heartbeat_status()->>'healthy')::BOOLEAN, true, 'healthy when every active job is on time');

SELECT * FROM finish();
ROLLBACK;
