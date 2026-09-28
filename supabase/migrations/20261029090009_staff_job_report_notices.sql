-- CLI-created 20260927124058; ordered after existing future-dated dependencies.
-- All new producers remain OFF. No transport replay or evidence deletion.
ALTER TABLE private.staff_inbox_control
 ADD COLUMN job_events_enabled BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN report_events_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE private.staff_event_outbox DROP CONSTRAINT staff_event_outbox_kind_check;
ALTER TABLE private.staff_event_outbox ADD CONSTRAINT staff_event_outbox_kind_check CHECK(kind IN
 ('support_assigned','support_sla_breached','legal_review_requested','moderation_assigned','moderation_review_requested',
  'job_push_attention','job_email_attention','job_media_attention','impact_report_ready'));

CREATE TABLE private.staff_job_attention (
 source_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 queue TEXT NOT NULL UNIQUE CHECK(queue IN ('push','email','media')),
 observed_count INTEGER CHECK(observed_count BETWEEN 0 AND 1000),
 has_more BOOLEAN NOT NULL DEFAULT false,
 measured_at TIMESTAMPTZ
);
INSERT INTO private.staff_job_attention(queue) VALUES('push'),('email'),('media');
ALTER TABLE private.staff_job_attention ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.staff_job_attention FROM PUBLIC,anon,authenticated;
CREATE INDEX staff_push_dead_idx ON public.push_delivery_outbox(created_at,delivery_id) WHERE status='dead';
CREATE INDEX staff_email_failed_idx ON public.email_outbox(created_at,outbox_id) WHERE status='failed';
CREATE INDEX staff_media_stalled_idx ON public.media_scan_jobs(lease_expires_at) WHERE completed_at IS NULL;

CREATE FUNCTION public.admin_configure_staff_inbox_sources(p_operation UUID,p_jobs BOOLEAN,p_reports BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('jobs',p_jobs,'reports',p_reports);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_jobs IS NULL OR p_reports IS NULL THEN RAISE EXCEPTION 'invalid_rollout'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'staff_inbox.sources',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_sources',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.staff_inbox_control SET job_events_enabled=p_jobs,report_events_enabled=p_reports WHERE singleton;
 PERFORM private.record_operational_audit(actor,'staff_inbox.sources','staff_inbox',p_operation,'Staff notification sources','release_control',request);
 PERFORM private.record_admin_operation(actor,p_operation,'staff_inbox.sources',request,p_operation);
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_staff_inbox_sources(UUID,BOOLEAN,BOOLEAN) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_staff_inbox_sources(UUID,BOOLEAN,BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION private.can_read_staff_event(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT CASE
 WHEN p_kind IN ('support_assigned','support_sla_breached') THEN
  public.is_staff(p_actor,ARRAY['super_admin','admin','support']) AND EXISTS(SELECT 1 FROM private.support_cases WHERE support_case_id=p_source)
 WHEN p_kind='legal_review_requested' THEN
  public.is_staff(p_actor,ARRAY['super_admin']) AND EXISTS(SELECT 1 FROM private.legal_requests WHERE legal_request_id=p_source AND created_by<>p_actor)
 WHEN p_kind IN ('moderation_assigned','moderation_review_requested') THEN
  (SELECT moderation_events_enabled FROM private.staff_inbox_control WHERE singleton)
  AND public.is_staff(p_actor,ARRAY['super_admin','admin','moderator'])
  AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=p_source AND
   CASE WHEN p_kind='moderation_assigned' THEN c.assignee_id=p_actor AND c.status<>'resolved'
   ELSE c.status='awaiting_second_review' AND p_actor<>(
    SELECT e.actor_id FROM public.moderation_case_events e WHERE e.case_id=c.case_id AND e.kind='status_changed' AND e.detail->>'to'='awaiting_second_review'
    ORDER BY e.created_at DESC,e.event_id DESC LIMIT 1) END)
 WHEN p_kind IN ('job_push_attention','job_email_attention','job_media_attention') THEN
  (SELECT job_events_enabled FROM private.staff_inbox_control WHERE singleton)
  AND public.is_staff(p_actor,ARRAY['super_admin','admin'])
  AND EXISTS(SELECT 1 FROM private.staff_job_attention s WHERE s.source_id=p_source
   AND p_kind='job_'||s.queue||'_attention' AND s.observed_count>0 AND s.measured_at>now()-interval '2 minutes')
 WHEN p_kind='impact_report_ready' THEN
  (SELECT report_events_enabled FROM private.staff_inbox_control WHERE singleton)
  AND public.is_staff(p_actor,ARRAY['super_admin','admin','analyst','read_only_auditor'])
  AND EXISTS(SELECT 1 FROM private.impact_report_snapshots r WHERE r.report_id=p_source AND r.generated_by=p_actor
   AND r.status IN ('generated','published') AND r.checksum IS NOT NULL)
 ELSE false END;
$$;
REVOKE ALL ON FUNCTION private.can_read_staff_event(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;

-- Indexed, capped queue reads: at most 1,001 source rows per queue, no payloads.
-- At most one notice per queue per UTC hour, even when thousands of jobs fail.
CREATE FUNCTION private.refresh_staff_job_attention()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s private.staff_job_attention; n INTEGER; emitted INTEGER:=0; rows_written INTEGER;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled AND job_events_enabled FOR SHARE;
 IF NOT FOUND THEN RETURN 0; END IF;
 FOR s IN SELECT * FROM private.staff_job_attention ORDER BY queue LOOP
  CASE s.queue
   WHEN 'push' THEN SELECT count(*) INTO n FROM (SELECT 1 FROM public.push_delivery_outbox WHERE status='dead' LIMIT 1001)t;
   WHEN 'email' THEN SELECT count(*) INTO n FROM (SELECT 1 FROM public.email_outbox WHERE status='failed' LIMIT 1001)t;
   WHEN 'media' THEN SELECT count(*) INTO n FROM (SELECT 1 FROM public.media_scan_jobs WHERE completed_at IS NULL AND lease_expires_at<now()-interval '15 minutes' LIMIT 1001)t;
  END CASE;
  UPDATE private.staff_job_attention SET observed_count=least(n,1000),has_more=n>1000,measured_at=clock_timestamp() WHERE source_id=s.source_id;
  IF n>0 THEN
   INSERT INTO private.staff_event_outbox(event_key,kind,source_id,severity)
   VALUES('job-queue:'||s.queue||':'||to_char(now() AT TIME ZONE 'UTC','YYYYMMDDHH'),'job_'||s.queue||'_attention',s.source_id,'warning')
   ON CONFLICT(event_key) DO NOTHING;
   GET DIAGNOSTICS rows_written=ROW_COUNT; emitted:=emitted+rows_written;
  END IF;
 END LOOP;
 RETURN emitted;
END $$;
REVOKE ALL ON FUNCTION private.refresh_staff_job_attention() FROM PUBLIC,anon,authenticated;
SELECT cron.schedule('staff-inbox-job-attention','* * * * *','SELECT private.refresh_staff_job_attention()');

-- Checksum is written only after the immutable values have been populated.
-- This announces a generated snapshot, not file download/delivery completion.
CREATE FUNCTION private.enqueue_staff_report_ready()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.checksum IS NULL OR NEW.generated_by IS NULL OR NEW.status NOT IN ('generated','published') THEN RETURN NEW; END IF;
 IF NOT (SELECT enabled AND report_events_enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN NEW; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 VALUES('impact-report:'||NEW.report_id,'impact_report_ready',NEW.report_id,NEW.generated_by,'info') ON CONFLICT(event_key) DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.enqueue_staff_report_ready() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER staff_report_ready AFTER INSERT OR UPDATE OF checksum ON private.impact_report_snapshots
 FOR EACH ROW EXECUTE FUNCTION private.enqueue_staff_report_ready();

-- Aggregate only; no user IDs, content, raw errors or source identifiers.
CREATE TABLE private.staff_inbox_hourly (
 hour TIMESTAMPTZ PRIMARY KEY,
 batches BIGINT NOT NULL DEFAULT 0 CHECK(batches>=0),
 delivered_events BIGINT NOT NULL DEFAULT 0 CHECK(delivered_events>=0),
 failed_attempts BIGINT NOT NULL DEFAULT 0 CHECK(failed_attempts>=0),
 max_delivery_lag_seconds NUMERIC,
 last_batch_at TIMESTAMPTZ NOT NULL
);
ALTER TABLE private.staff_inbox_hourly ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.staff_inbox_hourly FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.record_staff_inbox_batch()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.batch_at IS NULL OR NEW.batch_at IS NOT DISTINCT FROM OLD.batch_at THEN RETURN NEW; END IF;
 INSERT INTO private.staff_inbox_hourly(hour,batches,delivered_events,failed_attempts,max_delivery_lag_seconds,last_batch_at)
 VALUES(date_trunc('hour',NEW.batch_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',1,NEW.delivered_events,NEW.failed_attempts,NEW.max_delivery_lag_seconds,NEW.batch_at)
 ON CONFLICT(hour) DO UPDATE SET batches=staff_inbox_hourly.batches+1,
  delivered_events=staff_inbox_hourly.delivered_events+excluded.delivered_events,
  failed_attempts=staff_inbox_hourly.failed_attempts+excluded.failed_attempts,
  max_delivery_lag_seconds=greatest(staff_inbox_hourly.max_delivery_lag_seconds,excluded.max_delivery_lag_seconds),last_batch_at=excluded.last_batch_at;
 -- Fixed-size aggregate retention, not incident/audit evidence deletion.
 DELETE FROM private.staff_inbox_hourly WHERE hour IN (SELECT hour FROM private.staff_inbox_hourly WHERE hour<now()-interval '90 days' ORDER BY hour LIMIT 1000);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.record_staff_inbox_batch() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER staff_inbox_batch_history AFTER UPDATE OF batch_at ON private.staff_inbox_runtime FOR EACH ROW EXECUTE FUNCTION private.record_staff_inbox_batch();

CREATE FUNCTION public.admin_staff_notification_observability()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT public.claim_rate_limit('staff_notification_observability',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 RETURN jsonb_build_object('measured_at',clock_timestamp(),
  'jobs_enabled',(SELECT enabled AND job_events_enabled FROM private.staff_inbox_control WHERE singleton),
  'reports_enabled',(SELECT enabled AND report_events_enabled FROM private.staff_inbox_control WHERE singleton),
  'jobs',(SELECT jsonb_agg(jsonb_build_object('queue',queue,'count',observed_count,'has_more',has_more,'measured_at',measured_at) ORDER BY queue) FROM private.staff_job_attention),
  'hours',COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY hour) FROM private.staff_inbox_hourly h WHERE hour>=date_trunc('hour',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'-interval '23 hours'),'[]'::JSONB));
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_notification_observability() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_notification_observability() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_staff_inbox_page(
 p_filter TEXT DEFAULT 'all',p_category TEXT DEFAULT 'all',p_severity TEXT DEFAULT 'all',
 p_limit INTEGER DEFAULT 30,p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL
) RETURNS TABLE(event_id UUID,kind TEXT,severity TEXT,source_id UUID,destination TEXT,delivered_at TIMESTAMPTZ,read_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid();
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF p_filter IS NULL OR p_filter NOT IN ('all','unread','urgent','assigned')
  OR p_category IS NULL OR p_category NOT IN ('all','support','legal','moderation','jobs','reports')
  OR p_severity IS NULL OR p_severity NOT IN ('all','info','warning','critical')
  OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_before_at IS NULL)<>(p_before_id IS NULL))
  OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_inbox_query' USING ERRCODE='22023'; END IF;
 IF NOT (SELECT enabled AND public.is_staff(actor,audience_roles) FROM private.staff_inbox_control WHERE singleton) THEN RETURN; END IF;
 RETURN QUERY SELECT o.event_id,o.kind,o.severity,o.source_id,
  CASE WHEN o.kind='legal_review_requested' THEN '/legal-requests'
   WHEN o.kind IN ('moderation_assigned','moderation_review_requested') THEN '/moderation/cases/'||o.source_id
   WHEN o.kind='impact_report_ready' THEN '/impact/reports/'||o.source_id
   WHEN o.kind LIKE 'job_%' THEN '/jobs#'||CASE o.kind WHEN 'job_push_attention' THEN 'push-failures' WHEN 'job_email_attention' THEN 'email-failures' ELSE 'media-stalled' END
   ELSE '/support/cases' END,d.delivered_at,d.read_at
 FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
 WHERE d.recipient_id=actor AND private.can_read_staff_event(actor,o.kind,o.source_id)
  AND (p_filter<>'unread' OR d.read_at IS NULL) AND (p_filter<>'urgent' OR o.severity='critical')
  AND (p_filter<>'assigned' OR
   (o.kind IN ('support_assigned','support_sla_breached') AND EXISTS(SELECT 1 FROM private.support_cases c WHERE c.support_case_id=o.source_id AND c.assigned_to=actor AND c.status NOT IN ('resolved','closed')))
   OR (o.kind IN ('moderation_assigned','moderation_review_requested') AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=o.source_id AND c.assignee_id=actor AND c.status<>'resolved')))
  AND (p_category='all' OR (p_category='legal' AND o.kind='legal_review_requested')
   OR (p_category='support' AND o.kind IN ('support_assigned','support_sla_breached'))
   OR (p_category='moderation' AND o.kind IN ('moderation_assigned','moderation_review_requested'))
   OR (p_category='jobs' AND o.kind IN ('job_push_attention','job_email_attention','job_media_attention'))
   OR (p_category='reports' AND o.kind='impact_report_ready'))
  AND (p_severity='all' OR o.severity=p_severity)
  AND (p_before_at IS NULL OR (d.delivered_at,d.event_id)<(p_before_at,p_before_id))
 ORDER BY d.delivered_at DESC,d.event_id DESC LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;
CREATE OR REPLACE FUNCTION private.process_staff_inbox(p_limit INTEGER DEFAULT 100)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e private.staff_event_outbox%ROWTYPE; processed INTEGER:=0; delivered INTEGER:=0; failed INTEGER:=0; lag NUMERIC; max_lag NUMERIC;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_limit'; END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 -- Coordinate with rollout/recovery: disabling waits for this bounded batch.
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled FOR SHARE;
 IF NOT FOUND THEN RETURN 0; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT 'support-sla:'||c.support_case_id||':'||c.sla_due_at::TEXT,'support_sla_breached',c.support_case_id,c.assigned_to,'critical'
 FROM private.support_cases c WHERE c.status NOT IN ('resolved','closed') AND c.sla_due_at<now()
 AND NOT EXISTS(SELECT 1 FROM private.staff_event_outbox o WHERE o.event_key='support-sla:'||c.support_case_id||':'||c.sla_due_at::TEXT)
 ORDER BY c.sla_due_at,c.support_case_id LIMIT p_limit ON CONFLICT(event_key) DO NOTHING;
 FOR e IN SELECT * FROM private.staff_event_outbox WHERE status='pending' AND next_attempt_at<=now()
 ORDER BY next_attempt_at,event_id FOR UPDATE SKIP LOCKED LIMIT p_limit LOOP
  BEGIN
   INSERT INTO private.staff_inbox_deliveries(event_id,recipient_id)
   SELECT e.event_id,u.user_id FROM public.users u
   -- Match idx_users_role's partial predicate without casting the indexed enum.
   WHERE u.user_role<>'normal' AND u.user_role IN ('super_admin','admin','moderator','support','analyst','read_only_auditor')
    AND u.user_role::TEXT=ANY((SELECT audience_roles FROM private.staff_inbox_control WHERE singleton)::TEXT[])
    AND (e.intended_recipient IS NULL OR u.user_id=e.intended_recipient)
    AND private.can_read_staff_event(u.user_id,e.kind,e.source_id)
    AND (e.kind NOT IN ('support_assigned','moderation_assigned') OR e.severity='critical' OR COALESCE(
     (SELECT p.assignment_notifications FROM private.staff_inbox_preferences p WHERE p.staff_id=u.user_id),true))
   ON CONFLICT(recipient_id,event_id) DO NOTHING;
   IF EXISTS(SELECT 1 FROM private.staff_inbox_deliveries d WHERE d.event_id=e.event_id) THEN
    UPDATE private.staff_event_outbox SET status='delivered',delivered_at=clock_timestamp(),attempts=attempts+1,last_error_code=NULL WHERE event_id=e.event_id;
    delivered:=delivered+1;lag:=greatest(0,extract(epoch FROM clock_timestamp()-e.created_at));
    max_lag:=CASE WHEN max_lag IS NULL THEN lag ELSE greatest(max_lag,lag) END;
   ELSE
    UPDATE private.staff_event_outbox SET status='skipped',delivered_at=clock_timestamp(),attempts=attempts+1,last_error_code=NULL WHERE event_id=e.event_id;
   END IF;
   processed:=processed+1;
  EXCEPTION WHEN OTHERS THEN
   failed:=failed+1;
   UPDATE private.staff_event_outbox SET attempts=attempts+1,status=CASE WHEN attempts+1>=5 THEN 'failed' ELSE 'pending' END,
    next_attempt_at=now()+make_interval(secs=>LEAST(3600,30*(2^attempts)::INTEGER)),last_error_code=SQLSTATE WHERE event_id=e.event_id;
  END;
 END LOOP;
 PERFORM private.refresh_staff_attention();
 UPDATE private.staff_inbox_control SET worker_at=clock_timestamp() WHERE singleton;
 UPDATE private.staff_inbox_runtime SET batch_at=clock_timestamp(),delivered_events=delivered,failed_attempts=failed,max_delivery_lag_seconds=max_lag WHERE singleton;
 RETURN processed;
END $$;
REVOKE ALL ON FUNCTION private.process_staff_inbox(INTEGER) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.admin_staff_attention()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); control private.staff_inbox_control%ROWTYPE; unread INTEGER; queues JSONB;
BEGIN
  IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('staff_attention_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO control FROM private.staff_inbox_control WHERE singleton;
  IF NOT control.enabled OR NOT public.is_staff(actor,control.audience_roles) THEN RETURN jsonb_build_object('enabled',false); END IF;
  SELECT count(*) INTO unread FROM (SELECT 1 FROM private.staff_inbox_deliveries d
    JOIN private.staff_event_outbox o USING(event_id)
    WHERE d.recipient_id=actor AND d.read_at IS NULL
      AND private.can_read_staff_event(actor,o.kind,o.source_id) LIMIT 100) capped;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('key',s.queue_key,'count',s.open_count,
    'measured_at',s.measured_at,'stale',s.invalidated OR EXISTS(
      SELECT 1 FROM private.staff_attention_changes c WHERE c.queue_key=s.queue_key)
      OR s.measured_at<now()-interval '2 minutes'
      OR s.measured_at>now()+interval '1 minute') ORDER BY s.queue_key),'[]'::JSONB)
  INTO queues FROM private.staff_attention_snapshots s WHERE
    (s.queue_key='support' AND public.is_staff(actor,ARRAY['super_admin','admin','support'])) OR
    (s.queue_key='legal' AND public.is_staff(actor,ARRAY['super_admin'])) OR
    (s.queue_key IN ('moderation','appeals') AND public.is_staff(actor,ARRAY['super_admin','admin','moderator']));
  IF control.job_events_enabled AND public.is_staff(actor,ARRAY['super_admin','admin']) THEN
    queues:=queues||jsonb_build_array((SELECT jsonb_build_object('key','jobs','count',least(COALESCE(sum(observed_count),0),100),
      'measured_at',COALESCE(min(measured_at),'epoch'::TIMESTAMPTZ),
      'stale',count(measured_at)<>3 OR min(measured_at)<now()-interval '2 minutes' OR max(measured_at)>now()+interval '1 minute')
      FROM private.staff_job_attention));
  END IF;
  RETURN jsonb_build_object('enabled',true,'unread_count',LEAST(unread,99),'unread_more',unread>99,
    'generated_at',now(),'worker_at',control.worker_at,'queues',queues);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_staff_attention() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_attention() TO authenticated;
CREATE FUNCTION public.admin_generate_impact_report_checked(
 p_operation UUID,p_report_kind TEXT,p_title TEXT,p_audience TEXT,p_window_start DATE,p_window_end DATE,
 p_country_source TEXT DEFAULT 'none',p_country_filter TEXT DEFAULT NULL,p_notes TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB; result UUID;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF length(COALESCE(p_title,''))>160 OR length(COALESCE(p_notes,''))>1000 OR length(COALESCE(p_country_filter,''))>80
  OR length(COALESCE(p_country_source,''))>30 OR length(COALESCE(p_report_kind,''))>40 OR length(COALESCE(p_audience,''))>20 THEN RAISE EXCEPTION 'invalid_report_parameters' USING ERRCODE='22023'; END IF;
 request:=jsonb_build_object('kind',p_report_kind,'title',p_title,'audience',p_audience,'start',p_window_start,'end',p_window_end,
  'country_source',p_country_source,'country_filter',p_country_filter,'notes',p_notes);
 result:=private.admin_operation_existing(actor,p_operation,'impact.report.generate',request);
 IF result IS NOT NULL THEN RETURN result; END IF;
 IF NOT public.claim_rate_limit('impact_report_generate',60,5) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 result:=public.admin_generate_impact_report(p_report_kind,p_title,p_audience,p_window_start,p_window_end,p_country_source,p_country_filter,p_notes);
 -- Existing generation audits the canonical snapshot. The receipt stores only
 -- the request digest and resulting ID, never duplicate method notes/content.
 PERFORM private.record_admin_operation(actor,p_operation,'impact.report.generate',request,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_generate_impact_report_checked(UUID,TEXT,TEXT,TEXT,DATE,DATE,TEXT,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_generate_impact_report_checked(UUID,TEXT,TEXT,TEXT,DATE,DATE,TEXT,TEXT,TEXT) TO authenticated;
-- Pull this from an independently operated monitor, not from the delivery
-- worker being monitored. Service-only, metadata-only, no mutation privileges.
CREATE FUNCTION public.staff_notification_monitor()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('checked_at',now(),'enabled',c.enabled,
  'worker_stale',c.worker_at IS NULL OR c.worker_at<now()-interval '2 minutes' OR c.worker_at>now()+interval '1 minute',
  'job_monitor_stale',c.job_events_enabled AND EXISTS(SELECT 1 FROM private.staff_job_attention WHERE measured_at IS NULL OR measured_at<now()-interval '2 minutes' OR measured_at>now()+interval '1 minute'),
  'has_failed_events',EXISTS(SELECT 1 FROM private.staff_event_outbox WHERE status='failed'),
  'has_overdue_pending',EXISTS(SELECT 1 FROM private.staff_event_outbox WHERE status='pending' AND created_at<now()-interval '5 minutes'),
  'runbook','/inbox/operations') FROM private.staff_inbox_control c WHERE singleton;
$$;
REVOKE ALL ON FUNCTION public.staff_notification_monitor() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.staff_notification_monitor() TO service_role;
SELECT public.record_migration('20261029090009','staff_job_report_notices');
NOTIFY pgrst,'reload schema';
