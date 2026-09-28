BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
VALUES('1a760000-0000-4000-8000-000000000001','deadlinehealth','deadlinehealth','x','Synthetic Operator','synthetic operator','deadlinehealth','super_admin','active',1990);
INSERT INTO auth.users(id,aud,role,created_at,updated_at) VALUES('1a760000-0000-4000-8000-000000000001','authenticated','authenticated',now(),now());
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.health() RETURNS JSONB LANGUAGE sql AS $$SELECT public.staff_notification_monitor()->'incident_deadlines';$$;
SELECT ok(NOT has_table_privilege('authenticated','private.incident_deadline_runtime','SELECT'),'raw telemetry not client readable');
SELECT ok(NOT has_function_privilege('authenticated','private.incident_deadline_health()','EXECUTE'),'private health helper not callable');
SELECT ok(NOT has_function_privilege('authenticated','public.staff_notification_monitor()','EXECUTE'),'human access denied on machine probe');
SELECT ok(NOT has_function_privilege('anon','public.staff_notification_monitor()','EXECUTE'),'anonymous probe denied');
SELECT ok(has_function_privilege('service_role','public.staff_notification_monitor()','EXECUTE'),'machine role can probe');
SELECT is(pg_temp.health()->>'enabled','false','disabled producer explicitly not enabled');
SELECT is(private.reconcile_incident_deadlines(),0,'disabled worker performs no work');
SELECT is(pg_temp.health()->>'succeeded_at',NULL::TEXT,'disabled invocation cannot certify success');
UPDATE private.staff_inbox_control SET enabled=true,worker_at=now();
UPDATE private.incident_control SET enabled=true,notifications_enabled=true;
SELECT is(pg_temp.health()->>'worker_stale','true','new pilot heartbeat is unknown');
SELECT is(pg_temp.health()->>'backlog_overdue',NULL::TEXT,'unknown is not an empty backlog');
SELECT cron.alter_job(jobid,active:=true) FROM cron.job WHERE jobname='staff-incident-deadlines';
SELECT is(private.reconcile_incident_deadlines(),0,'healthy empty batch can complete');
SELECT is(pg_temp.health()->>'worker_stale','false','producer has its own fresh heartbeat');
SELECT is(pg_temp.health()->>'batch_max_lag_seconds',NULL::TEXT,'empty batch does not fabricate latency');
SELECT is(pg_temp.health()->>'scheduler_active','true','schedule is inspected independently');
UPDATE private.incident_deadline_runtime SET succeeded_at=now()-interval '3 minutes';
SELECT is(public.staff_notification_monitor()->>'worker_stale','false','delivery worker can still be healthy');
SELECT is(pg_temp.health()->>'worker_stale','true','stopped deadline producer is independently stale');
UPDATE private.incident_deadline_runtime SET succeeded_at=now()+interval '2 minutes';
SELECT is(pg_temp.health()->>'worker_stale','true','future heartbeat is not healthy');
SELECT cron.alter_job(jobid,active:=false) FROM cron.job WHERE jobname='staff-incident-deadlines';
SELECT is(pg_temp.health()->>'scheduler_active','false','paused scheduler is visible even before heartbeat expires');
INSERT INTO private.operational_incidents(title,severity,services,commander,response_due_at,runbook,created_by)
SELECT 'Synthetic private title','sev2',ARRAY['push'],'1a760000-0000-4000-8000-000000000001',now()-interval '10 minutes','delivery','1a760000-0000-4000-8000-000000000001'
FROM generate_series(1,101);
SELECT is(private.reconcile_incident_deadlines(),100,'producer writes at most 100 incident batches');
SELECT is(pg_temp.health()->>'backlog_overdue','true','old remaining backlog reported');
SELECT ok((pg_temp.health()->>'batch_max_lag_seconds')::NUMERIC>=600,'maximum observed deadline-to-enqueue delay recorded');
SELECT is(private.reconcile_incident_deadlines(),1,'next bounded batch drains remaining incident');
SELECT is(pg_temp.health()->>'backlog_overdue','false','drained backlog reconciles');
SELECT is(private.reconcile_incident_deadlines(),0,'repeated run is idempotent');
SELECT is(pg_temp.health()->>'batch_max_lag_seconds',NULL::TEXT,'empty retry has no invented latency');
SELECT ok(public.staff_notification_monitor()::TEXT NOT LIKE '%Synthetic private title%','no incident content in monitor');
SELECT ok(public.staff_notification_monitor()::TEXT NOT LIKE '%1a760000%','no staff identifiers in monitor');
UPDATE private.incident_control SET notifications_enabled=false;
SELECT is(pg_temp.health()->>'enabled','false','source kill switch reflected');
UPDATE private.incident_control SET notifications_enabled=true;
SELECT is(pg_temp.health()->>'succeeded_at',NULL::TEXT,'re-enabling invalidates past heartbeat');
-- A real enqueue error must remain an error; never swallow it into a successful
-- cron run or commit partial output. Trigger is transactional test-only.
CREATE FUNCTION pg_temp.reject_notice() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'synthetic_enqueue_failure'; END $$;
CREATE TRIGGER test_deadline_enqueue_failure BEFORE INSERT ON private.staff_event_outbox
 FOR EACH ROW WHEN (NEW.kind='incident_overdue') EXECUTE FUNCTION pg_temp.reject_notice();
UPDATE private.operational_incidents SET response_due_at=now()-interval '20 minutes' WHERE created_by='1a760000-0000-4000-8000-000000000001';
SELECT throws_like($$SELECT private.reconcile_incident_deadlines()$$,'%synthetic_enqueue_failure%','failed producer reports failure to cron');
SELECT is(pg_temp.health()->>'succeeded_at',NULL::TEXT,'failed batch does not advance heartbeat');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_event_outbox WHERE kind='incident_overdue' AND source_id IN(SELECT incident_id FROM private.operational_incidents WHERE created_by='1a760000-0000-4000-8000-000000000001')),101,'failed batch leaves no partial notifications');
DROP TRIGGER test_deadline_enqueue_failure ON private.staff_event_outbox;
SELECT is(private.reconcile_incident_deadlines(),100,'transient failure recovers on next run');
UPDATE private.staff_inbox_control SET enabled=false;
SELECT is(pg_temp.health()->>'enabled','false','global kill switch dominates source');
UPDATE private.staff_inbox_control SET enabled=true;
SELECT is(pg_temp.health()->>'worker_stale','true','global re-enable requires new success');
SET LOCAL ROLE service_role;
SELECT lives_ok('SELECT public.staff_notification_monitor()','service-role probe runs through effective grants');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
