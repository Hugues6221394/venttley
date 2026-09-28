-- CLI-created 20260928105740, ordered after this branch's dependencies.
-- Independent, metadata-only producer health. Does not enable any rollout.
CREATE TABLE private.incident_deadline_runtime (
 singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK(singleton),
 succeeded_at TIMESTAMPTZ,
 enqueued INTEGER CHECK(enqueued BETWEEN 0 AND 2100),
 oldest_unprocessed_due_at TIMESTAMPTZ,
 batch_max_lag_seconds NUMERIC CHECK(batch_max_lag_seconds>=0)
);
INSERT INTO private.incident_deadline_runtime DEFAULT VALUES;
ALTER TABLE private.incident_deadline_runtime ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.incident_deadline_runtime FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.reset_incident_deadline_health() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 -- A previous rollout's heartbeat must not certify a newly enabled producer.
 UPDATE private.incident_deadline_runtime SET succeeded_at=NULL,enqueued=NULL,
  oldest_unprocessed_due_at=NULL,batch_max_lag_seconds=NULL WHERE singleton;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.reset_incident_deadline_health() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER incident_deadline_health_rollout AFTER UPDATE ON private.incident_control
 FOR EACH ROW WHEN (NEW IS DISTINCT FROM OLD) EXECUTE FUNCTION private.reset_incident_deadline_health();
CREATE TRIGGER incident_deadline_health_inbox_rollout AFTER UPDATE OF enabled ON private.staff_inbox_control
 FOR EACH ROW WHEN (NEW.enabled IS DISTINCT FROM OLD.enabled) EXECUTE FUNCTION private.reset_incident_deadline_health();

CREATE OR REPLACE FUNCTION private.reconcile_incident_deadlines()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n INTEGER; remaining TIMESTAMPTZ; max_lag NUMERIC;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled FOR SHARE; IF NOT FOUND THEN RETURN 0; END IF;
 PERFORM 1 FROM private.incident_control WHERE singleton AND enabled AND notifications_enabled FOR SHARE; IF NOT FOUND THEN RETURN 0; END IF;
 -- One extra candidate measures remaining backlog without an unbounded count.
 WITH candidates AS MATERIALIZED (
  SELECT i.incident_id,i.response_due_at,i.commander,i.responders FROM private.operational_incidents i
  WHERE i.status NOT IN ('resolved','reviewed') AND i.response_due_at<now()
   AND EXISTS(SELECT 1 FROM unnest(array_prepend(i.commander,i.responders))r
    WHERE private.incident_pilot_member(r) AND NOT EXISTS(
     SELECT 1 FROM private.staff_event_outbox o
     WHERE o.event_key='incident-deadline:'||i.incident_id||':'||extract(epoch FROM i.response_due_at)::TEXT||':'||r))
  ORDER BY i.response_due_at,i.incident_id LIMIT 101
 ), batch AS MATERIALIZED (
  SELECT * FROM candidates ORDER BY response_due_at,incident_id LIMIT 100
 ), inserted AS (
  INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
  SELECT 'incident-deadline:'||i.incident_id||':'||extract(epoch FROM i.response_due_at)::TEXT||':'||recipient,
   'incident_overdue',i.incident_id,recipient,'critical'
  FROM batch i CROSS JOIN LATERAL (SELECT DISTINCT unnest(array_prepend(i.commander,i.responders)) AS recipient)t
  WHERE private.incident_pilot_member(recipient) ON CONFLICT(event_key) DO NOTHING RETURNING 1
 )
 SELECT (SELECT count(*)::INTEGER FROM inserted),
  (SELECT response_due_at FROM candidates ORDER BY response_due_at,incident_id OFFSET 100 LIMIT 1),
  (SELECT greatest(0,extract(epoch FROM clock_timestamp()-min(response_due_at))) FROM batch HAVING count(*)>0)
 INTO n,remaining,max_lag;
 -- Commit success and enqueue atomically. On any error both roll back; native
 -- cron failure remains visible and the independent heartbeat ages out.
 UPDATE private.incident_deadline_runtime SET succeeded_at=clock_timestamp(),enqueued=n,
  oldest_unprocessed_due_at=remaining,batch_max_lag_seconds=max_lag WHERE singleton;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION private.reconcile_incident_deadlines() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.incident_deadline_health()
RETURNS JSONB LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT jsonb_build_object(
  'enabled',c.enabled AND c.notifications_enabled AND s.enabled,
  'scheduler_active',EXISTS(SELECT 1 FROM cron.job WHERE jobname='staff-incident-deadlines' AND database=current_database() AND active),
  'succeeded_at',r.succeeded_at,
  'worker_stale',r.succeeded_at IS NULL OR r.succeeded_at<now()-interval '2 minutes' OR r.succeeded_at>now()+interval '1 minute',
  'enqueued',r.enqueued,'oldest_unprocessed_due_at',r.oldest_unprocessed_due_at,
  'backlog_overdue',CASE WHEN r.succeeded_at IS NULL THEN NULL ELSE COALESCE(r.oldest_unprocessed_due_at<now()-interval '5 minutes',false) END,
  'batch_max_lag_seconds',r.batch_max_lag_seconds)
 FROM private.incident_control c CROSS JOIN private.staff_inbox_control s
 LEFT JOIN private.incident_deadline_runtime r ON r.singleton WHERE c.singleton AND s.singleton;
$$;
REVOKE ALL ON FUNCTION private.incident_deadline_health() FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.staff_notification_monitor()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('checked_at',now(),'enabled',c.enabled,
  'worker_stale',c.worker_at IS NULL OR c.worker_at<now()-interval '2 minutes' OR c.worker_at>now()+interval '1 minute',
  'job_monitor_stale',c.job_events_enabled AND EXISTS(SELECT 1 FROM private.staff_job_attention WHERE measured_at IS NULL OR measured_at<now()-interval '2 minutes' OR measured_at>now()+interval '1 minute'),
  'has_failed_events',EXISTS(SELECT 1 FROM private.staff_event_outbox WHERE status='failed'),
  'has_overdue_pending',EXISTS(SELECT 1 FROM private.staff_event_outbox WHERE status='pending' AND created_at<now()-interval '5 minutes'),
  'incident_deadlines',private.incident_deadline_health(),
  'runbook','/inbox/operations') FROM private.staff_inbox_control c WHERE singleton;
$$;
REVOKE ALL ON FUNCTION public.staff_notification_monitor() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.staff_notification_monitor() TO service_role;
SELECT public.record_migration('20261029090013','incident_deadline_health');
NOTIFY pgrst,'reload schema';
