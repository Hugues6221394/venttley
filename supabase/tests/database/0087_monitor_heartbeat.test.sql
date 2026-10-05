-- External heartbeat status: grants, schedule parsing and job health rules.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(17);

SELECT ok(NOT has_function_privilege('anon', 'public.platform_heartbeat_status()', 'EXECUTE'), 'anon cannot read heartbeat status');
SELECT ok(NOT has_function_privilege('authenticated', 'public.platform_heartbeat_status()', 'EXECUTE'), 'members and staff cannot read heartbeat status');
SELECT ok(has_function_privilege('service_role', 'public.platform_heartbeat_status()', 'EXECUTE'), 'service role reads heartbeat status');

SELECT is(private.cron_interval_minutes('* * * * *'), 1, 'every minute');
SELECT is(private.cron_interval_minutes('*/5 * * * *'), 5, 'every five minutes');
SELECT is(private.cron_interval_minutes('17 * * * *'), 60, 'hourly');
SELECT is(private.cron_interval_minutes('15 3 * * *'), 1440, 'daily');
SELECT is(private.cron_interval_minutes('0 0 * * 1'), NULL, 'unknown shapes are not checked for lateness');

CREATE FUNCTION pg_temp.p(every INT, started INT, succeeded INT, status TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT private.cron_job_problem(every,
    now() - make_interval(mins => started), now() - make_interval(mins => succeeded), status, now())
$$;

SELECT is(private.cron_job_problem(1, NULL, NULL, NULL, now()), 'not_running', 'a frequent job that never ran is reported');
SELECT is(private.cron_job_problem(1440, NULL, NULL, NULL, now()), NULL, 'a daily job not yet run since activation is not');
SELECT is(pg_temp.p(1, 8, 8, 'succeeded'), 'late', 'a minute job silent for eight minutes is late');
SELECT is(pg_temp.p(1, 2, 2, 'succeeded'), NULL, 'a minute job that ran two minutes ago is healthy');
SELECT is(pg_temp.p(1440, 1500, 1500, 'succeeded'), NULL, 'a daily job that ran yesterday is healthy');
SELECT is(pg_temp.p(1, 0, 2, 'failed'), NULL, 'one transient failure after a recent success is tolerated');
SELECT is(pg_temp.p(1, 0, 10, 'failed'), 'failed', 'repeated failures with no recent success are reported');
SELECT is(pg_temp.p(1440, 0, 1500, 'failed'), 'failed', 'a failed daily job is reported at once');

SELECT ok(public.platform_heartbeat_status() ? 'healthy', 'status reads the live scheduler without error');

SELECT * FROM finish();
ROLLBACK;
